--
-- 0012 the application role owns the continuous aggregates
--
-- WHY. A correction must refresh the rollup. Architecture section 16 records
-- the defect: deleting a raw row does not remove its aggregate bucket, so the
-- chart keeps drawing the old value.
--
-- Only the owner of a continuous aggregate may refresh it. Before this
-- migration the app role got:
--
--   ERROR:  must be owner of continuous aggregate "readings_1m"
--
-- WHY NOT A SECURITY DEFINER WRAPPER. refresh_continuous_aggregate controls
-- its own transactions. PostgreSQL forbids transaction control inside a
-- SECURITY DEFINER routine, so a wrapper cannot work.
--
-- WHAT THIS COSTS. The mobilelab role can now drop these two views. It already
-- holds insert, update, and delete on readings, so this is a small step, not a
-- new class of power. The role still cannot change a table.
--
-- The refresh policies keep running. Check them after this migration with:
--   select application_name, config from timescaledb_information.jobs
--   where proc_name = 'policy_refresh_continuous_aggregate';

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'mobilelab') then
    raise exception 'Role mobilelab does not exist. Run ops/bootstrap-db.sh first.';
  end if;
end
$$;

alter materialized view public.readings_1m owner to mobilelab;
alter materialized view public.readings_1h owner to mobilelab;
