# Operations

Every script here needs root. Run each one with `sudo`.

No script here touches the network. Architecture section 10 locks the network topology,
and Scott configures it in person at the console. No script reads or writes `wlan0`,
`hostapd`, `dnsmasq`, NetworkManager, `dhcpcd`, `iptables`, or `ufw`.

## Scripts

| Script | What it does |
|---|---|
| `install-services.sh` | Makes the service user. Builds the virtual environment. Installs the writer, API, and fixture units. |
| `verify-writer.sh` | Runs the writer and fixture gates. |
| `verify-api.sh` | Runs the local API and durability gates. |
| `verify-chart.sh` | Runs the overlay chart gates in headless Chromium, at 14 day scale. |
| `verify-entry.sh` | Runs the manual entry gates, at 14 day scale. It breaks and restores the clock. |
| `eyewitness-chart.sh` | Prints the chart address and what to look for. No arguments, no sudo. |
| `eyewitness-entry.sh` | Prints the entry form address and four tasks to do by hand. No arguments, no sudo. |
| `verify-bridge.sh` | Runs the WQL bridge gates against a generated dive. |
| `eyewitness-bridge.sh` | Posts a dive and shows it land, then on the chart. No arguments, no sudo. |
| `eyewitness.sh` | Shows data going in. No arguments, no sudo. |
| `eyewitness-api.sh` | Shows data coming back out through the API. No arguments, no sudo. |
| `install-mosquitto.sh` | Installs Mosquitto from Debian. Installs the station configuration. Enables the unit. |
| `install-timescaledb.sh` | Adds the Timescale packagecloud repository. Installs the community edition. Runs `timescaledb-tune`. |
| `bootstrap-db.sh` | Makes the `mobilelab` role and database. Seeds the station row. |
| `verify.sh` | Runs the eight gates. Prints the blind spot for each one. |
| `backup/install-backup.sh` | Installs and starts the nightly dump timer. |
| `backup/mobilelab-pg-backup.sh` | Runs one dump. |

## Why the packagecloud repository

Debian trixie contains `postgresql-17-timescaledb`. That package carries `+dfsg` in its
version, and its description says it holds the Apache licensed version.

The Apache edition has no continuous aggregates. Architecture section 2 requires them.
So the station uses the Timescale community edition instead.

`install-timescaledb.sh` removes the Debian package first, if it is present. Two copies
of the extension in one cluster cause confusion.

## Known problem with restore

`pg_dump` prints this warning on every run:

```
warning: there are circular foreign-key constraints on this table:
detail: continuous_agg
```

TimescaleDB puts circular foreign keys in its own catalog. The warning is expected. It
does not damage the dump.

**Restore is untested.** Nobody has restored one of these dumps into an empty cluster.
A TimescaleDB restore needs extra steps, because the extension must be present before
the data lands. Test a restore before you trust the backup. Write the result into
`docs/MobileLab-Arch.md` section 16.

## The gates

`verify.sh` runs eight gates. Six are positive. Two are negative.

| # | Gate |
|---|---|
| 1 | Both units are active. The `timescaledb` extension loads. |
| 2 | Mosquitto accepts a publish, and delivers it to a subscriber. |
| 3 | A readings row inserts and returns. |
| 4 | One observation groups three readings rows. |
| 5 | The continuous aggregates return buckets. |
| 6 | **Negative.** Restart PostgreSQL. Data survives. |
| 7 | **Negative.** A source outside the allowed set fails to insert. |
| 8 | A nightly dump is scheduled. One manual run writes a non empty file. |

Architecture section 17 makes negative tests a standing rule. Every gate prints what it
proves and what it does not prove. A gate with no stated blind spot has not passed.

`verify.sh` writes rows with `sensor = 'gate'` and `site_label = 'gate-harness'`. It
clears those rows at the start of each run. It leaves them at the end, so you can
inspect them.

## Negative tests still owed

Architecture section 17 requires four negative tests at V1. Two of them need software
that does not exist, and one needs hardware that is absent.

| Test | Status |
|---|---|
| Source labelling, the chart draws synthetic dashed | **PART DONE.** `verify-chart.sh` gate 3 runs 30 checks in Chromium against the shared chart code. A missing, null, empty, wrongly cased, or numeric `render_hint` draws dashed and raises the banner. It closes the rule for the overlay chart only. Any second chart, tile, or export can still get it wrong. |
| Implausible entry, pH 700 saves and flags | **PART DONE.** `verify-entry.sh` gate 2 enters pH 700 through the form. The row saves, keeps the typed number, carries `quality_flag='implausible'` on the row and the batch, and shows a FLAGGED tag on screen. The review queue promised in architecture section 4 is NOT built, so nothing gathers flagged rows for a teacher. |
| Offline buffer, pull the uplink | **OWED.** No offload service exists. |
| Power yank with the UPS HAT | **PART DONE.** Scott cut the power on 2026-08-15 with no UPS HAT fitted. PostgreSQL recovered cleanly and lost no committed rows. The graceful shutdown half stays owed until a UPS HAT exists. |

## Findings from the power cut on 2026-08-15

Scott pulled the cable with the stack running. Report these to the architecture
document, section 16.

**The database survived.** PostgreSQL logged `database system was not properly
shut down; automatic recovery in progress`, replayed the write ahead log, and
started. A full `pg_dump` read every row with no error. No row carried a broken
timestamp.

**The real time clock has no battery.** The kernel logged
`setting system clock to 1970-01-01T00:00:09 UTC`. The clock was wrong until NTP
fixed it. Architecture section 9 assumes the battery header is populated. It is
not.

This matters in a field session. With no network and no GPS fix, every reading
taken after a power cut carries a 1970 timestamp. In a time series database
those rows land 56 years in the past, outside every chart window and outside
every continuous aggregate refresh window.

Fit the RTC battery. Until then, treat any timestamp taken after a power cut as
suspect.

**Data checksums are off.** `show data_checksums` returns `off`, which is the
Debian default. PostgreSQL therefore cannot detect a corrupt page. That matters
more than usual while hard rule 9 runs under its microSD exception, because a
worn card corrupts silently.

Turn them on with `pg_checksums --enable` on a stopped cluster.
