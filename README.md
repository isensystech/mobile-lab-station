# Mobile Lab Station

A field aggregator, an environmental station, a cloud gateway, and a STEM teaching
instrument. It runs on a Raspberry Pi 5.

Read `docs/MobileLab-Arch.md` first. It is the authority document. `CLAUDE.md` is a
summary of it. If the two disagree, the architecture document wins.

## What this repository contains now

This repository holds the data spine only. The spine is the broker, the database, and
the schema.

```
manual entry form ─┐
gpsd ──────────────┼─▶ Mosquitto ─▶ writer ─▶ TimescaleDB ─▶ local API ─▶ kiosk UI
WQL bridge ────────┤                                       └─▶ offload svc ─▶ Supabase
synthetic fixture ─┘
   see below          BUILT      BUILT       BUILT      NOT BUILT      NOT BUILT
```

| Part | State |
|---|---|
| Mosquitto | BUILT |
| TimescaleDB and the schema | BUILT |
| Writer | BUILT |
| Synthetic fixture | BUILT |
| Local API | BUILT |
| Overlay chart page | BUILT |
| Manual entry form | NOT BUILT |
| gpsd driver | NOT BUILT |
| WQL bridge | NOT BUILT |
| Kiosk UI | NOT BUILT |
| Offload service | NOT BUILT |

See `services/README.md`.

## How to see it work

Run these at the Pi screen. They need no arguments and no `sudo`.

```
/opt/mobile-lab-station/ops/eyewitness.sh
/opt/mobile-lab-station/ops/eyewitness-api.sh
```

The first shows data going in. The second shows it coming back out through the
local API, and draws the overlay chart from the API answer. Each one ends with a
list of what to look for and what shows a problem.

## The overlay chart

This is the demo screen. Open it in a browser on the Pi, or from any computer on
the same network.

```
http://<pi-address>:8000/
```

It draws two measurements on one time axis, with a scale on each edge. A tick
box normalizes both lines. A slider moves the second line in time, and the
caption follows it.

The station finds the delay by sliding one line against the other and keeping
the shift where they match best. It does NOT compare the tallest peak with the
deepest dip. Peak to peak answers 7 hours on the test data where the mechanism
uses 6, because rain keeps falling after its own peak.

Two rules are built into the page.

**A line the station cannot vouch for draws dashed, and a red SIMULATED banner
stays on the screen.** The banner is page text. It is not a tooltip. An unknown
or malformed label counts as not real. Open `/selftest` to watch the page refuse
broken data.

**"Correlation is not causation" is permanent text**, per hard rule 10.

Do not run Chromium in kiosk mode yet. The page opens in a normal browser, so
the desktop stays reachable.

## Local API

The API answers on port 8000. Open the documentation in a browser:

```
http://<pi-address>:8000/docs
```

| Address | Answers |
|---|---|
| `GET /health` | Are the parts working? What are the writer counters? |
| `GET /api/sources` | What sources exist? Which are real? |
| `GET /api/readings` | History for one sensor and metric over a time range. |
| `GET /api/series/pair` | Two metrics on one shared time axis, for the overlay chart. |
| `WS /ws/live` | Live readings as they arrive. |

Every response that carries readings also carries `is_real` and `render_hint`
for each series. The kiosk must never make a second call to learn what is
simulated. An unknown source is reported as not real, because the safe default
is to look simulated.

A wide time range reads a continuous aggregate. Only a range under two hours
reads the raw hypertable. A 48 hour query reads `readings_1m`.

### SECURITY, DEV CYCLE DECISION

**The API binds to every network address and has no authentication.** Anybody on
the same network can read the data and can read `/docs`.

This is deliberate for the development cycle. The kiosk browser and a teacher
laptop both have to reach it, and V1 has no login by design. Architecture
section 12 locks that: the station is the identity, and there is no login screen
in V1.

**This must not reach a classroom network or any untrusted network unchanged.**
Close it before then, in one of these ways.

- Bind to the AP subnet only, once `hostapd` runs on `wlan0`.
- Put a token in front of the write paths when write paths exist.
- Keep the station on its own AP, with no route to a school network.

The API is read only today. It has no endpoint that changes data. That limits
the damage, but it does not remove the exposure.

## Deployment model

The station installs native Debian packages. systemd supervises them. There is no
Docker. The box has one job, and a container layer does not help it do that job.

## Install order

Do these steps in this order. Run each step with `sudo`.

1. Copy `.env.example` to `.env`. Set `MOBILELAB_DB_PASSWORD`.
2. Run `sudo ops/install-mosquitto.sh`.
3. Run `sudo ops/install-timescaledb.sh`.
4. Run `sudo ops/bootstrap-db.sh`. This makes the role and the database.
5. Run `sudo db/migrate.sh`. This applies the schema.
6. Run `sudo ops/bootstrap-db.sh` again. This seeds the station row.
7. Run `sudo ops/backup/install-backup.sh`. This schedules the nightly dump.
8. Run `sudo ops/verify.sh`. This runs the gates.

## TimescaleDB package source

Debian trixie contains `postgresql-17-timescaledb`. Do not use it. That package is the
Apache edition. The Apache edition has no continuous aggregates, and architecture
section 2 requires them.

`ops/install-timescaledb.sh` adds the Timescale packagecloud repository. It installs
the community edition, which does have continuous aggregates.

## Storage

### ACTIVE EXCEPTION, opened 2026-08-15 by Scott

Hard rule 9 says TimescaleDB runs on NVMe, never on microSD. The NVMe HAT is not yet in
hand. This development cycle runs on the microSD card.

**This exception closes when the NVMe arrives. It must not reach a classroom.**

PostgreSQL write amplification kills SD cards. This station has no endurance evidence.
The nightly `pg_dump` reduces the damage. It does not remove the risk, because the dump
lands on the same card.

### PostgreSQL data directory

```
/var/lib/postgresql/17/main
```

The setting lives in `/etc/postgresql/17/main/postgresql.conf`, as `data_directory`.

### How to move the database to the NVMe

Do these steps in this order.

1. Stop PostgreSQL. `sudo systemctl stop postgresql`
2. Mount the NVMe. Add it to `/etc/fstab`.
3. Copy the data. `sudo rsync -aHAX /var/lib/postgresql/17/main/ /mnt/nvme/postgresql/17/main/`
4. Edit `data_directory` in `/etc/postgresql/17/main/postgresql.conf`.
5. Start PostgreSQL. `sudo systemctl start postgresql`
6. Run `sudo ops/verify.sh`.
7. Delete the exception from this file and from `docs/MobileLab-Arch.md` section 15.

Keep the owner as `postgres` and the mode as `0700`. PostgreSQL refuses to start if the
data directory is group readable or world readable.

## Backups

`ops/backup/mobilelab-pg-backup.sh` writes a custom format dump to
`/var/backups/mobilelab`. A systemd timer runs it every night at 02:30 UTC. The script
refuses to write inside the PostgreSQL data directory.

**Known limit 1.** The backup directory and the database sit on the same microSD card.
The dump protects against a bad migration. It does not protect against the card failing.
Move the backup directory to a USB stick or to the NVMe when one arrives.

**Known limit 2.** Nobody has restored one of these dumps. A TimescaleDB restore needs
extra steps. See `ops/README.md`.

## Network

Do not change the network from this repository. No script here touches `wlan0`,
`hostapd`, `dnsmasq`, NetworkManager, `dhcpcd`, `iptables`, or `ufw`. Scott configures
the network in person at the console.

Mosquitto listens on `127.0.0.1` only. Every V1 publisher runs on this Pi. The WQL
loggers do not speak MQTT. They POST to the bridge over HTTP, and the bridge republishes
to the broker. See architecture section 3.

## Secrets

Secrets never enter git. `.env` holds them. `.gitignore` excludes `.env`. Commit
`.env.example` only.

## Schema changes

Write a new numbered file in `db/migrations`. Then run `sudo db/migrate.sh`.

Never run SQL against the live database by hand. Never change an applied migration.
`db/migrate.sh` stores a checksum for each applied file, and it stops if a file changed.
