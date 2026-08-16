"""Series queries.

One rule governs this module. A wide time range reads a continuous aggregate.
Only a narrow range reads the raw hypertable.

Architecture section 2 says the touchscreen must hit materialized views and not
raw scans. A 48 hour query at raw resolution is both slow and useless, because
no chart can draw 170000 points.

The relation names here are fixed constants. No caller supplies a table name, so
no identifier reaches SQL from a request.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import timedelta

RAW_MAX_SPAN = timedelta(hours=2)
MINUTE_MAX_SPAN = timedelta(days=7)


@dataclass(frozen=True)
class Relation:
    """Where a series comes from, and how to read it."""

    name: str
    time_column: str
    value_column: str
    bucket: str | None

    @property
    def is_aggregate(self) -> bool:
        return self.bucket is not None


RAW = Relation(name="public.readings", time_column="ts", value_column="value", bucket=None)
MINUTE = Relation(
    name="public.readings_1m", time_column="bucket", value_column="avg_value", bucket="1 minute"
)
HOUR = Relation(
    name="public.readings_1h", time_column="bucket", value_column="avg_value", bucket="1 hour"
)


def choose_relation(span: timedelta) -> Relation:
    """Pick the relation for a time span.

    A short range keeps full detail. A long range reads a rollup.
    """
    if span <= RAW_MAX_SPAN:
        return RAW
    if span <= MINUTE_MAX_SPAN:
        return MINUTE
    return HOUR


def series_sql(relation: Relation, with_source: bool) -> str:
    """Read one metric, or one metric from one source."""
    source_clause = "and r.source = %(source)s" if with_source else ""
    provenance = "null::jsonb as provenance" if relation.is_aggregate else "r.provenance"
    return f"""
select
  r.source,
  r.{relation.time_column} as ts,
  r.{relation.value_column} as value,
  r.unit,
  s.is_real,
  s.render_hint,
  {provenance}
from {relation.name} r
join public.sources s on s.source = r.source
where r.station_id = %(station_id)s
  and r.sensor = %(sensor)s
  and r.metric = %(metric)s
  and r.{relation.time_column} >= %(start)s
  and r.{relation.time_column} < %(end)s
  {source_clause}
order by r.source, r.{relation.time_column}
"""


def pair_sql(relation: Relation) -> str:
    """Read two metrics onto one shared time axis.

    A full outer join makes the shared axis a property of the query, not
    something the application stitches together afterwards. A gap in one series
    returns a null in that column and keeps the row.
    """
    return f"""
with a as (
  select r.{relation.time_column} as ts, r.{relation.value_column} as value
  from {relation.name} r
  where r.station_id = %(station_id)s
    and r.sensor = %(a_sensor)s
    and r.metric = %(a_metric)s
    and r.source = %(a_source)s
    and r.{relation.time_column} >= %(start)s
    and r.{relation.time_column} < %(end)s
),
b as (
  select r.{relation.time_column} as ts, r.{relation.value_column} as value
  from {relation.name} r
  where r.station_id = %(station_id)s
    and r.sensor = %(b_sensor)s
    and r.metric = %(b_metric)s
    and r.source = %(b_source)s
    and r.{relation.time_column} >= %(start)s
    and r.{relation.time_column} < %(end)s
)
select
  coalesce(a.ts, b.ts) as ts,
  a.value as a_value,
  b.value as b_value
from a
full outer join b on a.ts = b.ts
order by 1
"""


SERIES_META_SQL = """
select
  r.unit,
  r.source,
  s.is_real,
  s.render_hint,
  r.provenance
from public.readings r
join public.sources s on s.source = r.source
where r.station_id = %(station_id)s
  and r.sensor = %(sensor)s
  and r.metric = %(metric)s
  and r.source = %(source)s
order by r.ts desc
limit 1
"""

SOURCES_SQL = """
select source, kind, is_real, render_hint, description
from public.sources
order by source
"""
