--
-- 0007 readings gains quality_flag
--
-- RESOLVES A CONFLICT INSIDE THE ARCH DOCUMENT. Report this to Scott.
--
-- Section 4 puts quality_flag on observations only. Section 17 requires the
-- negative test "enter pH 700, confirm the row saves and carries
-- quality_flag='implausible'". A pH value is one readings row. The batch flag
-- cannot carry it, because the other seven metrics in the batch may be fine.
--
-- The two flags answer different questions:
--   observations.quality_flag  the teacher's verdict on the whole batch
--   readings.quality_flag      whether this one number is inside a sane range
--
-- This migration is deliberately separate from 0006. Delete this one file if
-- Scott decides the batch flag is enough.
--
-- The writer service sets this column. Nothing here blocks an implausible
-- value. Hard rule 1 stands: flag, never reject.

alter table public.readings
  add column if not exists quality_flag text;

alter table public.readings
  add constraint readings_quality_flag_chk
  check (quality_flag in ('plausible', 'implausible', 'verified'));

create index if not exists readings_quality_flag_idx
  on public.readings (quality_flag, ts desc)
  where quality_flag is not null;

comment on column public.readings.quality_flag is
  'Whether this one value is inside a sane range. Never blocks a save.';
