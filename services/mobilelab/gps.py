"""The GPS driver.

gpsd owns the receiver. This driver owns the MEANING of what the receiver says.

It is a driver like any other. It normalizes, then it publishes to MQTT. It
never writes to readings. The writer stays the only path into the database.

THE ONE THING THIS FILE EXISTS TO GET RIGHT.

    A receiver that is talking is not a receiver that knows where it is.

Indoors this dongle reports happily, sees eight satellites, and uses none of
them. Every sentence arrives with a valid checksum and every sentence says "no
fix". A status indicator that turns green because bytes are arriving would be
green in that state, which is the exact state where the position is worthless.
So the state below is computed from the FIX, never from the connection.

GREEN needs a 3D fix AND four satellites used.

    Four is not a taste. A 3D fix solves four unknowns: x, y, z, and the
    receiver clock bias. Four satellites is the arithmetic minimum to solve
    them. Under four the receiver is not solving, it is holding the last answer
    or extrapolating, and it will still print a latitude. So four is the floor
    below which a printed position is not a measurement.

    A 2D fix is AMBER, not GREEN. A 2D fix drops the altitude unknown to make
    three satellites enough, and folds the leftover error into the horizontal
    position. It prints a lat and lon that can be wrong by a lot.

TIME. HARD RULE 13 APPLIES HERE TOO.

GPS is a clock as well as a position, and it is a better clock than the RTC.
That does not exempt it. A receiver with no fix still prints a time, and a
receiver that has just woken up prints one that is wrong. Every record this
driver builds goes through check_clock before it is published, the same guard a
manual entry gets. A GPS-derived timestamp that fails the guard is dropped and
counted, exactly like any other.

SIMULATION. HARD RULE 3 APPLIES HERE TOO.

gpsfake replays a recorded NMEA log into gpsd through a pseudo-terminal. That is
the only way to see a fix indoors, so the gates use it. It is also the fastest
way to put fabricated positions into the database wearing a real source name,
which is the defect hard rule 3 exists to prevent.

So the guard is structural, not a promise. gpsd reports the device path it read
from. A path under /dev/pts is a pseudo-terminal, which means a program is
feeding it, which means the data is not a measurement. In that state the driver
publishes under gps_simulated (is_real false, drawn dashed) and REFUSES to
publish under gps. It does not warn. It refuses.
"""

from __future__ import annotations

import argparse
import json
import logging
import signal
import socket
import sys
import threading
import time
from datetime import UTC, datetime
from types import FrameType
from typing import Any

import paho.mqtt.client as mqtt

from . import __version__, topics
from .config import Settings, load_settings
from .db import Database, DatabaseUnavailable
from .record import ImplausibleClock, Reading, check_clock

log = logging.getLogger("mobilelab.gps")

DRIVER_VERSION = "1"

GPSD_HOST = "127.0.0.1"
GPSD_PORT = 2947

# nmea:true asks gpsd to pass the raw sentences through beside its own JSON.
#
# THE DRIVER NEEDS ONE NUMBER THAT gpsd WILL NOT GIVE IT: satellites in view.
#
# gpsd builds its SKY report from satellites it can place in the sky, and it
# needs an elevation and an azimuth to place one. Indoors this receiver hears
# satellites but has no almanac yet, so it sends GSV with a signal strength and
# EMPTY elevation and azimuth fields:
#
#     $GPGSV,3,1,09,26,,,34,09,,,33,31,,,30,28,,,24*75
#                     ^^ 9 in view, and not one of them placeable
#
# gpsd therefore counts zero visible and sends no SKY at all, and the panel
# would say "not known" for the number a person waiting outside most wants to
# watch. The third field of GSV is the count, and it is present, so the driver
# reads that one field itself.
#
# It reads ONLY the count in view. "Used" still comes from gpsd, because GSV
# does not say which satellites went into a solution and guessing that is how
# an indicator turns green without a fix.
GPSD_WATCH = b'?WATCH={"enable":true,"json":true,"nmea":true}\n'

SENSOR = "gps"
REAL_SOURCE = "gps"
SIMULATED_SOURCE = "gps_simulated"

# See the module docstring. Four satellites is the arithmetic floor for a 3D fix.
MIN_SATELLITES_USED = 4
MODE_3D = 3
MODE_2D = 2
MODE_NO_FIX = 1

STATE_GREEN = "green"
STATE_AMBER = "amber"
STATE_RED = "red"

# ASD-STE100. Short, active, one idea each. These strings reach the screen.
LABELS = {
    STATE_GREEN: "GPS OK",
    STATE_AMBER: "NO FIX",
    STATE_RED: "NO GPS",
}

MODE_TEXT = {
    0: "Unknown",
    1: "No fix",
    2: "2D fix",
    3: "3D fix",
}

# A pseudo-terminal is a program pretending to be a receiver.
PTY_PREFIX = "/dev/pts/"


class GpsdUnavailable(Exception):
    """gpsd did not answer. That is a RED state, not a crash."""


def fix_state(mode: int | None, satellites_used: int | None, min_satellites: int) -> str:
    """Turn what the receiver knows into what the screen shows.

    This function is the whole rule, and it takes no argument about whether the
    receiver is connected. A caller that has heard nothing reports RED without
    asking this. Everything this function sees is already talking, so the only
    question left is whether it knows where it is.
    """
    if mode is None or satellites_used is None:
        return STATE_AMBER
    if mode >= MODE_3D and satellites_used >= min_satellites:
        return STATE_GREEN
    return STATE_AMBER


class Reader(threading.Thread):
    """Hold one connection to gpsd and keep the newest report.

    It runs forever. A gpsd that goes away is not an error here, it is a state,
    and the state is RED. The thread reconnects on its own so that the indicator
    recovers with no help when the dongle comes back.
    """

    def __init__(self, host: str, port: int, stopping: threading.Event) -> None:
        super().__init__(name="gpsd-reader", daemon=True)
        self.host = host
        self.port = port
        self.stopping = stopping

        self._lock = threading.Lock()
        self.connected = False
        self.reports = 0
        self.last_report_at: float | None = None
        self.tpv: dict[str, Any] = {}
        self.sky: dict[str, Any] = {}
        self.device: str | None = None
        self.last_fix_at: str | None = None
        self.gsv_in_view: int | None = None

    def snapshot(self) -> dict[str, Any]:
        with self._lock:
            return {
                "connected": self.connected,
                "reports": self.reports,
                "last_report_at": self.last_report_at,
                "tpv": dict(self.tpv),
                "sky": dict(self.sky),
                "device": self.device,
                "last_fix_at": self.last_fix_at,
                "gsv_in_view": self.gsv_in_view,
            }

    def run(self) -> None:
        while not self.stopping.is_set():
            try:
                self._session()
            except Exception as exc:
                log.warning("the gpsd connection failed: %s", exc)
            with self._lock:
                self.connected = False
            self.stopping.wait(2.0)

    def _session(self) -> None:
        with socket.create_connection((self.host, self.port), timeout=5) as sock:
            sock.sendall(GPSD_WATCH)
            with self._lock:
                self.connected = True
            log.info("watching gpsd at %s:%d", self.host, self.port)

            sock.settimeout(2.0)
            buffer = b""
            while not self.stopping.is_set():
                try:
                    chunk = sock.recv(4096)
                except socket.timeout:
                    continue
                if not chunk:
                    raise GpsdUnavailable("gpsd closed the connection")
                buffer += chunk
                while b"\n" in buffer:
                    line, buffer = buffer.split(b"\n", 1)
                    self._take(line)

    def _take(self, line: bytes) -> None:
        text = line.strip()
        if not text:
            return

        # A raw NMEA sentence, passed through by gpsd. Only GSV is read here.
        if text.startswith(b"$"):
            self._take_nmea(text)
            return

        try:
            report = json.loads(text)
        except json.JSONDecodeError:
            return
        if not isinstance(report, dict):
            return

        kind = report.get("class")
        if kind not in ("TPV", "SKY", "DEVICE", "DEVICES"):
            return

        with self._lock:
            self.reports += 1
            self.last_report_at = time.monotonic()

            if kind == "TPV":
                self.tpv = report
                if report.get("mode", 0) >= MODE_2D and report.get("time"):
                    self.last_fix_at = str(report["time"])
            elif kind == "SKY":
                self.sky = report
            elif kind == "DEVICES":
                devices = report.get("devices") or []
                if devices and isinstance(devices[0], dict):
                    self.device = devices[0].get("path")
            elif kind == "DEVICE":
                self.device = report.get("path") or self.device

            path = report.get("device")
            if isinstance(path, str) and path:
                self.device = path

    def _take_nmea(self, sentence: bytes) -> None:
        """Read the satellites-in-view count out of a GSV sentence.

        $GPGSV,<messages>,<message number>,<in view>,<per satellite fields...>

        The checksum is verified first. An unverified count is worse than no
        count, because a corrupt digit would put a confident wrong number on
        screen. This receiver is on a PL2303 that has produced corrupt bytes
        before, so the check is not decoration.
        """
        try:
            text = sentence.decode("ascii", errors="strict")
        except UnicodeDecodeError:
            return
        if "*" not in text or "GSV" not in text[:7]:
            return

        body, _, tail = text[1:].partition("*")
        want = tail[:2]
        got = 0
        for char in body:
            got ^= ord(char)
        try:
            if got != int(want, 16):
                return
        except ValueError:
            return

        parts = body.split(",")
        if len(parts) < 4 or not parts[3].isdigit():
            return
        with self._lock:
            self.gsv_in_view = int(parts[3])


class Driver:
    def __init__(self, settings: Settings, args: argparse.Namespace) -> None:
        self.settings = settings
        self.args = args
        self.station_id = args.station_id or settings.mobilelab_station_id
        self.stopping = threading.Event()

        self.reader = Reader(args.gpsd_host, args.gpsd_port, self.stopping)

        self.readings_published = 0
        self.rejected_by_clock = 0
        self.refused_simulated = 0
        self.last_publish_at: float | None = None
        self._source_checked: set[str] = set()
        self._last_state: str | None = None

        self.client = mqtt.Client(
            mqtt.CallbackAPIVersion.VERSION2, client_id="mobilelab-gps"
        )
        self.client.reconnect_delay_set(min_delay=1, max_delay=30)
        # The retained status is the last thing the driver said. If the driver
        # dies, that message stays on the broker, so it MUST carry a timestamp.
        # The API ages it and calls a stale status RED. Without that, a dead
        # driver would leave a cheerful AMBER frozen on the screen forever.
        self.client.will_set(
            topics.GPS_STATUS,
            json.dumps(self._offline_status()),
            qos=1,
            retain=True,
        )

    def _offline_status(self) -> dict[str, Any]:
        return {
            "state": STATE_RED,
            "label": LABELS[STATE_RED],
            "detail": "The GPS driver stopped.",
            "driver_running": False,
            "reported_at": _now_iso(),
            "driver_version": DRIVER_VERSION,
        }

    # ---- the meaning ----------------------------------------------------

    def build_status(self) -> dict[str, Any]:
        """Describe the receiver in the terms the screen uses."""
        snap = self.reader.snapshot()
        tpv = snap["tpv"]
        sky = snap["sky"]

        age = None
        if snap["last_report_at"] is not None:
            age = time.monotonic() - snap["last_report_at"]

        satellites_seen = sky.get("nSat")
        satellites_used = sky.get("uSat")
        if satellites_used is None and isinstance(sky.get("satellites"), list):
            satellites_used = sum(1 for sat in sky["satellites"] if sat.get("used"))
            satellites_seen = len(sky["satellites"])

        # gpsd sends no SKY while it cannot place the satellites in the sky, so
        # fall back to the count GSV states directly. See GPSD_WATCH above.
        if not satellites_seen and snap["gsv_in_view"] is not None:
            satellites_seen = snap["gsv_in_view"]

        mode = tpv.get("mode")

        # No GSV, no SKY, so no satellite count. That is the state this receiver
        # sits in indoors: it stops sending GSV once it is hearing nothing worth
        # reporting, and gpsd has nothing to build a SKY report from.
        #
        # "Not known" is the wrong word for the screen there. A receiver that
        # reports no fix used zero satellites to reach that answer, by the
        # definition of a fix rather than by a guess. So the count is 0.
        #
        # This can never manufacture a GREEN. It only fills in a count when the
        # receiver has ALREADY said it has no fix, and no fix is amber whatever
        # the count says.
        if satellites_used is None and mode is not None and mode <= MODE_NO_FIX:
            satellites_used = 0

        # RED is about silence, not about the fix. Three ways to be silent:
        # gpsd is not there, gpsd is there but has told us nothing, or gpsd has
        # gone quiet because the dongle was pulled.
        silent = (
            not snap["connected"]
            or snap["last_report_at"] is None
            or (age is not None and age > self.args.stale_seconds)
        )

        if silent:
            state = STATE_RED
            if not snap["connected"]:
                detail = "The station cannot reach gpsd."
            elif snap["last_report_at"] is None:
                detail = "gpsd has no data from a receiver."
            else:
                detail = f"The receiver stopped {age:.0f} seconds ago."
        else:
            state = fix_state(mode, satellites_used, self.args.min_satellites)
            if state == STATE_GREEN:
                detail = f"The receiver has a 3D fix on {satellites_used} satellites."
            elif mode == MODE_2D:
                detail = "The receiver has a 2D fix. A 2D fix is not accurate enough."
            elif satellites_seen:
                detail = (
                    f"The receiver sees {satellites_seen} satellites and uses "
                    f"{satellites_used or 0}. It needs {self.args.min_satellites}."
                )
            else:
                detail = "The receiver looks for satellites."

        device = snap["device"]
        simulated = bool(device and device.startswith(PTY_PREFIX))

        # A silent receiver has no CURRENT anything.
        #
        # gpsd's last TPV and SKY stay in memory after the receiver stops
        # talking, so without this the panel goes on showing "3D fix, 3
        # satellites" beside a red badge that says NO GPS. Measured on this
        # station while the dongle was failing: the badge went red and the
        # satellite count sat at 3 for four minutes.
        #
        # The position and the time of the last fix are kept, because those two
        # are labelled as history on the screen and a last known position is
        # worth having. The live numbers are not history, so they go.
        if silent:
            mode = None
            satellites_used = None
            satellites_seen = None
            sky = {}

        return {
            "state": state,
            "label": LABELS[state],
            "detail": detail,
            "driver_running": True,
            "simulated": simulated,
            "fix": {
                "mode": mode,
                "mode_text": MODE_TEXT.get(mode or 0, "Unknown"),
                "satellites_used": satellites_used,
                "satellites_seen": satellites_seen,
                "hdop": sky.get("hdop"),
            },
            "position": {
                "lat": tpv.get("lat"),
                "lon": tpv.get("lon"),
                "alt_m": tpv.get("altHAE", tpv.get("alt")),
            },
            "last_fix_at": snap["last_fix_at"],
            "gps_time": tpv.get("time"),
            "device": device,
            "gpsd": {
                "connected": snap["connected"],
                "host": f"{self.args.gpsd_host}:{self.args.gpsd_port}",
                "reports": snap["reports"],
                "seconds_since_report": round(age, 1) if age is not None else None,
            },
            "threshold": {
                "min_satellites_used": self.args.min_satellites,
                "requires_3d": True,
                "why": (
                    "A 3D fix solves four unknowns, so it needs four satellites. "
                    "Below four the receiver prints a position it did not solve."
                ),
            },
            "published": {
                "readings_total": self.readings_published,
                "rejected_by_clock": self.rejected_by_clock,
                "refused_simulated": self.refused_simulated,
                "seconds_since_publish": (
                    round(time.monotonic() - self.last_publish_at, 1)
                    if self.last_publish_at is not None
                    else None
                ),
            },
            "station_id": self.station_id,
            "driver_version": DRIVER_VERSION,
            "api_version": __version__,
            "reported_at": _now_iso(),
        }

    # ---- the source guard ------------------------------------------------

    def source_for(self, simulated: bool) -> str | None:
        """Choose the source name, and refuse a wrong one.

        A pseudo-terminal means a program is feeding gpsd. The data is not a
        measurement, so it cannot carry a source with is_real true.
        """
        wanted = self.args.source

        if simulated:
            if wanted != SIMULATED_SOURCE:
                self.refused_simulated += 1
                log.error(
                    "REFUSING TO PUBLISH: gpsd is reading a pseudo-terminal, so this "
                    "data is fed by a program and is not a measurement. The source %r "
                    "cannot carry it. Run the driver with --source %s.",
                    wanted,
                    SIMULATED_SOURCE,
                )
                return None
            return SIMULATED_SOURCE

        if wanted == SIMULATED_SOURCE:
            # The reverse mistake is harmless to the truth of the data, but it
            # would draw a real measurement as dashed and label it fake. Say so.
            log.warning(
                "gpsd is reading a real device but --source is %s. The position is "
                "real and it will be drawn as simulated.",
                SIMULATED_SOURCE,
            )
        return wanted

    def check_source_once(self, source: str) -> bool:
        """Confirm the source exists before the first publish under it.

        This mirrors the fixture. It runs lazily and never at start, because a
        slow database at boot must not stop the indicator. The indicator is the
        recovery-critical part. Readings can wait.
        """
        if source in self._source_checked:
            return True

        database = Database(self.settings.dsn())
        try:
            is_real = database.source_is_real(source)
        except DatabaseUnavailable as exc:
            log.warning("the source check could not run, so no reading is published: %s", exc)
            return False
        finally:
            database.close()

        if is_real is None:
            log.error(
                "REFUSING TO PUBLISH: the source %r is not in public.sources. "
                "Add it with a numbered migration first.",
                source,
            )
            return False

        if source == SIMULATED_SOURCE and is_real:
            log.error(
                "REFUSING TO PUBLISH: the source %r has is_real true. Simulated "
                "position must never carry a real source name.",
                source,
            )
            return False

        self._source_checked.add(source)
        log.info("the source %r is known, publishing is permitted", source)
        return True

    # ---- publishing -------------------------------------------------------

    def records_from(self, status: dict[str, Any], source: str) -> list[dict[str, Any]]:
        """Build the common record shape, one record per measurement.

        Position only. This driver does not stamp GPS onto anybody else's
        reading, and binding position to an observation is a later task.
        """
        lat = status["position"]["lat"]
        lon = status["position"]["lon"]
        if lat is None or lon is None:
            return []

        stamp = status.get("gps_time") or _now_iso()
        provenance = {
            "driver": "mobilelab.gps",
            "version": DRIVER_VERSION,
            "device": status.get("device"),
            "fix_mode": status["fix"]["mode"],
            "satellites_used": status["fix"]["satellites_used"],
            "hdop": status["fix"]["hdop"],
            "time_from": "gps" if status.get("gps_time") else "system",
        }
        common = {
            "station_id": self.station_id,
            "ts": stamp,
            "lat": lat,
            "lon": lon,
            "source": source,
            "provenance": provenance,
        }

        records = [
            {**common, "sensor": SENSOR, "metric": "latitude", "value": lat, "unit": "deg"},
            {**common, "sensor": SENSOR, "metric": "longitude", "value": lon, "unit": "deg"},
            {
                **common,
                "sensor": SENSOR,
                "metric": "satellites_used",
                "value": float(status["fix"]["satellites_used"] or 0),
                "unit": "count",
            },
        ]

        altitude = status["position"]["alt_m"]
        if altitude is not None:
            records.append(
                {**common, "sensor": SENSOR, "metric": "altitude", "value": altitude, "unit": "m"}
            )

        hdop = status["fix"]["hdop"]
        if hdop is not None:
            records.append(
                {**common, "sensor": SENSOR, "metric": "hdop", "value": hdop, "unit": "ratio"}
            )

        return records

    def publish_readings(self, status: dict[str, Any]) -> int:
        """Publish position, but only from a fix worth trusting.

        AMBER publishes nothing. A position from an unsolved fix is not a
        measurement, and a row in readings is a claim that it was.
        """
        if status["state"] != STATE_GREEN:
            return 0

        source = self.source_for(status["simulated"])
        if source is None:
            return 0
        if not self.check_source_once(source):
            return 0

        sent = 0
        for payload in self.records_from(status, source):
            # HARD RULE 13. GPS time is a time source. It is not an exemption.
            try:
                reading = Reading.model_validate(payload)
                check_clock(reading)
            except ImplausibleClock as exc:
                self.rejected_by_clock += 1
                log.error(
                    "reason=implausible_clock the GPS timestamp is not usable: %s payload=%s",
                    exc,
                    json.dumps(payload, default=str)[:1000],
                )
                continue
            except Exception as exc:
                log.error("the GPS record did not validate: %s payload=%s", exc, payload)
                continue

            topic = f"station/{self.station_id}/{SENSOR}/{reading.metric}"
            info = self.client.publish(topic, json.dumps(payload, default=str), qos=1)
            info.wait_for_publish(timeout=10)
            sent += 1

        if sent:
            self.readings_published += sent
            self.last_publish_at = time.monotonic()
        return sent

    def publish_status(self, status: dict[str, Any]) -> None:
        self.client.publish(
            topics.GPS_STATUS, json.dumps(status, default=str), qos=1, retain=True
        )

    # ---- the loop ---------------------------------------------------------

    def run(self) -> int:
        self.client.connect(self.args.mqtt_host, self.args.mqtt_port, keepalive=30)
        self.client.loop_start()
        self.reader.start()

        log.info(
            "the GPS driver is running. GREEN needs a 3D fix on %d satellites.",
            self.args.min_satellites,
        )

        next_reading = 0.0
        try:
            while not self.stopping.is_set():
                status = self.build_status()
                self.publish_status(status)

                if status["state"] != self._last_state:
                    log.info(
                        "the GPS state is %s. %s", status["state"].upper(), status["detail"]
                    )
                    self._last_state = status["state"]

                now = time.monotonic()
                if now >= next_reading:
                    if self.publish_readings(status):
                        next_reading = now + self.args.publish_seconds
                    else:
                        next_reading = now + self.args.status_seconds

                self.stopping.wait(self.args.status_seconds)
        finally:
            self.publish_status(self._offline_status())
            time.sleep(0.3)
            self.client.loop_stop()
            self.client.disconnect()

        return 0

    def stop(self, signum: int, frame: FrameType | None) -> None:
        log.info("signal %d received, stopping", signum)
        self.stopping.set()


def _now_iso() -> str:
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m mobilelab.gps",
        description="Read gpsd and publish position to MQTT.",
    )
    parser.add_argument("--gpsd-host", default=GPSD_HOST)
    parser.add_argument("--gpsd-port", type=int, default=GPSD_PORT)
    parser.add_argument("--mqtt-host", default=None)
    parser.add_argument("--mqtt-port", type=int, default=None)
    parser.add_argument("--station-id", default=None)
    parser.add_argument(
        "--source",
        default=REAL_SOURCE,
        help=(
            "The source name for published position. A pseudo-terminal forces "
            f"{SIMULATED_SOURCE} whatever this says."
        ),
    )
    parser.add_argument(
        "--min-satellites",
        type=int,
        default=MIN_SATELLITES_USED,
        help="Satellites used before the state is GREEN. Four is the arithmetic floor.",
    )
    parser.add_argument(
        "--status-seconds",
        type=float,
        default=3.0,
        help="How often the status goes to MQTT.",
    )
    parser.add_argument(
        "--publish-seconds",
        type=float,
        default=60.0,
        help="How often a position lands in readings, while the fix holds.",
    )
    parser.add_argument(
        "--stale-seconds",
        type=float,
        default=15.0,
        help="Silence for longer than this is RED.",
    )
    parser.add_argument(
        "--once",
        action="store_true",
        help="Print one status as JSON and exit. Publish nothing.",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
        stream=sys.stderr,
    )
    args = build_parser().parse_args(argv)
    settings = load_settings()
    args.mqtt_host = args.mqtt_host or settings.mobilelab_mqtt_host
    args.mqtt_port = args.mqtt_port or settings.mobilelab_mqtt_port

    driver = Driver(settings, args)

    if args.once:
        driver.reader.start()
        # Give gpsd a moment to send the first TPV and SKY. A poll that answers
        # before the receiver has spoken would report RED and mean nothing.
        time.sleep(args.stale_seconds if args.stale_seconds < 6 else 6)
        status = driver.build_status()
        driver.stopping.set()
        print(json.dumps(status, indent=2, sort_keys=True, default=str))
        return 0

    signal.signal(signal.SIGTERM, driver.stop)
    signal.signal(signal.SIGINT, driver.stop)
    return driver.run()


if __name__ == "__main__":
    raise SystemExit(main())
