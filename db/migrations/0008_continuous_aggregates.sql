-- migrate:no-transaction
--
-- 0008 continuous aggregates
--
-- Arch section 2 locks these. The touchscreen must read a materialized view.
-- It must not scan the raw hypertable.
--
-- This file runs outside a transaction. TimescaleDB refuses to make a
-- continuous aggregate inside a transaction block.
--
-- materialized_only = false turns on real time aggregation. A query then adds
-- the newest rows to the materialized result. Without it the kiosk shows
-- nothing until the next refresh job runs, and a live tile looks broken.
--
-- Both views read the raw hypertable. A hierarchical view, where the hour view
-- reads the minute view, is possible. V1 does not need it.

create materialized view if not exists public.readings_1m
with (timescaledb.continuous, timescaledb.materialized_only = false) as
select
  station_id,
  sensor,
  metric,
  unit,
  source,
  time_bucket(interval '1 minute', ts) as bucket,
  avg(value)   as avg_value,
  min(value)   as min_value,
  max(value)   as max_value,
  count(value) as sample_count
from public.readings
group by station_id, sensor, metric, unit, source, time_bucket(interval '1 minute', ts)
with no data;

create materialized view if not exists public.readings_1h
with (timescaledb.continuous, timescaledb.materialized_only = false) as
select
  station_id,
  sensor,
  metric,
  unit,
  source,
  time_bucket(interval '1 hour', ts) as bucket,
  avg(value)   as avg_value,
  min(value)   as min_value,
  max(value)   as max_value,
  count(value) as sample_count
from public.readings
group by station_id, sensor, metric, unit, source, time_bucket(interval '1 hour', ts)
with no data;

select add_continuous_aggregate_policy(
  'public.readings_1m',
  start_offset      => interval '3 hours',
  end_offset        => interval '1 minute',
  schedule_interval => interval '1 minute',
  if_not_exists     => true
);

select add_continuous_aggregate_policy(
  'public.readings_1h',
  start_offset      => interval '7 days',
  end_offset        => interval '1 hour',
  schedule_interval => interval '1 hour',
  if_not_exists     => true
);
