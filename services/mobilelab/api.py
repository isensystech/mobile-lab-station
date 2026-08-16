"""The local API.

It serves history over REST and live readings over a websocket. Architecture
section 2 locks that split, and open decision 2 chose FastAPI.

Two rules shape every response that carries readings.

1. A series always carries is_real and render_hint. The response model makes
   those fields required, so the API cannot return a series without them. The
   kiosk must never make a second call to learn what is simulated.

2. An unknown source is treated as NOT real. A source that is missing from the
   sources table gets is_real false and a dashed render hint. The safe default
   is to look simulated, because the failure that matters is fake data that
   looks real.
"""

from __future__ import annotations

import asyncio
import json
import logging
import threading
from contextlib import asynccontextmanager
from pathlib import Path
from datetime import UTC, datetime, timedelta
from typing import Any, Literal

import paho.mqtt.client as mqtt
from fastapi import FastAPI, HTTPException, Query, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool
from pydantic import BaseModel, Field

from . import __version__, topics
from .config import load_settings
from .record import parse_topic
from .series import (
    SERIES_META_SQL,
    SOURCES_SQL,
    choose_relation,
    pair_sql,
    series_sql,
)

log = logging.getLogger("mobilelab.api")

WRITER_STALE_SECONDS = 60.0
LIVE_QUEUE_SIZE = 200
MAX_SPAN = timedelta(days=400)

UNKNOWN_SOURCE = {"is_real": False, "render_hint": "dashed", "known": False}


class Point(BaseModel):
    ts: datetime
    value: float | None


class SeriesBase(BaseModel):
    """Every series carries its labelling. These fields are not optional."""

    sensor: str
    metric: str
    source: str
    unit: str | None
    is_real: bool
    render_hint: Literal["solid", "dashed"]
    source_known: bool = True
    provenance: dict[str, Any] | None = None


class HistorySeries(SeriesBase):
    point_count: int
    points: list[Point]


class AlignedSeries(SeriesBase):
    key: Literal["a", "b"]
    values: list[float | None]


class HistoryResponse(BaseModel):
    station_id: str
    start: datetime = Field(serialization_alias="from")
    end: datetime = Field(serialization_alias="to")
    served_from: str
    bucket: str | None
    series: list[HistorySeries]
    explain: list[str] | None = None
    caption: str = "Correlation is not causation."


class PairResponse(BaseModel):
    station_id: str
    start: datetime = Field(serialization_alias="from")
    end: datetime = Field(serialization_alias="to")
    served_from: str
    bucket: str | None
    axis: list[datetime]
    series: list[AlignedSeries]
    explain: list[str] | None = None
    caption: str = "Correlation is not causation."


class SourceRow(BaseModel):
    source: str
    kind: str
    is_real: bool
    render_hint: str
    description: str


class SourceCache:
    """The sources table, held in memory.

    The MQTT thread reads this for every live message, so it must not hit the
    database on that path.
    """

    def __init__(self, pool: ConnectionPool) -> None:
        self._pool = pool
        self._lock = threading.Lock()
        self._rows: dict[str, dict] = {}

    def refresh(self) -> None:
        with self._pool.connection() as conn, conn.cursor(row_factory=dict_row) as cur:
            cur.execute(SOURCES_SQL)
            rows = {row["source"]: dict(row) for row in cur.fetchall()}
        with self._lock:
            self._rows = rows
        log.info("loaded %d sources", len(rows))

    def all(self) -> list[dict]:
        with self._lock:
            return list(self._rows.values())

    def label(self, source: str) -> dict:
        """Return the labelling for a source. An unknown source is not real."""
        with self._lock:
            row = self._rows.get(source)
        if row is None:
            return dict(UNKNOWN_SOURCE)
        return {"is_real": row["is_real"], "render_hint": row["render_hint"], "known": True}


class LiveHub:
    """Fans MQTT messages out to every open websocket.

    The MQTT thread must never block. A websocket that cannot keep up loses
    messages instead of stalling the broker loop.
    """

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._subscribers: set[asyncio.Queue] = set()
        self.loop: asyncio.AbstractEventLoop | None = None
        self.dropped = 0

    def register(self) -> asyncio.Queue:
        channel: asyncio.Queue = asyncio.Queue(maxsize=LIVE_QUEUE_SIZE)
        with self._lock:
            self._subscribers.add(channel)
        return channel

    def unregister(self, channel: asyncio.Queue) -> None:
        with self._lock:
            self._subscribers.discard(channel)

    def subscriber_count(self) -> int:
        with self._lock:
            return len(self._subscribers)

    def publish_threadsafe(self, message: dict) -> None:
        loop = self.loop
        if loop is None:
            return
        with self._lock:
            targets = list(self._subscribers)
        for channel in targets:
            loop.call_soon_threadsafe(self._offer, channel, message)

    def _offer(self, channel: asyncio.Queue, message: dict) -> None:
        try:
            channel.put_nowait(message)
        except asyncio.QueueFull:
            self.dropped += 1


class State:
    def __init__(self) -> None:
        self.settings = load_settings()
        self.pool: ConnectionPool | None = None
        self.sources: SourceCache | None = None
        self.hub = LiveHub()
        self.mqtt: mqtt.Client | None = None
        self.broker_connected = False
        self.writer_status: dict | None = None


state = State()


def _on_connect(client, userdata, flags, reason_code, properties=None) -> None:
    if reason_code != 0:
        log.error("the broker refused the API connection, reason %s", reason_code)
        return
    state.broker_connected = True
    client.subscribe(topics.READINGS_WILDCARD, qos=1)
    client.subscribe(topics.WRITER_STATUS, qos=1)
    log.info("the API connected to the broker and subscribed")


def _on_disconnect(client, userdata, flags=None, reason_code=None, properties=None) -> None:
    state.broker_connected = False
    log.warning("the API lost the broker connection, reason %s", reason_code)


def _on_message(client, userdata, message: mqtt.MQTTMessage) -> None:
    raw = message.payload.decode("utf-8", errors="replace")

    if message.topic == topics.WRITER_STATUS:
        try:
            state.writer_status = json.loads(raw)
        except json.JSONDecodeError:
            log.warning("the writer status was not JSON")
        return

    try:
        payload = json.loads(raw)
    except json.JSONDecodeError:
        return
    if not isinstance(payload, dict):
        return

    from_topic = parse_topic(message.topic) or {}
    source = str(payload.get("source", ""))
    label = state.sources.label(source) if state.sources else dict(UNKNOWN_SOURCE)

    state.hub.publish_threadsafe(
        {
            "station_id": payload.get("station_id") or from_topic.get("station_id"),
            "sensor": payload.get("sensor") or from_topic.get("sensor"),
            "metric": payload.get("metric") or from_topic.get("metric"),
            "value": payload.get("value"),
            "unit": payload.get("unit"),
            "ts": payload.get("ts"),
            "source": source,
            "is_real": label["is_real"],
            "render_hint": label["render_hint"],
            "source_known": label["known"],
            "received_at": datetime.now(UTC).isoformat().replace("+00:00", "Z"),
        }
    )


@asynccontextmanager
async def lifespan(app: FastAPI):
    settings = state.settings
    state.hub.loop = asyncio.get_running_loop()

    # check=check_connection runs a cheap probe before the pool hands a
    # connection out, and replaces it if the probe fails.
    #
    # Without it, a PostgreSQL restart leaves dead connections in the pool. The
    # next request then fails with AdminShutdown and the API answers 500, even
    # though the database is healthy again. The writer already retries on its
    # own. The API needs the same care.
    state.pool = ConnectionPool(
        settings.dsn(),
        min_size=1,
        max_size=4,
        check=ConnectionPool.check_connection,
        open=True,
    )
    state.sources = SourceCache(state.pool)
    state.sources.refresh()

    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id="mobilelab-api")
    client.on_connect = _on_connect
    client.on_disconnect = _on_disconnect
    client.on_message = _on_message
    client.reconnect_delay_set(min_delay=1, max_delay=30)
    client.connect_async(settings.mobilelab_mqtt_host, settings.mobilelab_mqtt_port, keepalive=60)
    client.loop_start()
    state.mqtt = client

    log.info("the API is ready on %s:%d", settings.mobilelab_api_host, settings.mobilelab_api_port)
    yield

    client.loop_stop()
    client.disconnect()
    if state.pool is not None:
        state.pool.close()


app = FastAPI(
    title="Mobile Lab Station local API",
    version=__version__,
    lifespan=lifespan,
    description=(
        "History over REST and live readings over a websocket. "
        "Every series carries is_real and render_hint."
    ),
)


def _window(start: datetime | None, end: datetime | None) -> tuple[datetime, datetime]:
    end = end or datetime.now(UTC)
    start = start or (end - timedelta(hours=24))
    if start.tzinfo is None or end.tzinfo is None:
        raise HTTPException(400, "from and to need a timezone. Use a Z suffix.")
    if start >= end:
        raise HTTPException(400, "from must be earlier than to.")
    if (end - start) > MAX_SPAN:
        raise HTTPException(400, "the range is longer than 400 days.")
    return start, end


def _explain(sql: str, params: dict) -> list[str]:
    with state.pool.connection() as conn, conn.cursor() as cur:
        cur.execute(f"explain (analyze, costs off, timing off, summary off) {sql}", params)
        return [row[0] for row in cur.fetchall()]


@app.get("/health")
def health() -> dict[str, Any]:
    database_ok = False
    try:
        with state.pool.connection() as conn, conn.cursor() as cur:
            cur.execute("select 1")
            database_ok = cur.fetchone()[0] == 1
    except Exception as exc:
        log.warning("the health check could not reach the database: %s", exc)

    writer: dict[str, Any] | None = None
    if state.writer_status is not None:
        writer = dict(state.writer_status)
        age = None
        reported = writer.get("reported_at")
        if reported:
            try:
                stamp = datetime.fromisoformat(str(reported).replace("Z", "+00:00"))
                age = (datetime.now(UTC) - stamp).total_seconds()
            except ValueError:
                age = None
        writer["age_seconds"] = age
        writer["stale"] = age is None or age > WRITER_STALE_SECONDS

    healthy = database_ok and state.broker_connected and writer is not None and not writer["stale"]

    return {
        "status": "ok" if healthy else "degraded",
        "api": {"version": __version__, "websocket_clients": state.hub.subscriber_count()},
        "database": {"connected": database_ok},
        "broker": {"connected": state.broker_connected},
        "writer": writer,
    }


STATIC_DIR = Path(__file__).resolve().parent / "static"
app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")


@app.get("/", include_in_schema=False)
def chart_page() -> FileResponse:
    """The demo screen. A person who types the bare address wants the chart."""
    return FileResponse(STATIC_DIR / "index.html")


@app.get("/chart", include_in_schema=False)
def chart_page_alias() -> FileResponse:
    return FileResponse(STATIC_DIR / "index.html")


@app.get("/selftest", include_in_schema=False)
def selftest_page() -> FileResponse:
    """Runs the chart provenance rules against broken input, in the browser."""
    return FileResponse(STATIC_DIR / "selftest.html")


@app.get("/api/sources", response_model=list[SourceRow])
def list_sources() -> list[dict]:
    return state.sources.all()


@app.get("/api/stations")
def list_stations() -> list[dict]:
    with state.pool.connection() as conn, conn.cursor(row_factory=dict_row) as cur:
        cur.execute("select station_id, label from public.stations order by station_id")
        return [dict(row) for row in cur.fetchall()]


@app.get("/api/readings", response_model=HistoryResponse, response_model_by_alias=True)
def readings(
    sensor: str,
    metric: str,
    station_id: str | None = None,
    source: str | None = None,
    start: datetime | None = Query(None, alias="from"),
    end: datetime | None = Query(None, alias="to"),
    explain: bool = False,
) -> HistoryResponse:
    station_id = station_id or state.settings.mobilelab_station_id
    start, end = _window(start, end)
    relation = choose_relation(end - start)

    params: dict[str, Any] = {
        "station_id": station_id,
        "sensor": sensor,
        "metric": metric,
        "start": start,
        "end": end,
    }
    if source is not None:
        params["source"] = source

    sql = series_sql(relation, with_source=source is not None)

    with state.pool.connection() as conn, conn.cursor(row_factory=dict_row) as cur:
        cur.execute(sql, params)
        rows = cur.fetchall()

    grouped: dict[str, dict] = {}
    for row in rows:
        bucket = grouped.setdefault(
            row["source"],
            {
                "sensor": sensor,
                "metric": metric,
                "source": row["source"],
                "unit": row["unit"],
                "is_real": row["is_real"],
                "render_hint": row["render_hint"],
                "source_known": True,
                "provenance": row.get("provenance"),
                "points": [],
            },
        )
        if bucket["provenance"] is None and row.get("provenance") is not None:
            bucket["provenance"] = row["provenance"]
        bucket["points"].append(Point(ts=row["ts"], value=row["value"]))

    series = [
        HistorySeries(**dict(entry, point_count=len(entry["points"])))
        for entry in grouped.values()
    ]

    return HistoryResponse(
        station_id=station_id,
        start=start,
        end=end,
        served_from=relation.name,
        bucket=relation.bucket,
        series=series,
        explain=_explain(sql, params) if explain else None,
    )


@app.get("/api/series/pair", response_model=PairResponse, response_model_by_alias=True)
def series_pair(
    a_sensor: str,
    a_metric: str,
    a_source: str,
    b_sensor: str,
    b_metric: str,
    b_source: str,
    station_id: str | None = None,
    start: datetime | None = Query(None, alias="from"),
    end: datetime | None = Query(None, alias="to"),
    explain: bool = False,
) -> PairResponse:
    """Return two metrics on one shared time axis, for the overlay chart."""
    station_id = station_id or state.settings.mobilelab_station_id
    start, end = _window(start, end)
    relation = choose_relation(end - start)

    params: dict[str, Any] = {
        "station_id": station_id,
        "a_sensor": a_sensor,
        "a_metric": a_metric,
        "a_source": a_source,
        "b_sensor": b_sensor,
        "b_metric": b_metric,
        "b_source": b_source,
        "start": start,
        "end": end,
    }
    sql = pair_sql(relation)

    with state.pool.connection() as conn, conn.cursor(row_factory=dict_row) as cur:
        cur.execute(sql, params)
        rows = cur.fetchall()

        meta = {}
        for key, sensor, metric, source in (
            ("a", a_sensor, a_metric, a_source),
            ("b", b_sensor, b_metric, b_source),
        ):
            cur.execute(
                SERIES_META_SQL,
                {
                    "station_id": station_id,
                    "sensor": sensor,
                    "metric": metric,
                    "source": source,
                },
            )
            found = cur.fetchone()
            label = state.sources.label(source)
            meta[key] = {
                "key": key,
                "sensor": sensor,
                "metric": metric,
                "source": source,
                "unit": found["unit"] if found else None,
                "is_real": found["is_real"] if found else label["is_real"],
                "render_hint": found["render_hint"] if found else label["render_hint"],
                "source_known": label["known"],
                "provenance": found["provenance"] if found else None,
            }

    axis = [row["ts"] for row in rows]
    meta["a"]["values"] = [row["a_value"] for row in rows]
    meta["b"]["values"] = [row["b_value"] for row in rows]

    return PairResponse(
        station_id=station_id,
        start=start,
        end=end,
        served_from=relation.name,
        bucket=relation.bucket,
        axis=axis,
        series=[AlignedSeries(**meta["a"]), AlignedSeries(**meta["b"])],
        explain=_explain(sql, params) if explain else None,
    )


@app.websocket("/ws/live")
async def live(websocket: WebSocket) -> None:
    await websocket.accept()
    channel = state.hub.register()
    log.info("a websocket client joined, %d open", state.hub.subscriber_count())
    try:
        await websocket.send_json(
            {
                "type": "hello",
                "message": "Live readings follow. Every reading carries is_real and render_hint.",
                "caption": "Correlation is not causation.",
            }
        )
        while True:
            reading = await channel.get()
            await websocket.send_json({"type": "reading", **reading})
    except WebSocketDisconnect:
        pass
    except Exception as exc:
        log.warning("a websocket client failed: %s", exc)
    finally:
        state.hub.unregister(channel)
        log.info("a websocket client left, %d open", state.hub.subscriber_count())


def main() -> int:
    import uvicorn

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    settings = state.settings
    uvicorn.run(
        app,
        host=settings.mobilelab_api_host,
        port=settings.mobilelab_api_port,
        log_level="info",
        access_log=True,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
