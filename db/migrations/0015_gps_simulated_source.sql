--
-- 0015 gps simulated source
--
-- The source 'gps' already exists, from 0003, with is_real true. That is
-- correct: a solved fix from the receiver on the bench IS a measurement.
--
-- This migration adds the other one.
--
-- WHY A SECOND SOURCE IS NEEDED.
--
-- A GPS receiver indoors never gets a fix. Ours sees eight satellites through
-- the roof and uses none of them. So the only way to exercise the fix path, and
-- the only way to prove the indicator turns green when it should, is to replay
-- a recorded NMEA log into gpsd with gpsfake.
--
-- gpsfake feeds gpsd through a pseudo-terminal. The positions it produces are
-- fabrications. They are also indistinguishable, downstream, from a real fix,
-- because they arrive through the same gpsd socket in the same shape. Without a
-- separate source name every simulated gate run would put invented coordinates
-- into readings wearing is_real true, and hard rule 3 says a synthetic row that
-- renders as real is a defect.
--
-- So simulated position gets its own row, is_real false, drawn dashed. The
-- driver decides which one to use from the device path gpsd reports, not from
-- an argument a person can get wrong: a path under /dev/pts is a program
-- pretending to be a receiver, and the driver refuses to publish that under
-- 'gps'. See services/mobilelab/gps.py.

insert into public.sources (source, kind, is_real, render_hint, description) values
  ('gps_simulated', 'synthetic', false, 'dashed',
   'A recorded NMEA log was replayed into gpsd. It is not a measurement of where the station is.')
on conflict (source) do nothing;
