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
import csv
import io
import json
import logging
import subprocess
import threading
import time
from contextlib import asynccontextmanager
from pathlib import Path
from datetime import UTC, datetime, timedelta
from typing import Any, Literal

import paho.mqtt.client as mqtt
import psycopg
from fastapi import FastAPI, HTTPException, Query, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse, PlainTextResponse
from fastapi.staticfiles import StaticFiles
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool
from pydantic import BaseModel, Field

from . import __version__, entry, kb, metrics, suite, topics
from .config import load_settings
from .record import CLOCK_FLOOR, CLOCK_FUTURE_LIMIT, parse_topic
from .series import (
    MAX_SERIES,
    SERIES_META_SQL,
    SOURCES_SQL,
    choose_relation,
    multi_sql,
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
    render_hint: Literal["solid", "dashed", "stepped"]
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


class MultiSeries(SeriesBase):
    """One series on the shared axis, for the N series endpoint."""

    key: str
    name: str
    values: list[float | None]


class MultiResponse(BaseModel):
    station_id: str
    start: datetime = Field(serialization_alias="from")
    end: datetime = Field(serialization_alias="to")
    served_from: str
    bucket: str | None
    axis: list[datetime]
    series: list[MultiSeries]
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


@app.middleware("http")
async def no_stale_screen(request: Request, call_next):
    """Never let the kiosk show a stale screen after a deploy.

    The kiosk browser runs for days and caches what it is given. A deploy that
    changes the stylesheet or a script would then reach the database and the API
    but not the glass, and the screen would keep the old look with no clue why.

    The station serves one browser on the same machine, so caching buys nothing
    and costs confusion.
    """
    response = await call_next(request)
    path = request.url.path
    if path.startswith("/static") or path in ("/", "/chart", "/entry", "/knowledge", "/sensors", "/selftest"):
        response.headers["Cache-Control"] = "no-store, must-revalidate"
        response.headers["Pragma"] = "no-cache"
    return response


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


@app.get("/entry", include_in_schema=False)
def entry_page() -> FileResponse:
    """The manual entry form. This is the data collection instrument."""
    return FileResponse(STATIC_DIR / "entry.html")


@app.get("/knowledge", include_in_schema=False)
def knowledge_page() -> FileResponse:
    """The shell. The article text comes from the markdown, through the API."""
    return FileResponse(STATIC_DIR / "knowledge.html")


@app.get("/sensors", include_in_schema=False)
def sensors_page() -> FileResponse:
    return FileResponse(STATIC_DIR / "sensors.html")


@app.get("/api/kb")
def list_kb() -> list[dict]:
    """Every article on disk, read fresh."""
    return [article.as_dict() for article in kb.list_articles()]


@app.get("/api/kb/{slug}")
def one_kb_article(slug: str) -> dict:
    """Render one article from its markdown file, right now.

    Nothing is cached. Edit the file, reload the page, and the change appears.
    """
    article = kb.find_article(slug)
    if article is None:
        raise HTTPException(404, f"There is no article called {slug}.")
    return kb.render_article(article)


@app.get("/api/sensors")
def list_suite() -> list[dict]:
    """The sensor suite, from architecture section 13.

    A planned sensor carries NO reading key. A live or manual sensor carries a
    reading, or `null` when the station has none. `null` means the tile must say
    the value is unavailable. It must never fall back to the example number in
    the shell file.
    """
    station_id = state.settings.mobilelab_station_id
    payload: list[dict] = []

    with state.pool.connection() as conn, conn.cursor(row_factory=dict_row) as cur:
        for sensor in suite.SUITE:
            entry_out: dict[str, Any] = {
                "number": sensor.number,
                "name": sensor.name,
                "parameters": sensor.parameters,
                "interface": sensor.interface,
                "tier": sensor.tier,
                "status": sensor.status,
                "note": sensor.note,
            }

            if sensor.status != suite.PLANNED:
                cur.execute(
                    suite.NEWEST_READING,
                    {
                        "station_id": station_id,
                        "sensor": sensor.sensor,
                        "metric": sensor.metric,
                        "sources": list(sensor.sources),
                    },
                )
                row = cur.fetchone()
                entry_out["reads"] = {
                    "sensor": sensor.sensor,
                    "metric": sensor.metric,
                    "sources": list(sensor.sources),
                }
                entry_out["reading"] = (
                    None
                    if row is None
                    else {
                        "value": float(row["value"]) if row["value"] is not None else None,
                        "unit": row["unit"],
                        "ts": row["ts"],
                        "source": row["source"],
                        "is_real": row["is_real"],
                    }
                )

            payload.append(entry_out)

    suite.assert_no_planned_values(payload)
    return payload


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


@app.get("/api/series/multi", response_model=MultiResponse, response_model_by_alias=True)
def series_multi(
    series: list[str] = Query(..., alias="series"),
    station_id: str | None = None,
    start: datetime | None = Query(None, alias="from"),
    end: datetime | None = Query(None, alias="to"),
    explain: bool = False,
) -> MultiResponse:
    """Return up to four metrics on one shared time axis.

    Each series is given as sensor:metric:source, with an optional fourth part
    for the name the screen shows. For example:

      series=water:salinity:synthetic:Salinity
      series=rain:rainfall:public_synthetic:NOAA
      series=rain:rainfall:synthetic:Rain Gauge

    The same sensor and metric from two different sources is the ordinary case,
    not a special one. Architecture section 6 makes sensor and metric the join
    key, so a public row and a local row compare directly.
    """
    if not 1 <= len(series) <= MAX_SERIES:
        raise HTTPException(
            status_code=422,
            detail=f"Ask for between 1 and {MAX_SERIES} series. You asked for {len(series)}.",
        )

    specs = []
    for index, raw in enumerate(series):
        parts = raw.split(":")
        if len(parts) < 3 or not all(parts[position] for position in range(3)):
            raise HTTPException(
                status_code=422,
                detail=(
                    f"Series {index + 1} is {raw!r}. Write it as "
                    f"sensor:metric:source, and add :name if you want one."
                ),
            )
        sensor, metric, source = parts[0], parts[1], parts[2]
        name = ":".join(parts[3:]) if len(parts) > 3 else metric
        specs.append({"sensor": sensor, "metric": metric, "source": source, "name": name})

    station_id = station_id or state.settings.mobilelab_station_id
    start, end = _window(start, end)
    relation = choose_relation(end - start)

    params: dict[str, Any] = {
        "station_id": station_id,
        "start": start,
        "end": end,
    }
    for index, spec in enumerate(specs):
        params[f"s{index}_sensor"] = spec["sensor"]
        params[f"s{index}_metric"] = spec["metric"]
        params[f"s{index}_source"] = spec["source"]

    sql = multi_sql(relation, len(specs))

    with state.pool.connection() as conn, conn.cursor(row_factory=dict_row) as cur:
        cur.execute(sql, params)
        rows = cur.fetchall()

        built = []
        for index, spec in enumerate(specs):
            cur.execute(
                SERIES_META_SQL,
                {
                    "station_id": station_id,
                    "sensor": spec["sensor"],
                    "metric": spec["metric"],
                    "source": spec["source"],
                },
            )
            found = cur.fetchone()
            label = state.sources.label(spec["source"])
            built.append(
                {
                    "key": f"s{index}",
                    "name": spec["name"],
                    "sensor": spec["sensor"],
                    "metric": spec["metric"],
                    "source": spec["source"],
                    "unit": found["unit"] if found else None,
                    "is_real": found["is_real"] if found else label["is_real"],
                    "render_hint": found["render_hint"] if found else label["render_hint"],
                    "source_known": label["known"],
                    "provenance": found["provenance"] if found else None,
                    "values": [row[f"v{index}"] for row in rows],
                }
            )

    return MultiResponse(
        station_id=station_id,
        start=start,
        end=end,
        served_from=relation.name,
        bucket=relation.bucket,
        axis=[row["ts"] for row in rows],
        series=[MultiSeries(**entry) for entry in built],
        explain=_explain(sql, params) if explain else None,
    )


class EntryIn(BaseModel):
    sensor: str
    metric: str
    value_raw: float
    unit_raw: str


class ObservationIn(BaseModel):
    ts: datetime
    entries: list[EntryIn] = Field(min_length=1)
    station_id: str | None = None
    observer: str | None = None
    site_label: str | None = None
    note: str | None = None
    lat: float | None = None
    lon: float | None = None


class CorrectionIn(BaseModel):
    value_raw: float
    unit_raw: str


def _refresh_aggregates(stamp: datetime) -> list[dict]:
    """Refresh the rollups around a corrected row.

    A correction that skips this leaves the chart drawing the old number.
    refresh_continuous_aggregate controls its own transactions, so it needs a
    connection of its own with autocommit on.
    """
    done = []
    with psycopg.connect(state.settings.dsn(), autocommit=True) as conn, conn.cursor() as cur:
        for view, start, end in entry.refresh_windows(stamp):
            cur.execute(f"call refresh_continuous_aggregate('{view}', %s, %s)", (start, end))
            done.append({"view": view, "from": start.isoformat(), "to": end.isoformat()})
    return done


def _clock_state() -> dict:
    with state.pool.connection() as conn, conn.cursor() as cur:
        cur.execute(entry.NEWEST_READING_TS)
        row = cur.fetchone()
    return entry.clock_health(row[0] if row else None)


def _reading_or_404(reading_id: int) -> dict:
    with state.pool.connection() as conn, conn.cursor(row_factory=dict_row) as cur:
        cur.execute(entry.SELECT_READING, {"id": reading_id})
        row = cur.fetchone()
    if row is None:
        raise HTTPException(404, f"There is no reading with id {reading_id}.")
    return dict(row)


@app.get("/api/metrics")
def list_metrics() -> list[dict]:
    """What the form may collect, with units and plausible ranges."""
    return metrics.catalogue_payload()


@app.get("/api/clock")
def clock() -> dict:
    """Is the station clock trustworthy? Hard rule 13."""
    return _clock_state()


@app.post("/api/observations")
def create_observation(body: ObservationIn) -> dict:
    """Save one batch. Several metrics, one observation_id."""
    health = _clock_state()
    if not health["ok"]:
        raise HTTPException(409, {"reason": "implausible_clock", **_jsonable_clock(health)})

    station_id = body.station_id or state.settings.mobilelab_station_id

    now = datetime.now(UTC)
    if body.ts < CLOCK_FLOOR:
        raise HTTPException(400, f"The observation time is before {CLOCK_FLOOR.date()}.")
    if body.ts > now + CLOCK_FUTURE_LIMIT:
        raise HTTPException(400, "The observation time is more than 24 hours ahead.")

    prepared = []
    for item in body.entries:
        try:
            value, unit = metrics.to_canonical(
                item.sensor, item.metric, item.value_raw, item.unit_raw
            )
        except (metrics.UnknownMetric, metrics.UnknownUnit) as exc:
            raise HTTPException(400, str(exc)) from exc
        flag = metrics.quality_flag(item.sensor, item.metric, value)
        prepared.append(
            {
                "sensor": item.sensor,
                "metric": item.metric,
                "value": value,
                "unit": unit,
                "value_raw": item.value_raw,
                "unit_raw": item.unit_raw,
                "quality_flag": flag,
            }
        )

    batch_flag = (
        metrics.IMPLAUSIBLE
        if any(e["quality_flag"] == metrics.IMPLAUSIBLE for e in prepared)
        else metrics.PLAUSIBLE
    )

    with state.pool.connection() as conn, conn.cursor(row_factory=dict_row) as cur:
        cur.execute(
            entry.INSERT_OBSERVATION,
            {
                "station_id": station_id,
                "observer": body.observer,
                "site_label": body.site_label,
                "ts": body.ts,
                "lat": body.lat,
                "lon": body.lon,
                "note": body.note,
                "quality_flag": batch_flag,
            },
        )
        created = cur.fetchone()
        conn.commit()

    observation_id = str(created["observation_id"])
    stamp = body.ts.astimezone(UTC).isoformat().replace("+00:00", "Z")

    for item in prepared:
        record = {
            "station_id": station_id,
            "sensor": item["sensor"],
            "metric": item["metric"],
            "value": item["value"],
            "unit": item["unit"],
            "ts": stamp,
            "lat": body.lat,
            "lon": body.lon,
            "source": entry.MANUAL_SOURCE,
            "observation_id": observation_id,
            "value_raw": item["value_raw"],
            "unit_raw": item["unit_raw"],
            "quality_flag": item["quality_flag"],
        }
        topic = f"station/{station_id}/{item['sensor']}/{item['metric']}"
        info = state.mqtt.publish(topic, json.dumps(record), qos=1)
        info.wait_for_publish(timeout=5)

    expected = len(prepared)
    deadline = time.monotonic() + 5.0
    stored = 0
    while time.monotonic() < deadline:
        with state.pool.connection() as conn, conn.cursor() as cur:
            cur.execute(entry.COUNT_BATCH_READINGS, {"observation_id": observation_id})
            stored = cur.fetchone()[0]
        if stored >= expected:
            break
        time.sleep(0.1)

    batch = _load_batch(observation_id)
    batch["expected_readings"] = expected
    batch["stored_readings"] = stored
    batch["complete"] = stored >= expected
    if not batch["complete"]:
        log.error(
            "batch %s expected %d readings and stored %d. Is the writer running?",
            observation_id,
            expected,
            stored,
        )
    return batch


def _jsonable_clock(health: dict) -> dict:
    out = dict(health)
    for key in ("now", "newest_reading_ts", "floor"):
        if out.get(key) is not None:
            out[key] = out[key].isoformat()
    return out


def _load_batch(observation_id: str) -> dict:
    with state.pool.connection() as conn, conn.cursor(row_factory=dict_row) as cur:
        cur.execute(entry.SELECT_BATCH, {"observation_id": observation_id})
        rows = [dict(row) for row in cur.fetchall()]
    grouped = entry.group_batches(rows)
    if not grouped:
        raise HTTPException(404, f"There is no observation {observation_id}.")
    return grouped[0]


@app.get("/api/observations/recent")
def recent_observations(station_id: str | None = None, limit: int = 5) -> list[dict]:
    """The newest batches, so a typo or a duplicate shows at once."""
    station_id = station_id or state.settings.mobilelab_station_id
    limit = max(1, min(limit, 50))
    with state.pool.connection() as conn, conn.cursor(row_factory=dict_row) as cur:
        cur.execute(entry.SELECT_RECENT, {"station_id": station_id, "limit": limit})
        rows = [dict(row) for row in cur.fetchall()]
    return entry.group_batches(rows)


@app.get("/api/observations/{observation_id}")
def one_observation(observation_id: str) -> dict:
    return _load_batch(observation_id)


@app.patch("/api/readings/{reading_id}")
def correct_reading(reading_id: int, body: CorrectionIn) -> dict:
    """Fix a number entered by mistake, then repair the rollups."""
    existing = _reading_or_404(reading_id)

    try:
        value, unit = metrics.to_canonical(
            existing["sensor"], existing["metric"], body.value_raw, body.unit_raw
        )
    except (metrics.UnknownMetric, metrics.UnknownUnit) as exc:
        raise HTTPException(400, str(exc)) from exc

    flag = metrics.quality_flag(existing["sensor"], existing["metric"], value)

    with state.pool.connection() as conn, conn.cursor() as cur:
        cur.execute(
            entry.UPDATE_READING,
            {
                "id": reading_id,
                "ts": existing["ts"],
                "value": value,
                "unit": unit,
                "value_raw": body.value_raw,
                "unit_raw": body.unit_raw,
                "quality_flag": flag,
            },
        )
        if cur.fetchone() is None:
            raise HTTPException(404, f"There is no reading with id {reading_id}.")
        conn.commit()

    refreshed = _refresh_aggregates(existing["ts"])
    log.info("corrected reading %d, refreshed %d rollup windows", reading_id, len(refreshed))

    return {
        "reading_id": reading_id,
        "was": {"value": existing["value"], "unit": existing["unit"]},
        "now": {"value": value, "unit": unit},
        "quality_flag": flag,
        "aggregates_refreshed": refreshed,
    }


@app.delete("/api/readings/{reading_id}")
def remove_reading(reading_id: int) -> dict:
    """Remove a reading entered by mistake, then repair the rollups."""
    existing = _reading_or_404(reading_id)

    with state.pool.connection() as conn, conn.cursor() as cur:
        cur.execute(entry.DELETE_READING, {"id": reading_id, "ts": existing["ts"]})
        if cur.fetchone() is None:
            raise HTTPException(404, f"There is no reading with id {reading_id}.")
        conn.commit()

    refreshed = _refresh_aggregates(existing["ts"])
    log.info("removed reading %d, refreshed %d rollup windows", reading_id, len(refreshed))

    return {
        "reading_id": reading_id,
        "removed": {
            "sensor": existing["sensor"],
            "metric": existing["metric"],
            "value": existing["value"],
            "unit": existing["unit"],
            "ts": existing["ts"].isoformat(),
        },
        "aggregates_refreshed": refreshed,
    }


@app.get("/api/export.csv", response_class=PlainTextResponse)
def export_csv(
    station_id: str | None = None,
    observation_id: str | None = None,
    start: datetime | None = Query(None, alias="from"),
    end: datetime | None = Query(None, alias="to"),
) -> PlainTextResponse:
    """Export readings as CSV. The column list is append-only, hard rule 5."""
    end = end or datetime.now(UTC) + timedelta(days=1)
    start = start or (end - timedelta(days=31))

    with state.pool.connection() as conn, conn.cursor(row_factory=dict_row) as cur:
        cur.execute(
            entry.EXPORT_SQL,
            {
                "start": start,
                "end": end,
                "station_id": station_id,
                "observation_id": observation_id,
            },
        )
        rows = [dict(row) for row in cur.fetchall()]

    buffer = io.StringIO()
    writer = csv.DictWriter(buffer, fieldnames=list(entry.EXPORT_COLUMNS), extrasaction="ignore")
    writer.writeheader()
    for row in rows:
        writer.writerow({key: _csv_cell(row.get(key)) for key in entry.EXPORT_COLUMNS})

    stamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
    return PlainTextResponse(
        buffer.getvalue(),
        media_type="text/csv",
        headers={"Content-Disposition": f'attachment; filename="mobilelab-{stamp}.csv"'},
    )


def _csv_cell(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, datetime):
        return value.isoformat()
    return str(value)


LOOPBACK = {"127.0.0.1", "::1", "localhost"}
POWER_DELAY_SECONDS = 2.0


def _power_check(action: str) -> tuple[bool, str]:
    """Ask whether this process may run the power command, without running it.

    "sudo -l COMMAND" answers the question and does nothing else. It walks the
    same setuid path as the real call, so everything that would stop the real
    call stops this too, and it cannot switch the station off while it asks.

    This exists because the failure it catches is invisible from the outside.
    The command runs in a background thread AFTER the answer has already gone
    to the screen, so a broken station returned 200 OK and the button said
    "Done" while nothing happened. Now the question is asked first.
    """
    try:
        done = subprocess.run(
            ["sudo", "-n", "-l", "/usr/bin/systemctl", action],
            capture_output=True,
            timeout=10,
            text=True,
        )
    except Exception as exc:
        return False, str(exc)
    if done.returncode == 0:
        return True, done.stdout.strip()
    return False, (done.stderr.strip() or done.stdout.strip() or
                   f"sudo refused, exit status {done.returncode}")


def _power_command(action: str) -> None:
    """Run the power command after a short pause.

    The pause lets the answer reach the screen, so a person sees "shutting
    down" instead of a browser error.
    """
    time.sleep(POWER_DELAY_SECONDS)
    try:
        subprocess.run(
            ["sudo", "-n", "/usr/bin/systemctl", action],
            check=True,
            capture_output=True,
            timeout=30,
        )
    except subprocess.CalledProcessError as exc:
        # Carry sudo's own words into the log. Without this the log said only
        # "returned non-zero exit status 1", which names no cause at all.
        detail = (exc.stderr or b"").decode(errors="replace").strip()
        log.error("the %s command failed: %s: %s", action, exc, detail)
    except Exception as exc:
        log.error("the %s command failed: %s", action, exc)


def _require_local(request: Request, action: str) -> str:
    """Refuse a power command from anywhere but the station itself.

    The API has no authentication and binds every interface, so without this
    check anybody on the network could switch the station off in the middle of
    a field session. The kiosk browser runs ON the Pi and loads the page from
    localhost, so it passes. A laptop across the room does not.
    """
    client = request.client.host if request.client else ""
    if client not in LOOPBACK:
        log.error(
            "REFUSED power %s from %s. Only the station screen may do this.", action, client
        )
        raise HTTPException(
            403,
            f"The {action} control works at the station screen only. "
            f"This request came from {client or 'an unknown address'}.",
        )
    return client


def _start_power(action: str, command: str, message: str, request: Request) -> dict:
    """Check the command can run, answer, then run it.

    The order matters. The check happens BEFORE the answer, so the screen can
    never report a stop that the station cannot perform.
    """
    client = _require_local(request, action)
    ready, detail = _power_check(command)
    if not ready:
        log.error("%s requested from %s, but this station cannot %s: %s",
                  action, client, command, detail)
        raise HTTPException(
            503,
            f"This station cannot {action} itself. The {command} command is not "
            f"available to the API: {detail}",
        )
    log.warning("%s requested from %s. The station acts in %.0f seconds.",
                action, client, POWER_DELAY_SECONDS)
    threading.Thread(target=_power_command, args=(command,), daemon=True).start()
    return {"action": action, "in_seconds": POWER_DELAY_SECONDS, "message": message}


@app.get("/api/power")
def power_state() -> dict:
    """What the power control can do, and who may use it.

    "ready" is the part a gate can test. It proves the API can really stop the
    station, and it proves it without stopping the station.
    """
    shutdown_ready, shutdown_detail = _power_check("poweroff")
    restart_ready, restart_detail = _power_check("reboot")
    return {
        "actions": ["shutdown", "restart"],
        "local_only": True,
        "note": "These work from the station screen only. See README, Kiosk.",
        "ready": {
            "shutdown": shutdown_ready,
            "restart": restart_ready,
            "detail": shutdown_detail if shutdown_ready else f"shutdown: {shutdown_detail}",
        },
        "hardware_button": {
            "present": True,
            "device": "pwr_button, the Pi 5 onboard button",
            "behaviour": "A press starts the same clean shutdown. logind sets HandlePowerKey=poweroff.",
        },
    }


@app.post("/api/power/shutdown")
def power_shutdown(request: Request) -> dict:
    """Shut the station down cleanly. Architecture section 9."""
    return _start_power(
        "shutdown", "poweroff",
        "The station is shutting down. Wait for the screen to go dark, then unplug it.",
        request,
    )


@app.post("/api/power/restart")
def power_restart(request: Request) -> dict:
    return _start_power(
        "restart", "reboot",
        "The station is restarting. The chart returns on its own.",
        request,
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
