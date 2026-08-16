--
-- 0014 cell average sources
--
-- Adds the public record as a comparison lane, per architecture section 6.
--
-- TWO SOURCES, ON PURPOSE.
--
-- The rehearsal rig needs a public series before any real figure exists. A real
-- figure arrives later, entered by hand through the existing form, because
-- fetching NOAA over the network is V2 per section 6 tier 2.
--
-- Those are two different claims about truth, so they are two different rows.
--   public_synthetic  is_real false  a generator made it
--   public_record     is_real true   a person read a published figure
--
-- Both carry the same render hint. The chart therefore draws either one the
-- same way, and swapping the rig series for the real series needs no code
-- change. Section 5 stays satisfied, because is_real still separates them and
-- the badge is bound to is_real.
--
-- A NEW RENDER HINT: stepped.
--
-- A cell average is not a continuous measurement. It is one number that stands
-- for a whole grid cell across a whole bucket. Drawing it as a sloping line
-- would claim the value moved smoothly between two readings, and it did not.
-- Stepped draws it flat across the bucket, which is what the number means.
--
-- The check constraint is replaced rather than widened in place, because a
-- check constraint cannot be altered.

alter table public.sources
  drop constraint if exists sources_render_hint_check;

alter table public.sources
  add constraint sources_render_hint_check
  check (render_hint in ('solid', 'dashed', 'stepped'));

comment on column public.sources.render_hint is
  'How a chart must draw the series. Fixture data draws dashed. A cell average draws stepped, flat across each bucket.';

insert into public.sources (source, kind, is_real, render_hint, description) values
  ('public_synthetic', 'synthetic', false, 'stepped',
   'A seeded generator made a stand-in for the public record. It is not a measurement.'),
  ('public_record',    'public',    true,  'stepped',
   'A person read a published public figure and typed it. It is a cell average across a grid cell.')
on conflict (source) do nothing;
