"""The WQL logger bridge.

Architecture section 3 locks the shape: the logger POSTs a dive over HTTP, and a
small bridge service republishes it to MQTT. The logger never speaks MQTT, so
its local and cloud modes differ only by URL and key. No firmware churn.

THE BRIDGE NEVER WRITES READINGS. It publishes to MQTT and the writer stores the
rows. One insert path, one set of rules. The bridge writes only the dive
manifest, which is a batch header, in the same way the entry form writes an
observation header.

The URL paths copy the Supabase paths from DiveSync-To-Do.md on purpose, so the
firmware needs a new host and nothing else.
"""

from __future__ import annotations

import json
import logging
import sys
import time
from collections import Counter
from contextlib import asynccontextmanager
from datetime import UTC, datetime, timedelta

import paho.mqtt.client as mqtt
import psycopg
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from psycopg import errors as pg_errors
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

from . import __version__, dive
from .config import load_settings
from .record import CLOCK_FLOOR, CLOCK_FUTURE_LIMIT

log = logging.getLogger("mobilelab.bridge")

MAX_UPLOAD_BYTES = 32 * 1024 * 1024

INSERT_DIVE = """
insert into public.dives
  (device_id, filename, station_id, cast_num, mission, operator, site,
   water_type, utc_start, time_source, rows_total, meta)
values
  (%(device_id)s, %(filename)s, %(station_id)s, %(cast_num)s, %(mission)s,
   %(operator)s, %(site)s, %(water_type)s, %(utc_start)s, %(time_source)s,
   %(rows_total)s, %(meta)s)
returning dive_id
"""

FINISH_DIVE = """
update public.dives
set rows_accepted = %(accepted)s,
    rows_rejected = %(rejected)s,
    reject_reasons = %(reasons)s
where dive_id = %(dive_id)s
"""

COUNT_DIVE_READINGS = "select count(*) from public.readings where dive_id = %(dive_id)s"

RECENT_DIVES = """
select dive_id, device_id, filename, station_id, site, utc_start, time_source,
       rows_total, rows_accepted, rows_rejected, reject_reasons, received_at
from public.dives
order by received_at desc
limit %(limit)s
"""


class State:
    def __init__(self) -> None:
        self.settings = load_settings()
        self.pool: ConnectionPool | None = None
        self.mqtt: mqtt.Client | None = None
        self.broker_connected = False


state = State()


def _on_connect(client, userdata, flags, reason_code, properties=None) -> None:
    state.broker_connected = reason_code == 0
    log.info("the bridge connected to the broker, reason %s", reason_code)


def _on_disconnect(client, userdata, flags=None, reason_code=None, properties=None) -> None:
    state.broker_connected = False
    log.warning("the bridge lost the broker connection, reason %s", reason_code)


@asynccontextmanager
async def lifespan(app: FastAPI):
    settings = state.settings
    state.pool = ConnectionPool(
        settings.dsn(), min_size=1, max_size=3, check=ConnectionPool.check_connection, open=True
    )

    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id="mobilelab-bridge")
    client.on_connect = _on_connect
    client.on_disconnect = _on_disconnect
    client.reconnect_delay_set(min_delay=1, max_delay=30)
    client.connect_async(settings.mobilelab_mqtt_host, settings.mobilelab_mqtt_port, keepalive=60)
    client.loop_start()
    state.mqtt = client

    log.info(
        "the bridge is ready on %s:%d",
        settings.mobilelab_bridge_host,
        settings.mobilelab_bridge_port,
    )
    yield

    client.loop_stop()
    client.disconnect()
    if state.pool is not None:
        state.pool.close()


app = FastAPI(
    title="Mobile Lab Station WQL bridge",
    version=__version__,
    lifespan=lifespan,
    description=(
        "The WQL logger POSTs a dive CSV here. The bridge republishes every row to "
        "MQTT, and the writer stores it. The bridge never writes readings."
    ),
)


@app.get("/health")
def health() -> dict:
    database_ok = False
    try:
        with state.pool.connection() as conn, conn.cursor() as cur:
            cur.execute("select 1")
            database_ok = cur.fetchone()[0] == 1
    except Exception as exc:
        log.warning("the bridge could not reach the database: %s", exc)

    return {
        "status": "ok" if (database_ok and state.broker_connected) else "degraded",
        "version": __version__,
        "database": {"connected": database_ok},
        "broker": {"connected": state.broker_connected},
        "columns_expected": dive.DIVE_COLUMN_COUNT,
        "header_expected": dive.DIVE_HEADER,
    }


@app.get("/dives")
def recent_dives(limit: int = 10) -> list[dict]:
    with state.pool.connection() as conn, conn.cursor(row_factory=dict_row) as cur:
        cur.execute(RECENT_DIVES, {"limit": max(1, min(limit, 100))})
        return [dict(row) for row in cur.fetchall()]


def _refresh_for_dive(first: datetime, last: datetime) -> list[dict]:
    """Refresh both rollups across the dive, plus a margin on each side.

    refresh_continuous_aggregate manages its own transactions, so it needs a
    connection of its own with autocommit on.
    """
    done: list[dict] = []
    windows = [
        (
            "public.readings_1m",
            (first - timedelta(hours=1)).replace(second=0, microsecond=0),
            (last + timedelta(hours=1)).replace(second=0, microsecond=0),
        ),
        (
            "public.readings_1h",
            (first - timedelta(days=1)).replace(minute=0, second=0, microsecond=0),
            (last + timedelta(days=1)).replace(minute=0, second=0, microsecond=0),
        ),
    ]
    try:
        with psycopg.connect(state.settings.dsn(), autocommit=True) as conn, conn.cursor() as cur:
            for view, start, end in windows:
                cur.execute(f"call refresh_continuous_aggregate('{view}', %s, %s)", (start, end))
                done.append({"view": view, "from": start.isoformat(), "to": end.isoformat()})
    except Exception as exc:
        log.error("could not refresh the rollups after the dive: %s", exc)
    return done


def _ingest(device_id: str, filename: str, body: bytes) -> JSONResponse:
    """Parse, register, publish. Nothing is stored until the parse succeeds."""
    if len(body) > MAX_UPLOAD_BYTES:
        raise HTTPException(413, f"The dive file is larger than {MAX_UPLOAD_BYTES} bytes.")

    try:
        text = body.decode("utf-8", errors="strict")
    except UnicodeDecodeError as exc:
        raise HTTPException(400, f"The dive file is not UTF-8 text. {exc}") from exc

    # STEP 1. Parse first. A bad file must ingest nothing at all.
    try:
        parsed = dive.parse_dive_csv(text)
    except dive.DiveFormatError as exc:
        log.error(
            "REFUSED dive %s/%s | reason=bad_format | detail=%s", device_id, filename, exc
        )
        raise HTTPException(
            400,
            {
                "reason": "bad_format",
                "detail": str(exc),
                "expected_columns": dive.DIVE_COLUMN_COUNT,
                "expected_header": dive.DIVE_HEADER,
                "rows_ingested": 0,
            },
        ) from exc

    meta = dive.dive_metadata(parsed.meta)
    station_id = state.settings.mobilelab_station_id

    # STEP 2. Register the dive. A repeat upload stops here with 409.
    try:
        with state.pool.connection() as conn, conn.cursor(row_factory=dict_row) as cur:
            cur.execute(
                INSERT_DIVE,
                {
                    "device_id": device_id,
                    "filename": filename,
                    "station_id": station_id,
                    "cast_num": meta["cast_num"],
                    "mission": meta["mission"],
                    "operator": meta["operator"],
                    "site": meta["site"],
                    "water_type": meta["water_type"],
                    "utc_start": meta["utc_start"],
                    "time_source": meta["time_source"],
                    "rows_total": len(parsed.rows),
                    "meta": json.dumps({"meta_lines": meta["meta_lines"]}),
                },
            )
            dive_id = str(cur.fetchone()["dive_id"])
            conn.commit()
    except pg_errors.UniqueViolation:
        log.info("dive %s/%s was already received, answering 409", device_id, filename)
        return JSONResponse(
            status_code=409,
            content={
                "statusCode": "409",
                "error": "Duplicate",
                "message": (
                    f"The station already has {filename} from {device_id}. "
                    f"A dive file never changes after it closes, so the station keeps the "
                    f"first copy and ingests nothing again."
                ),
                "rows_ingested": 0,
            },
        )

    # STEP 3. Publish every usable row. Reject a row the clock cannot place.
    now = datetime.now(UTC)
    rejected: Counter = Counter()
    accepted_rows = 0
    published = 0
    first_stamp: datetime | None = None
    last_stamp: datetime | None = None

    for index, cells in enumerate(parsed.rows):
        stamp, problem = dive.row_timestamp(cells)
        if problem is not None:
            rejected[problem] += 1
            log.error(
                "REJECTED dive row | reason=%s | dive=%s | row=%d | utc=%r",
                problem,
                filename,
                index,
                cells[dive.COL["utc"]],
            )
            continue

        if stamp < CLOCK_FLOOR or stamp > now + CLOCK_FUTURE_LIMIT:
            rejected["implausible_clock"] += 1
            log.error(
                "REJECTED dive row | reason=implausible_clock | dive=%s | row=%d | ts=%s",
                filename,
                index,
                stamp.isoformat(),
            )
            continue

        readings = dive.row_readings(cells, meta["cyclops_unit"])
        if not readings:
            rejected["no_readings_in_row"] += 1
            continue

        lat, lon = dive.row_position(cells)
        stamp_text = stamp.isoformat().replace("+00:00", "Z")
        accepted_rows += 1
        first_stamp = stamp if first_stamp is None or stamp < first_stamp else first_stamp
        last_stamp = stamp if last_stamp is None or stamp > last_stamp else last_stamp

        for reading in readings:
            record = {
                "station_id": station_id,
                "sensor": dive.DIVE_SENSOR,
                "metric": reading["metric"],
                "value": reading["value"],
                "unit": reading["unit"],
                "ts": stamp_text,
                "lat": lat,
                "lon": lon,
                "source": dive.DIVE_SOURCE,
                "dive_id": dive_id,
            }
            topic = f"station/{station_id}/{dive.DIVE_SENSOR}/{reading['metric']}"
            state.mqtt.publish(topic, json.dumps(record), qos=1)
            published += 1

    # STEP 4. Wait for the writer, so the answer reports what really landed.
    deadline = time.monotonic() + max(15.0, published * 0.02)
    stored = 0
    while time.monotonic() < deadline:
        with state.pool.connection() as conn, conn.cursor() as cur:
            cur.execute(COUNT_DIVE_READINGS, {"dive_id": dive_id})
            stored = cur.fetchone()[0]
        if stored >= published:
            break
        time.sleep(0.2)

    with state.pool.connection() as conn, conn.cursor() as cur:
        cur.execute(
            FINISH_DIVE,
            {
                "dive_id": dive_id,
                "accepted": accepted_rows,
                "rejected": sum(rejected.values()),
                "reasons": json.dumps(dict(rejected)),
            },
        )
        conn.commit()

    # STEP 5. Materialize the rollups over the dive's own time range.
    #
    # A dive is always BACKDATED. The logger records under water and uploads
    # when it surfaces, so every row lands behind the rollup watermark. Rows
    # below that watermark are not covered by real time aggregation, so the
    # chart cannot see the dive at all until a refresh runs across it.
    #
    # Without this step a diver surfaces, uploads, opens the chart, and sees
    # nothing. Architecture section 16 records the same trap for corrections.
    refreshed = _refresh_for_dive(first_stamp, last_stamp) if accepted_rows else []

    complete = stored >= published
    if not complete:
        log.error(
            "dive %s published %d readings and only %d landed. Is the writer running?",
            filename,
            published,
            stored,
        )

    log.info(
        "dive %s/%s ingested. rows %d, accepted %d, rejected %d, readings stored %d",
        device_id,
        filename,
        len(parsed.rows),
        accepted_rows,
        sum(rejected.values()),
        stored,
    )

    return JSONResponse(
        status_code=201,
        content={
            "dive_id": dive_id,
            "device_id": device_id,
            "filename": filename,
            "station_id": station_id,
            "site": meta["site"],
            "utc_start": meta["utc_start"].isoformat() if meta["utc_start"] else None,
            "time_source": meta["time_source"],
            "rows_total": len(parsed.rows),
            "rows_accepted": accepted_rows,
            "rows_rejected": sum(rejected.values()),
            "reject_reasons": dict(rejected),
            "readings_published": published,
            "readings_stored": stored,
            "readings_complete": complete,
            "aggregates_refreshed": refreshed,
            "source": dive.DIVE_SOURCE,
        },
    )


@app.post("/storage/v1/object/dives/{device_id}/{filename}")
async def upload_dive_cloud_path(device_id: str, filename: str, request: Request) -> JSONResponse:
    """The Supabase storage path, copied so the firmware needs only a new host."""
    return _ingest(device_id, filename, await request.body())


@app.post("/dives/{device_id}/{filename}")
async def upload_dive(device_id: str, filename: str, request: Request) -> JSONResponse:
    """A short path, for a person testing with curl."""
    return _ingest(device_id, filename, await request.body())


@app.post("/rest/v1/dives")
async def dive_metadata_row(request: Request) -> JSONResponse:
    """The Supabase metadata call.

    The CSV meta header already carries every one of these fields, so the
    station does not need this call. It answers politely so a firmware that
    makes both calls does not retry for ever.

    NOT VERIFIED against real firmware. No logger has posted here.
    """
    try:
        body = await request.json()
    except Exception as exc:
        raise HTTPException(400, "The metadata body is not JSON.") from exc

    device_id = body.get("device_id")
    filename = body.get("filename")
    if not device_id or not filename:
        raise HTTPException(400, "The metadata needs device_id and filename.")

    with state.pool.connection() as conn, conn.cursor() as cur:
        cur.execute(
            "select dive_id from public.dives where device_id = %s and filename = %s",
            (device_id, filename),
        )
        row = cur.fetchone()

    return JSONResponse(
        status_code=201,
        content={
            "device_id": device_id,
            "filename": filename,
            "known": row is not None,
            "note": "The station reads the meta header inside the CSV. This call changes nothing.",
        },
    )


def main() -> int:
    import uvicorn

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
        stream=sys.stdout,
    )
    settings = state.settings
    uvicorn.run(
        app,
        host=settings.mobilelab_bridge_host,
        port=settings.mobilelab_bridge_port,
        log_level="info",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
