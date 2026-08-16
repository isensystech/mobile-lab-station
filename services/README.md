# Services

Python services for the Mobile Lab Station. They run under systemd. There is no
Docker.

All services share one package, `mobilelab`, and one virtual environment at
`/opt/mobile-lab-station/.venv`. They share one record model, so a change to the
record shape changes every service at once.

## Built

| Module | Unit | Job |
|---|---|---|
| `mobilelab.writer` | `mobilelab-writer.service` | Subscribes to `station/#`. Validates. Inserts into `readings`. |
| `mobilelab.api` | `mobilelab-api.service` | Serves history over REST, live readings over a websocket, and the chart page. |
| `static/chart-core.js` | none | The chart rules. The live page and the self test both load it. |
| `mobilelab.fixture` | `mobilelab-fixture.service` | Makes a seeded rainfall and salinity pair. Publishes it. |
| `mobilelab.plot` | none | Draws two series in a terminal, from the API or from the database. |
| `mobilelab.wslisten` | none | Prints live readings from the websocket. |
| `mobilelab.series` | none | The series queries, and the rule that picks raw or a rollup. |
| `mobilelab.topics` | none | MQTT topic names. |
| `mobilelab.record` | none | The common record shape. Architecture section 2 locks it. |
| `mobilelab.db` | none | The database layer. |
| `mobilelab.config` | none | Settings from the environment, then from `.env`. |

## How to install

```
sudo ops/install-services.sh
```

The script makes the `mobilelab` system user, builds the virtual environment,
and installs both units. It starts the writer. It does not start the fixture.

## The writer

```
sudo systemctl status mobilelab-writer
journalctl -u mobilelab-writer -f
```

Three rules shape the writer.

**It never blocks the broker.** The MQTT callback only puts the raw message on a
queue. A worker thread does the validation and the database work. A slow
database cannot stall the network loop.

**It never exits on a bad payload.** Every rejection is caught, logged at error
with the payload and the reason, and counted. Search the log for `REJECTED`.

**It reconnects on its own.** paho reconnects to the broker with a backoff from
one second to thirty. The database layer reconnects on the next insert. Nobody
has to restart it.

### Rejection reasons

| Reason | Meaning |
|---|---|
| `malformed_json` | The payload is not JSON. |
| `not_an_object` | The payload is JSON, but it is not an object. |
| `schema_invalid` | A field is missing, has the wrong type, or is unknown. |
| `topic_payload_mismatch` | The topic and the payload disagree about the station, sensor, or metric. |
| `foreign_key` | The source or the station is not in the database. |
| `check_constraint` | A value broke a database rule, such as `quality_flag`. |
| `not_null` | A required column arrived empty. |
| `bad_data` | The database could not read a value. |
| `database_unavailable` | The database did not answer. The row may have been good. |
| `implausible_clock` | The timestamp is before 2026, or more than 24 hours ahead. |
| `queue_full` | The writer fell behind. The message was dropped. |
| `writer_bug` | The writer itself raised. This one is our fault. |

**Known gap.** A rejected message is lost. Nothing holds it for a retry. A dead
letter store is not built.

### Durability

The writer holds a persistent MQTT session, and it subscribes at QoS 1. The
broker keeps the session while the writer is stopped, and it holds the messages.
At the next connect it delivers them. A writer restart therefore loses nothing.

Three parts make that work. All three are needed.

| Part | Where |
|---|---|
| `persistence true` | `/etc/mosquitto/mosquitto.conf`, the Debian default |
| `clean_session=False` | `mobilelab/writer.py` |
| QoS 1 on publish and subscribe | every publisher, and the writer subscription |

**Known limit.** Mosquitto writes the queue to disk every 60 seconds. A power
cut can still lose up to a minute of queued messages.

### The clock guard

HARD RULE, added 2026-08-15. The writer refuses a reading whose timestamp is
before 2026-01-01, or more than 24 hours ahead of now. It logs the payload at
error with `reason=implausible_clock`, and it counts it.

The Pi 5 has no RTC battery fitted. A power cut sets the clock to 1970-01-01.
NTP repairs it, but only where a network exists. In a field session there is no
network, so every reading after a power cut would carry a 1970 timestamp. Those
rows land 56 years in the past, outside every chart window and outside every
rollup refresh window.

A missing reading beats a corrupt one.

**This throws data away.** It does not fix the clock. Fit the RTC battery.

### The writer counters

The writer publishes its counters as a retained MQTT message on
`mobilelab/writer/status`. The API reads that for `/health`.

The topic sits outside `station/#` on purpose. A status message under `station/`
would be read back by the writer, fail validation, and count itself as a
rejection forever.

The counters start again from zero each time the writer starts. They count this
run, not all time.

## The local API

```
sudo systemctl status mobilelab-api
journalctl -u mobilelab-api -f
```

See the README at the repository root for the addresses, the security note, and
the rule that picks a rollup over the raw table.

Two design points matter here.

**A series cannot lose its labelling.** `is_real` and `render_hint` are required
fields on the response model. The API cannot return a series without them.

**An unknown source is not real.** A source missing from the `sources` table
gets `is_real` false and a dashed render hint. The safe default is to look
simulated, because the failure that matters is fake data that looks real.

## The fixture

```
sudo systemctl start mobilelab-fixture
```

Or run it by hand for other options:

```
cd /opt/mobile-lab-station
PYTHONPATH=services .venv/bin/python -m mobilelab.fixture --help
```

It makes 48 hours of rainfall and salinity. Rain falls. Fresh water reaches the
water body six hours later, and the salinity drops. That lag is a known answer,
put there so the correlation user interface has something to find before a real
sensor exists.

**It is deterministic.** The generator uses SHA-256, not the `random` module.
The same seed and the same start time always make the same series, on any
machine and any Python version. Compare two runs like this:

```
PYTHONPATH=services .venv/bin/python -m mobilelab.fixture --seed 1337 --dry-run --json
```

**It cannot lie about what it is.** Before it publishes, the fixture reads
`public.sources`. It stops if the source is unknown. It stops if the source has
`is_real` true. Architecture section 5 locks that rule.

Every row it writes carries `provenance`, which holds the seed, the lag, and the
generator version. A person can rebuild the exact series from any row.

**The unit has no `[Install]` section on purpose.** A fixture must never start at
boot. `systemctl enable mobilelab-fixture` fails, and that is wanted.

## Not built

| Service | Job | Tier |
|---|---|---|
| `api` | Serves history over REST. Serves live tiles over a websocket. | V1 |
| `kiosk` | The Chromium web app for the ROADOM 10.1 inch touchscreen. | V1 |
| `manual-entry` | The manual entry form. It publishes with `source: "manual"`. | V1 |
| `wql-bridge` | Accepts a dive over HTTP. Republishes it to MQTT. | V1 |
| `gpsd-driver` | Reads gpsd. Publishes position and time. | V1 |
| `offload` | Drains TimescaleDB to Supabase when a default route appears. | V2 |
| `modbus` | Polls the RS485 bus. One poller serves four sensors. | V2 |
| `gpio-rain` | Counts tipping bucket pulses. | V2 |
| `lora-rx` | Receives buoy packets on US915. | V3 |

## Rules that apply to every driver

1. One process serves one protocol family.
2. Normalize the record first. Publish second.
3. Publish the common record shape. `mobilelab.record` defines it.
4. Use a `source` that exists in the `sources` table. The database rejects any
   other value, and the writer logs it.
5. The manual entry form is a driver. It is not a special case.
6. A generator must set `provenance`. A measurement leaves it empty.
