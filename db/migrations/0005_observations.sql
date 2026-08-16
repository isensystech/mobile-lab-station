--
-- 0005 observations
--
-- Manual batches. Copied from docs/MobileLab-Arch.md section 4, which locks
-- this table.
--
-- A student records eight metrics at one site at one moment. That is one event,
-- not eight. The grouping is expensive to retrofit, so it ships in V1.
--
-- Two small additions to the arch DDL, both additive:
--   - observation_id gains a default, so the writer does not have to make one.
--   - quality_flag gains a check constraint. The arch DDL lists the permitted
--     values in a comment. This turns that comment into a rule.
--
-- The check constraint does not conflict with hard rule 1, "flag, never
-- reject". Rule 1 governs the VALUE a student types. This constraint governs
-- the FLAG our own code writes. A bad flag is a writer defect.

create table if not exists public.observations (
  observation_id uuid primary key default gen_random_uuid(),
  station_id     text not null references public.stations(station_id),
  observer       text,
  site_label     text,
  ts             timestamptz not null,
  entered_at     timestamptz default now(),
  lat            double precision,
  lon            double precision,
  note           text,
  quality_flag   text
    check (quality_flag in ('plausible', 'implausible', 'verified'))
);

create index if not exists observations_station_ts_idx
  on public.observations (station_id, ts desc);

comment on table public.observations is
  'One row for each manual batch. One batch groups many readings rows.';
comment on column public.observations.ts is
  'When the person made the observation.';
comment on column public.observations.entered_at is
  'When the person typed the observation. They often type it later.';
comment on column public.observations.observer is
  'Free text in V1. A roster replaces it in V2.';
comment on column public.observations.note is
  'What the person saw. Example: the water looked cloudy after the rain.';
