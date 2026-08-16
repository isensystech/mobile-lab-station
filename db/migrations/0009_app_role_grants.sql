--
-- 0009 grants for the application role
--
-- The role name is fixed here on purpose. A migration cannot read .env. Keep
-- MOBILELAB_DB_USER in .env equal to this name.
--
-- The writer, the local API, the bridge, and the offload service all connect as
-- this role. None of them is a superuser. None of them can change the schema.
-- Schema changes go through db/migrate.sh only. That is hard rule 7.

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'mobilelab') then
    raise exception 'Role mobilelab does not exist. Run ops/bootstrap-db.sh first.';
  end if;
end
$$;

grant usage on schema public to mobilelab;

grant select, insert, update, delete
  on public.stations, public.readings, public.observations
  to mobilelab;

grant select on public.sources to mobilelab;

grant select on public.readings_1m, public.readings_1h to mobilelab;

alter default privileges in schema public
  grant select, insert, update, delete on tables to mobilelab;

alter default privileges in schema public
  grant usage, select on sequences to mobilelab;
