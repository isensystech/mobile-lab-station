--
-- 0003 sources
--
-- A registry of permitted values for readings.source.
--
-- DIVERGENCE FROM THE ARCH DOCUMENT. The arch document does not specify this
-- table. Section 5 makes source labelling a LOCKED rule and section 16 records
-- that the rule has no negative test. A free-text source column cannot enforce
-- the rule, because a typo becomes a new and silent source value.
--
-- This table makes the rule structural. readings.source has a foreign key to
-- it. An unknown source value cannot enter the database.
--
-- is_real gives the user interface one column to test. The interface must not
-- compare source strings against a list held in code, because that list rots.

create table if not exists public.sources (
  source      text primary key,
  kind        text not null
    check (kind in ('measured', 'manual', 'synthetic', 'reconstructed', 'public')),
  is_real     boolean not null,
  render_hint text not null default 'solid'
    check (render_hint in ('solid', 'dashed')),
  description text not null
);

comment on table public.sources is
  'The permitted values for readings.source. Add a new source with a migration.';
comment on column public.sources.is_real is
  'True if a person or an instrument measured the value. False for test fixtures.';
comment on column public.sources.render_hint is
  'How a chart must draw the series. Fixture data draws dashed.';

insert into public.sources (source, kind, is_real, render_hint, description) values
  ('manual',        'manual',        true,  'solid',
   'A person read an instrument. The person typed the value.'),
  ('wql',           'measured',      true,  'solid',
   'A WQL logger sent the value. The bridge service published it.'),
  ('gps',           'measured',      true,  'solid',
   'gpsd supplied the value.'),
  ('synthetic',     'synthetic',     false, 'dashed',
   'A seeded test fixture made the value. It is not a measurement.'),
  ('reconstructed', 'reconstructed', false, 'dashed',
   'A test fixture derived the value from a real record. It is not a measurement.')
on conflict (source) do nothing;
