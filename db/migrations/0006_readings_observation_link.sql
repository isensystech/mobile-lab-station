--
-- 0006 readings gains the manual entry columns
--
-- Copied from docs/MobileLab-Arch.md section 4, which locks this change.
--
-- This migration shows the pattern the whole design depends on. A new
-- capability adds columns to readings. It does not make a new table.

alter table public.readings
  add column if not exists observation_id uuid references public.observations(observation_id),
  add column if not exists value_raw      double precision,
  add column if not exists unit_raw       text,
  add column if not exists ref_distance_m double precision;

create index if not exists readings_observation_idx
  on public.readings (observation_id)
  where observation_id is not null;

comment on column public.readings.observation_id is
  'The manual batch this row belongs to. Null for automatic rows.';
comment on column public.readings.value_raw is
  'The number the person typed, before conversion.';
comment on column public.readings.unit_raw is
  'The unit the person typed. They will type degrees Fahrenheit.';
comment on column public.readings.ref_distance_m is
  'Distance to the reference source, in metres. See arch section 6.';
