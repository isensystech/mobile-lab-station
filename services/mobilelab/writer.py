"""The writer service.

It subscribes to station/#, validates each message, and inserts a row into
readings.

Three rules shape this design.

1. It never blocks the broker. The MQTT callback only puts the raw message on a
   queue. A worker thread does the validation and the database work. A slow
   database therefore cannot stall the network loop.

2. It never exits on a bad payload. Every rejection is caught, logged at error
   with the offending payload and the reason, and counted.

3. It reconnects on its own. paho reconnects to the broker with a backoff. The
   database layer reconnects on the next insert. Nobody has to restart it.
"""

from __future__ import annotations

import json
import logging
import os
import queue
import signal
import sys
import threading
import time
from collections import Counter
from datetime import UTC, datetime
from types import FrameType

import paho.mqtt.client as mqtt

from . import __version__, topics
from .config import Settings, load_settings
from .db import Database, DatabaseUnavailable, DataRejected
from .record import ImplausibleClock, TopicMismatch, check_clock, reading_from_message

log = logging.getLogger("mobilelab.writer")

PAYLOAD_LOG_LIMIT = 1000
SHUTDOWN_SENTINEL = None
STATUS_MIN_SECONDS = 1.0


class Counters:
    """Counts of what the writer did. Every rejection lands in one bucket."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self.accepted = 0
        self.rejected = Counter()

    def count_accepted(self) -> int:
        with self._lock:
            self.accepted += 1
            return self.accepted

    def count_rejected(self, reason: str) -> int:
        with self._lock:
            self.rejected[reason] += 1
            return sum(self.rejected.values())

    def rejected_total(self) -> int:
        with self._lock:
            return sum(self.rejected.values())

    def snapshot(self) -> dict:
        with self._lock:
            return {
                "accepted_total": self.accepted,
                "rejected_total": sum(self.rejected.values()),
                "rejected_by_reason": dict(self.rejected),
            }

    def summary(self) -> str:
        with self._lock:
            total = sum(self.rejected.values())
            if not self.rejected:
                detail = "none"
            else:
                detail = ", ".join(
                    f"{reason}={count}"
                    for reason, count in sorted(self.rejected.items())
                )
            return f"accepted={self.accepted} rejected={total} [{detail}]"


def _clip(text: str) -> str:
    if len(text) <= PAYLOAD_LOG_LIMIT:
        return text
    return f"{text[:PAYLOAD_LOG_LIMIT]}... [clipped, {len(text)} bytes total]"


class Writer:
    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        self.counters = Counters()
        self.database = Database(settings.dsn())
        self.inbox: queue.Queue = queue.Queue(maxsize=settings.mobilelab_writer_queue_size)
        self.stopping = threading.Event()
        self._last_status = 0.0

        # clean_session=False makes the broker keep this subscription while the
        # writer is stopped. With QoS 1 the broker then holds the messages and
        # delivers them at the next connect. Without it, every message published
        # during a restart is lost.
        self.client = mqtt.Client(
            mqtt.CallbackAPIVersion.VERSION2,
            client_id="mobilelab-writer",
            clean_session=False,
        )
        self.client.on_connect = self._on_connect
        self.client.on_disconnect = self._on_disconnect
        self.client.on_message = self._on_message
        self.client.reconnect_delay_set(min_delay=1, max_delay=30)

    def _on_connect(self, client, userdata, flags, reason_code, properties=None) -> None:
        if reason_code != 0:
            log.error("the broker refused the connection, reason %s", reason_code)
            return
        topic = self.settings.mobilelab_mqtt_topic
        client.subscribe(topic, qos=1)
        session_present = bool(getattr(flags, "session_present", False))
        log.info(
            "connected to the broker, subscribed to %s, session_present=%s",
            topic,
            session_present,
        )
        self._publish_status(force=True)

    def _on_disconnect(self, client, userdata, flags=None, reason_code=None, properties=None) -> None:
        if self.stopping.is_set():
            log.info("disconnected from the broker on request")
            return
        log.warning(
            "lost the broker connection, reason %s. paho will reconnect on its own.",
            reason_code,
        )

    def _on_message(self, client, userdata, message: mqtt.MQTTMessage) -> None:
        """Put the message on the queue. Do no work here."""
        try:
            self.inbox.put_nowait((message.topic, message.payload))
        except queue.Full:
            total = self.counters.count_rejected("queue_full")
            log.error(
                "REJECTED | reason=queue_full | detail=the writer queue holds %d "
                "messages and cannot take more | topic=%s | payload=%s | rejected_total=%d",
                self.settings.mobilelab_writer_queue_size,
                message.topic,
                _clip(message.payload.decode("utf-8", errors="replace")),
                total,
            )

    def _publish_status(self, force: bool = False) -> None:
        """Publish the counters as a retained message.

        The local API reads this to answer /health. A retained message means the
        API gets the last known counters the moment it subscribes, even if the
        API started after the writer.

        The topic sits outside station/#, so the writer never reads it back.
        """
        now = time.monotonic()
        if not force and (now - self._last_status) < STATUS_MIN_SECONDS:
            return
        self._last_status = now

        payload = self.counters.snapshot()
        payload.update(
            {
                "queue_depth": self.inbox.qsize(),
                "reported_at": datetime.now(UTC).isoformat().replace("+00:00", "Z"),
                "pid": os.getpid(),
                "version": __version__,
            }
        )
        try:
            self.client.publish(topics.WRITER_STATUS, json.dumps(payload), qos=1, retain=True)
        except Exception as exc:
            log.warning("could not publish the writer status: %s", _one_line(exc))

    def _reject(self, reason: str, detail: str, topic: str, raw: str) -> None:
        total = self.counters.count_rejected(reason)
        log.error(
            "REJECTED | reason=%s | detail=%s | topic=%s | payload=%s | rejected_total=%d",
            reason,
            detail,
            topic,
            _clip(raw),
            total,
        )
        self._publish_status(force=True)

    def _handle(self, topic: str, payload: bytes) -> None:
        raw = payload.decode("utf-8", errors="replace")

        try:
            decoded = json.loads(raw)
        except json.JSONDecodeError as exc:
            self._reject("malformed_json", str(exc), topic, raw)
            return

        if not isinstance(decoded, dict):
            self._reject(
                "not_an_object",
                f"the payload decoded to {type(decoded).__name__}, not an object",
                topic,
                raw,
            )
            return

        try:
            reading = reading_from_message(topic, decoded)
        except TopicMismatch as exc:
            self._reject("topic_payload_mismatch", str(exc), topic, raw)
            return
        except Exception as exc:
            self._reject("schema_invalid", _one_line(exc), topic, raw)
            return

        try:
            check_clock(reading)
        except ImplausibleClock as exc:
            self._reject("implausible_clock", str(exc), topic, raw)
            return

        try:
            new_id = self.database.insert_reading(reading)
        except DataRejected as exc:
            self._reject(exc.reason, exc.detail, topic, raw)
            return
        except DatabaseUnavailable as exc:
            self._reject("database_unavailable", str(exc), topic, raw)
            return

        accepted = self.counters.count_accepted()
        log.info(
            "accepted id=%d %s %s/%s %s%s source=%s accepted_total=%d",
            new_id,
            reading.station_id,
            reading.sensor,
            reading.metric,
            reading.value,
            f" {reading.unit}" if reading.unit else "",
            reading.source,
            accepted,
        )
        self._publish_status()

    def _worker(self) -> None:
        log.info("the worker thread started")
        while True:
            item = self.inbox.get()
            if item is SHUTDOWN_SENTINEL:
                self.inbox.task_done()
                break
            topic, payload = item
            try:
                self._handle(topic, payload)
            except Exception as exc:
                total = self.counters.count_rejected("writer_bug")
                log.exception(
                    "REJECTED | reason=writer_bug | detail=%s | topic=%s | rejected_total=%d",
                    _one_line(exc),
                    topic,
                    total,
                )
            finally:
                self.inbox.task_done()
        log.info("the worker thread stopped")

    def _reporter(self) -> None:
        period = self.settings.mobilelab_writer_report_seconds
        while not self.stopping.wait(period):
            log.info("counters %s queue_depth=%d", self.counters.summary(), self.inbox.qsize())
            self._publish_status(force=True)

    def stop(self, signum: int, frame: FrameType | None) -> None:
        log.info("caught signal %d, stopping", signum)
        self.stopping.set()
        self.client.disconnect()

    def run(self) -> int:
        worker = threading.Thread(target=self._worker, name="writer-worker", daemon=True)
        worker.start()
        reporter = threading.Thread(target=self._reporter, name="writer-reporter", daemon=True)
        reporter.start()

        signal.signal(signal.SIGTERM, self.stop)
        signal.signal(signal.SIGINT, self.stop)

        try:
            self.database.connect()
        except DatabaseUnavailable as exc:
            log.warning("the database is not ready yet: %s. The writer will retry.", exc)

        log.info(
            "connecting to the broker at %s:%d",
            self.settings.mobilelab_mqtt_host,
            self.settings.mobilelab_mqtt_port,
        )
        self.client.connect_async(
            self.settings.mobilelab_mqtt_host,
            self.settings.mobilelab_mqtt_port,
            keepalive=60,
        )

        self.client.loop_forever(retry_first_connection=True)

        self.stopping.set()
        self.inbox.put(SHUTDOWN_SENTINEL)
        worker.join(timeout=10)
        self.database.close()
        log.info("final counters %s", self.counters.summary())
        return 0


def _one_line(exc: Exception) -> str:
    return " ".join(str(exc).split())


def main() -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
        stream=sys.stdout,
    )
    settings = load_settings()
    log.info("mobilelab writer starting")
    writer = Writer(settings)
    return writer.run()


if __name__ == "__main__":
    raise SystemExit(main())
