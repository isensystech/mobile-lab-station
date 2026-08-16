--
-- 0013 dive manifests
--
-- A dive is a batch, in the same way an observation is a batch. One dive file
-- becomes many readings rows. The manifest records what arrived, how much of it
-- the station kept, and how much it refused.
--
-- WHY A MANIFEST IS NEEDED. Two reasons.
--
-- 1. Idempotency. DiveSync-To-Do.md states the contract: dive files are
--    immutable after close, so the device treats a 409 as "already synced, mark
--    done", and the cloud is duplicate-safe on (device_id, filename). The
--    station must behave the same way, or a retry doubles every reading.
--
-- 2. A partial upload must leave a mark. rows_accepted and rows_rejected say
--    what happened. A dive that half ingested is visible, not silent.
--
-- This mirrors the Supabase `dives` table, so the offload path stays a straight
-- select here, insert there.
--
-- The bridge writes this manifest. It does NOT write readings. The writer stays
-- the only path into readings.

create table if not exists public.dives (
  dive_id       uuid primary key default gen_random_uuid(),
  device_id     text not null,
  filename      text not null,
  station_id    text not null references public.stations(station_id),
  cast_num      integer,
  mission       text,
  operator      text,
  site          text,
  water_type    text,
  utc_start     timestamptz,
  time_source   text,
  rows_total    integer not null default 0,
  rows_accepted integer not null default 0,
  rows_rejected integer not null default 0,
  reject_reasons jsonb,
  meta          jsonb,
  received_at   timestamptz not null default now(),
  unique (device_id, filename)
);

comment on table public.dives is
  'One row for each dive file the bridge received. The unique key makes a repeat upload safe.';
comment on column public.dives.rows_rejected is
  'How many CSV rows the bridge refused. A dive with rejects is not a complete dive.';

alter table public.readings
  add column if not exists dive_id uuid references public.dives(dive_id);

create index if not exists readings_dive_idx
  on public.readings (dive_id)
  where dive_id is not null;

comment on column public.readings.dive_id is
  'The dive file this row came from. Null for a row that did not come from a dive.';

grant select, insert, update, delete on public.dives to mobilelab;
