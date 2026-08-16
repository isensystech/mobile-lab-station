"""Manual entry: batches, corrections, export, and the clock check.

This is the data collection instrument. Every rain gauge reading is typed here.
It is not a demo feature.

Architecture section 2 locks the write path. The manual entry form is an
acquisition driver, so a reading goes out on MQTT with `source: "manual"` and
the writer stores it. The batch header row goes straight to the database,
because a batch is not a reading and has no place in the record shape.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta

from .record import CLOCK_FLOOR, CLOCK_FUTURE_LIMIT

MANUAL_SOURCE = "manual"

# How far back the clock may sit behind the newest stored reading before the
# station calls it wrong. A small step back is clock drift. An hour is not.
CLOCK_BACKWARD_TOLERANCE = timedelta(hours=1)

# How long a correction refreshes around the changed row. Both windows cover
# far more than one bucket, because a cheap wide refresh beats a clever narrow
# one that misses an edge.
MINUTE_REFRESH_PADDING = timedelta(hours=2)
HOUR_REFRESH_PADDING = timedelta(days=2)

INSERT_OBSERVATION = """
insert into public.observations
  (station_id, observer, site_label, ts, lat, lon, note, quality_flag)
values
  (%(station_id)s, %(observer)s, %(site_label)s, %(ts)s, %(lat)s, %(lon)s,
   %(note)s, %(quality_flag)s)
returning observation_id, entered_at
"""

COUNT_BATCH_READINGS = """
select count(*) from public.readings where observation_id = %(observation_id)s
"""

SELECT_BATCH = """
select
  o.observation_id, o.station_id, o.observer, o.site_label, o.ts, o.entered_at,
  o.note, o.quality_flag,
  r.id as reading_id, r.sensor, r.metric, r.value, r.unit,
  r.value_raw, r.unit_raw, r.quality_flag as reading_quality_flag,
  r.ts as reading_ts, r.source, s.is_real
from public.observations o
left join public.readings r on r.observation_id = o.observation_id
left join public.sources s on s.source = r.source
where o.observation_id = %(observation_id)s
order by r.sensor, r.metric
"""

SELECT_RECENT = """
select
  o.observation_id, o.station_id, o.observer, o.site_label, o.ts, o.entered_at,
  o.note, o.quality_flag,
  r.id as reading_id, r.sensor, r.metric, r.value, r.unit,
  r.value_raw, r.unit_raw, r.quality_flag as reading_quality_flag,
  r.ts as reading_ts, r.source, s.is_real
from public.observations o
left join public.readings r on r.observation_id = o.observation_id
left join public.sources s on s.source = r.source
where o.observation_id in (
  select observation_id from public.observations
  where station_id = %(station_id)s
  order by entered_at desc
  limit %(limit)s
)
order by o.entered_at desc, r.sensor, r.metric
"""

SELECT_READING = """
select id, ts, station_id, sensor, metric, value, unit, value_raw, unit_raw,
       source, quality_flag, observation_id
from public.readings
where id = %(id)s
"""

UPDATE_READING = """
update public.readings
set value = %(value)s,
    unit = %(unit)s,
    value_raw = %(value_raw)s,
    unit_raw = %(unit_raw)s,
    quality_flag = %(quality_flag)s
where id = %(id)s and ts = %(ts)s
returning id
"""

DELETE_READING = """
delete from public.readings where id = %(id)s and ts = %(ts)s returning id
"""

NEWEST_READING_TS = "select max(ts) from public.readings"

EXPORT_SQL = """
select
  o.observation_id,
  r.id                as reading_id,
  r.station_id,
  o.site_label,
  o.observer,
  o.ts                as observation_ts,
  o.entered_at,
  r.sensor,
  r.metric,
  r.value,
  r.unit,
  r.value_raw,
  r.unit_raw,
  r.quality_flag      as reading_quality_flag,
  o.quality_flag      as batch_quality_flag,
  o.note,
  r.lat,
  r.lon,
  r.source,
  s.is_real
from public.readings r
join public.sources s on s.source = r.source
left join public.observations o on o.observation_id = r.observation_id
where r.ts >= %(start)s and r.ts < %(end)s
  and (%(station_id)s::text is null or r.station_id = %(station_id)s::text)
  and (%(observation_id)s::uuid is null or r.observation_id = %(observation_id)s::uuid)
order by o.entered_at nulls last, r.ts, r.sensor, r.metric
"""

# HARD RULE 5. This list is append-only. Add a new column at the END, never in
# the middle, because a parser reads by column index.
EXPORT_COLUMNS = (
    "observation_id",
    "reading_id",
    "station_id",
    "site_label",
    "observer",
    "observation_ts",
    "entered_at",
    "sensor",
    "metric",
    "value",
    "unit",
    "value_raw",
    "unit_raw",
    "reading_quality_flag",
    "batch_quality_flag",
    "note",
    "lat",
    "lon",
    "source",
    "is_real",
)


def clock_health(newest_reading_ts: datetime | None, now: datetime | None = None) -> dict:
    """Judge the system clock.

    HARD RULE 13. The RTC battery is not fitted. A power cut sets the clock to
    1970. The form must say so and refuse to guess a timestamp.

    Two checks run.

    1. The clock must not sit before 2026-01-01.
    2. The clock must not sit behind the newest reading already stored. A clock
       that went backwards is wrong even when it stays inside this century.
    """
    now = now or datetime.now(UTC)
    problems: list[str] = []

    if now < CLOCK_FLOOR:
        problems.append(
            f"The station clock reads {now.isoformat()}. That is before "
            f"{CLOCK_FLOOR.date()}, so the clock is wrong."
        )

    if newest_reading_ts is not None and now < (newest_reading_ts - CLOCK_BACKWARD_TOLERANCE):
        problems.append(
            f"The station clock reads {now.isoformat()}, but a stored reading is "
            f"newer, at {newest_reading_ts.isoformat()}. The clock has gone backwards."
        )

    return {
        "ok": not problems,
        "now": now,
        "newest_reading_ts": newest_reading_ts,
        "floor": CLOCK_FLOOR,
        "future_limit_hours": CLOCK_FUTURE_LIMIT.total_seconds() / 3600,
        "problems": problems,
        "advice": (
            "The station cannot store a reading while the clock is wrong. "
            "A missing reading beats a corrupt one. Fix the clock, then enter the data. "
            "The Pi has no RTC battery fitted, so a power cut sets the clock to 1970."
        )
        if problems
        else "",
    }


def refresh_windows(stamp: datetime) -> list[tuple[str, datetime, datetime]]:
    """The rollup windows a correction at this time must refresh.

    Deleting or editing a raw row does NOT remove its aggregate bucket. The
    chart reads the rollup, so without this refresh the chart keeps drawing the
    old value. Architecture section 16 records the defect.
    """
    return [
        (
            "public.readings_1m",
            (stamp - MINUTE_REFRESH_PADDING).replace(second=0, microsecond=0),
            (stamp + MINUTE_REFRESH_PADDING).replace(second=0, microsecond=0),
        ),
        (
            "public.readings_1h",
            (stamp - HOUR_REFRESH_PADDING).replace(minute=0, second=0, microsecond=0),
            (stamp + HOUR_REFRESH_PADDING).replace(minute=0, second=0, microsecond=0),
        ),
    ]


def group_batches(rows: list[dict]) -> list[dict]:
    """Turn a flat join into one entry per observation."""
    batches: dict[str, dict] = {}
    order: list[str] = []

    for row in rows:
        key = str(row["observation_id"])
        if key not in batches:
            batches[key] = {
                "observation_id": row["observation_id"],
                "station_id": row["station_id"],
                "observer": row["observer"],
                "site_label": row["site_label"],
                "ts": row["ts"],
                "entered_at": row["entered_at"],
                "note": row["note"],
                "quality_flag": row["quality_flag"],
                "readings": [],
            }
            order.append(key)
        if row["reading_id"] is not None:
            batches[key]["readings"].append(
                {
                    "reading_id": row["reading_id"],
                    "sensor": row["sensor"],
                    "metric": row["metric"],
                    "value": row["value"],
                    "unit": row["unit"],
                    "value_raw": row["value_raw"],
                    "unit_raw": row["unit_raw"],
                    "quality_flag": row["reading_quality_flag"],
                    "ts": row["reading_ts"],
                    "source": row["source"],
                    "is_real": row["is_real"],
                }
            )

    return [batches[key] for key in order]
