--
-- 0004 readings
--
-- Inherited from docs/BaseStation-Arch.md, harvested into
-- docs/MobileLab-Arch.md section 4. The wide sensor / metric / value / unit
-- shape absorbs a new sensor without a migration.
--
-- TWO DIVERGENCES FROM THE INHERITED DDL, both forced:
--
-- 1. The inherited table declares "id bigint generated always as identity
--    primary key". A hypertable requires the partition column in every unique
--    index. The primary key becomes (id, ts). The identity column keeps its
--    own uniqueness, so no row identity is lost.
--
-- 2. The inherited table declares "source text" as nullable free text. Here
--    source is NOT NULL and has a foreign key to public.sources. Arch section 5
--    locks the source labelling rule. See 0003_sources.sql.
--
-- uploaded_at keeps its inherited name. The offload service copies rows
-- straight into Supabase, so the column names must match on both ends.

create table if not exists public.readings (
  id          bigint generated always as identity,
  station_id  text not null references public.stations(station_id),
  sensor      text not null,
  metric      text not null,
  value       double precision,
  unit        text,
  ts          timestamptz not null,
  lat         double precision,
  lon         double precision,
  source      text not null references public.sources(source),
  uploaded_at timestamptz default now(),
  primary key (id, ts)
);

select create_hypertable(
  'public.readings',
  by_range('ts'),
  if_not_exists => true
);

create index if not exists readings_series_idx
  on public.readings (station_id, sensor, metric, ts desc);

create index if not exists readings_source_idx
  on public.readings (source, ts desc);

comment on table public.readings is
  'One row for each measured value. Mirrors the Supabase readings table.';
comment on column public.readings.uploaded_at is
  'When the row entered this database. The name is inherited for offload parity.';
