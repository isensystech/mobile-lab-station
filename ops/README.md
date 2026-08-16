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
| `verify-kb.sh` | Runs the knowledge base and sensor suite gates in headless Chromium. |
| `install-kiosk.sh` | Installs the kiosk unit, the escape keybinding, and the narrow power permission. |
| `verify-kiosk.sh` | Runs the kiosk gates. Three of them need Scott at the screen. |
| `eyewitness-kiosk.sh` | The four tasks Scott does by hand: restart, escape, power pull, buttons. |
| `button-probe.sh` | Watches every input while somebody presses the screen buttons. |
| `eyewitness.sh` | Shows data going in. No arguments, no sudo. |
| `eyewitness-api.sh` | Shows data coming back out through the API. No arguments, no sudo. |
| `install-mosquitto.sh` | Installs Mosquitto from Debian. Installs the station configuration. Enables the unit. |
| `install-timescaledb.sh` | Adds the Timescale packagecloud repository. Installs the community edition. Runs `timescaledb-tune`. |
| `bootstrap-db.sh` | Makes the `mobilelab` role and database. Seeds the station row. |
| `verify.sh` | Runs the eight gates. Prints the blind spot for each one. |
| `backup/install-backup.sh` | Installs and starts the nightly dump timer. |
| `backup/mobilelab-pg-backup.sh` | Runs one dump. |
| `backup/restore-check.sh` | Restores a dump into a scratch database, checks it, drops it. |
| `backup/offbox-pull.sh` | **Runs on the laptop.** Copies the dumps off the Pi. |
| `backup/install-offbox-pull.sh` | **Runs on the laptop.** Schedules that copy every night. |

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

**Restore is tested.** Tested 2026-08-16 with `backup/restore-check.sh`.

The warning above did not appear in the restore. `pg_restore` finished with exit code 0,
no errors and no warnings. So the circular foreign key warning is a dump time message
only. It did not become a restore problem.

Run the check yourself:

```
sudo ops/backup/restore-check.sh /var/backups/mobilelab/<file>.dump
```

The script restores into a scratch database, compares it with the live database, and
drops the scratch database. It refuses to run if the scratch name matches the live name.

### What the dump carries

| Item | In the dump |
|---|---|
| `readings`, `observations`, `dives`, `stations` rows | yes |
| The `readings` hypertable | yes |
| `readings_1m` and `readings_1h`, with materialized data | yes |
| The two refresh policies | yes |

The rollups survive with real data. This was tested the hard way. The check sets
`materialized_only`, deletes every raw reading in the scratch copy, and then reads the
rollups again. They still answered with 726 and 691 buckets. So the numbers came from
the dump, not from live computation.

### What the dump does NOT carry

**Roles.** `pg_dump` writes one database. Roles live in the cluster. The dump holds 11
grant entries that name `mobilelab` and `sensoruser`, but it does not hold the roles
themselves. A restore onto a fresh card must make the roles first, with
`bootstrap-db.sh`, or the grants fail.

**`.env`.** It holds the database password and the station labels. It is correctly kept
out of git. It is also on the microSD card only, and no backup copies it. If the card
dies, `.env` dies with it.

Neither gap stops a restore onto THIS Pi, where the roles and `.env` already exist. Both
gaps stop a rebuild onto a NEW card.

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

## The physical buttons on the ROADOM screen

**Investigated 2026-08-16, before designing anything.**

The Pi enumerates these inputs:

| Device | What it is |
|---|---|
| `yldzkj USB2IIC_CTP_CONTROL` | The screen's TOUCH panel. This is the only device the screen presents. |
| `vc4-hdmi-0`, `vc4-hdmi-1` | HDMI audio and CEC endpoints, not buttons. |
| `pwr_button` | The Pi 5's OWN button on a GPIO. Not the screen. |
| `Logitech M705`, `MK700` | Scott's wireless mouse and keyboard. |

`lsusb` shows only the touch controller and the Logitech receiver. **The screen
presents no button device over USB.**

That is strong evidence and it is not proof. A monitor button can reach a Pi
over HDMI CEC, and this Pi has `/dev/cec0` and `/dev/cec1`. Until somebody
presses the button while something watches, nobody knows.

**To settle it:**

```
sudo ops/button-probe.sh 30
```

Press each screen button while it counts down.

- **If EVENT lines appear**, the Pi sees the button. It can then be ignored,
  remapped, or kept as the deliberate escape. Report which button and which
  line.
- **If nothing appears**, the button is wired to the monitor's own board. No
  setting on the Pi can change what it does. That needs a physical fix, such as
  tape or a cover, and not a software guard.

Do not write a software guard for a button the Pi cannot see.
