--
-- 0002 stations
--
-- Inherited unchanged from docs/BaseStation-Arch.md, harvested into
-- docs/MobileLab-Arch.md section 4. Do not rename these columns. The offload
-- service copies rows straight into the Supabase table of the same name.

create table if not exists public.stations (
  station_id text primary key,
  label      text,
  lat        double precision,
  lon        double precision,
  added_at   timestamptz default now()
);

comment on table public.stations is
  'One row for each station that reports data. The Pi is one station.';
