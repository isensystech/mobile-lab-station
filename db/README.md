# Database

TimescaleDB holds the local store. It makes the station autonomous. It also rhymes with
Supabase, because both are PostgreSQL. The offload path is a straight
`select here, insert there`.

## How to apply migrations

```
sudo db/migrate.sh
```

The runner tracks each applied file in `public.schema_migrations`. It stores a SHA-256
checksum for each file. It stops if an applied file changed on disk. An applied migration
is immutable. Write a new numbered file instead.

A file that starts with `-- migrate:no-transaction` runs outside a transaction.
TimescaleDB needs this for `CREATE EXTENSION` and for continuous aggregates.

## Migration list

| File | What it does |
|---|---|
| `0001_extensions.sql` | Creates the `timescaledb` extension. |
| `0002_stations.sql` | Creates `stations`. Inherited from the base station design. |
| `0003_sources.sql` | Creates `sources`, the registry of permitted `readings.source` values. |
| `0004_readings.sql` | Creates `readings` and makes it a hypertable. |
| `0005_observations.sql` | Creates `observations` for manual batches. |
| `0006_readings_observation_link.sql` | Adds `observation_id`, `value_raw`, `unit_raw`, `ref_distance_m` to `readings`. |
| `0007_readings_quality_flag.sql` | Adds `quality_flag` to `readings`. |
| `0008_continuous_aggregates.sql` | Creates the 1 minute and 1 hour rollups. |
| `0009_app_role_grants.sql` | Grants table access to the `mobilelab` role. |
| `0010_readings_provenance.sql` | Adds `provenance` to `readings`. A generator records its seed there. |
| `0011_widen_cagg_refresh.sql` | Widens the aggregate refresh windows to 7 days and 90 days. |
| `0012_cagg_owner.sql` | Gives the `mobilelab` role ownership of both rollups, so a correction can refresh them. |

## A rollup keeps data you deleted

**Read this before you delete or correct a row.**

Deleting a row from `readings` does NOT remove its bucket from `readings_1m` or
`readings_1h`. The rollup keeps the old number until a refresh runs across that
time range. The chart reads the rollup, so the chart still shows the deleted
data.

Measured on 2026-08-15: after 672 fixture rows were deleted and replaced, 52
hour buckets survived that no longer had any raw row behind them.

After you delete or correct historical rows, refresh both rollups across the
range you touched.

```sql
call refresh_continuous_aggregate('public.readings_1m', '2026-08-01', '2026-08-16');
call refresh_continuous_aggregate('public.readings_1h', '2026-08-01', '2026-08-16');
```

**The entry form does this for you.** A correction or a removal through
`/entry` refreshes both rollups around the changed row before it answers. Only
a change made outside the form needs the call above.

Only the owner of a rollup may refresh it. Migration 0012 gives the `mobilelab`
role that ownership. A `SECURITY DEFINER` wrapper cannot work, because
`refresh_continuous_aggregate` controls its own transactions and PostgreSQL
forbids that inside a `SECURITY DEFINER` routine.

The scheduled policies repair this on their own, but only inside their windows.
Migration 0011 sets those to 7 days for `readings_1m` and 90 days for
`readings_1h`. A correction older than the window stays wrong for ever until
somebody runs the call above.

## Shape

`stations` and `readings` come from the base station design without a change of column
names. The wide `sensor / metric / value / unit` shape absorbs a new sensor without a
migration. Sensor number ten needs a driver, not a schema change.

`observations` groups a manual batch. A student records eight metrics at one site at one
moment. That is one event, not eight.

## Divergences from the architecture document

Report these to Scott. Three exist.

### 1. `sources` is a new table

Architecture section 5 locks the source labelling rule. Section 16 records that the rule
has no negative test. Free text cannot enforce the rule, because a typo makes a new and
silent source value.

`readings.source` now has a foreign key to `sources`. An unknown source cannot enter the
database. `sources.is_real` gives the user interface one column to test, instead of a
list of strings held in code.

### 2. `readings` has a composite primary key

The inherited design declares `id bigint generated always as identity primary key`. A
hypertable requires the partition column in every unique index. The primary key is
`(id, ts)`. The identity column keeps its own uniqueness.

### 3. `readings.quality_flag` exists

**This resolves a conflict inside the architecture document.**

Section 4 puts `quality_flag` on `observations` only. Section 17 requires this negative
test: enter pH 700, and confirm the row saves with `quality_flag='implausible'`. A pH
value is one `readings` row. A batch flag cannot carry it, because the other seven
metrics in the batch can be good.

The two columns answer different questions.

| Column | Question |
|---|---|
| `observations.quality_flag` | What does the teacher say about the whole batch? |
| `readings.quality_flag` | Is this one number inside a sane range? |

Migration `0007` is separate from `0006` on purpose. Delete that one file if Scott
decides the batch flag is enough.

Neither column blocks a save. Hard rule 1 stands: flag, never reject.

## Roles

`ops/bootstrap-db.sh` makes the `mobilelab` role. Every service connects as that role.
The role is not a superuser. It cannot change the schema.

Migration `0009` grants to the name `mobilelab`. A migration cannot read `.env`. Keep
`MOBILELAB_DB_USER` equal to that name.
