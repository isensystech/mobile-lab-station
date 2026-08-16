--
-- 0011 widen the continuous aggregate refresh windows
--
-- Migration 0008 gave readings_1m a start_offset of 3 hours. That is too narrow.
--
-- Two problems come from a narrow window.
--
-- 1. The kiosk asks for the last 48 hours. Only the last 3 hours were ever
--    materialized, so the other 45 hours came from a real time scan of the raw
--    hypertable. That is the scan the aggregate exists to prevent.
--
-- 2. Data can arrive late. The WQL bridge delivers a dive after the dive ends.
--    The fixture backfills a whole day at once. A 3 hour window never
--    materializes any of it.
--
-- A wide start_offset is cheap. TimescaleDB keeps an invalidation log and
-- refreshes only the parts that changed. It does not rebuild the whole window
-- every minute.

select remove_continuous_aggregate_policy('public.readings_1m', if_exists => true);
select remove_continuous_aggregate_policy('public.readings_1h', if_exists => true);

select add_continuous_aggregate_policy(
  'public.readings_1m',
  start_offset      => interval '7 days',
  end_offset        => interval '1 minute',
  schedule_interval => interval '1 minute',
  if_not_exists     => true
);

select add_continuous_aggregate_policy(
  'public.readings_1h',
  start_offset      => interval '90 days',
  end_offset        => interval '1 hour',
  schedule_interval => interval '1 hour',
  if_not_exists     => true
);
