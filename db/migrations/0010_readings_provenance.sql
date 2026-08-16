--
-- 0010 readings gains provenance
--
-- Architecture section 5 locks this rule: "Reconstructed rows store what they
-- were derived from, so provenance survives."
--
-- The synthetic fixture writes the seed, the lag, and the generator version
-- here. A person can then rebuild the exact series from a row, months later.
--
-- A row with source 'synthetic' and an empty provenance column is a defect. The
-- column stays nullable, because a real measurement has nothing to record here.

alter table public.readings
  add column if not exists provenance jsonb;

create index if not exists readings_provenance_idx
  on public.readings using gin (provenance)
  where provenance is not null;

comment on column public.readings.provenance is
  'What made this row, for rows that a generator made. Holds the seed and the parameters.';
