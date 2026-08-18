# MobileLab-Arch.md — Mobile Lab Station

Authority document for the Pi5 mobile lab station: field aggregator, environmental
station, cloud gateway, and STEM teaching instrument in one Pelicase.

> **STATUS: V1 SCOPED — PROOF OF CONCEPT.** V1 exists to win the decision to build
> more. Locked decisions are marked **[LOCKED]**. Everything else is directional.
>
> **This document supersedes `docs/BaseStation-Arch.md`** in the `WaterQualitySensor`
> monorepo. That document carries a succession notice. Its locked decisions are
> harvested below. Purge it only after Scott verifies this document.

> **Active scratchpad for this topic:** `MobileLab-Demo-Story.md`. Treat it as the
> current source of truth for the pitch narrative until harvested. It does not define
> capability. This document does. If the two disagree, this document wins.

Repo: `github.com/isensystech/mobile-lab-station` **[LOCKED]**
Name: "mobile lab station" **[LOCKED]**

---

## 1. Role

The station is four things in one box. The first three are inherited from the base
station concept. The fourth is new and it changes the priorities.

1. **Local sink** for WQL loggers — DiveSync "local" mode delivers dives to the Pi.
2. **Environmental station** — its own sensor suite (soil, air, rain, noise, creek, buoy).
3. **Cloud gateway** — store-and-forward offload to Supabase.
4. **Teaching instrument** — students and teachers collect, plot, compare, and interpret
   environmental data.

**[LOCKED] Same box, both roles.** The mobile lab station is the evolution of the base
station. It keeps every gateway function and adds sensors and the learning element. It
is not a second product.

Design ethos, unchanged: **leave-and-forget, each hop tolerant of the next being absent.**
logger → Pi → cloud. No leg assumes the next is present. It buffers, then drains when a
path appears.

**What the teaching role changes.** The gateway framing puts the Modbus driver layer on
the critical path. The teaching framing does not. The primary user is a student at the
screen, not an unattended box in a field. The failure that hurts most is a confusing UI,
not a missed sample.

| | Gateway framing | Lab framing (this document) |
|---|---|---|
| V1 critical path | Modbus poller + offload service | manual entry + charts |
| Primary user | nobody, it runs alone | student at the screen |
| Failure that hurts | missed samples | confusing UI |
| Uplink | required | deferred to V2 |

---

## 2. The spine

**[LOCKED] The manual entry form is an acquisition driver.**

It publishes the same record to MQTT that a Modbus poller publishes, with
`source: "manual"`. Everything downstream is identical and gets built once.

```
 manual entry form ──┐
 gpsd ───────────────┤
 WQL bridge ─────────┼──▶ Mosquitto ──▶ writer ──▶ ┌──────────┐ ──▶ local API ──▶ kiosk UI
 synthetic fixture ──┤     (MQTT)                  │TimescaleDB│ ──▶ offload svc ──▶ Supabase
                     │                             └──────────┘
 modbus poller ......┤   V2+, changes nothing downstream
 gpio rain counter ..┤
 lora rx ............┘
```

V1 ships three real drivers instead of six. V2 adds drivers without touching the stack.
`readings.source` already exists, so the schema absorbs manual entry with no migration.

**[LOCKED] TimescaleDB** as the local store. It makes the station autonomous. It rhymes
with Supabase — both Postgres, so schema, queries, and the offload path share one mental
model. Hypertables for `readings`. Continuous aggregates for 1-minute and 1-hour rollups,
so the touchscreen hits materialized views and not raw scans.

**[LOCKED] Native packages under systemd. No Docker.** Mosquitto, PostgreSQL, and the
Python services install as Debian packages and run as systemd units. The box has one job.
A container layer does not help it do that job, and it adds a runtime the shipping model
does not need.

**[LOCKED] TimescaleDB comes from the Timescale packagecloud repository.** It does not
come from Debian.

Debian trixie contains `postgresql-17-timescaledb`. Do not use it. That package carries
`+dfsg` in its version, and its own description says it holds the Apache licensed edition.
The Apache edition has no continuous aggregates. This section requires them, so the Debian
package cannot serve the station.

> **RISK, and it is new.** The classroom image now depends on a third-party repository.
> Timescale controls that repository. If Timescale drops the Debian build, or the
> repository goes away, nobody can rebuild the image from Debian alone. Mirror the
> packages locally before the first classroom build.

**[LOCKED] Mosquitto (MQTT)** as the spine. Topics of the form
`station/lab01/soil/moisture`. Producers and consumers stay decoupled. This is the reason
the suite can grow without downstream churn.

Common record shape:

```json
{ "station_id":"lab01", "sensor":"soil", "metric":"moisture",
  "value":34.2, "unit":"pct", "ts":"2026-08-15T14:22:00Z",
  "lat":27.99, "lon":-80.62, "source":"manual" }
```

**[LOCKED] Custom kiosk UI.** Chromium in kiosk mode on the ROADOM 10.1", serving a
local web app off the Pi. A FastAPI local API server provides history over REST and live
tiles over a websocket. See §18, decision 2.

**[LOCKED] Charting library on the kiosk.** Do not reuse the firmware portal SVG renderer
(`parseCsv`, `miniChart`, `drawCharts`). That renderer is correct for 240×320 tiles on a
dive screen. It fights back on a 10.1" touchscreen doing scatter plots and lag sliders.
The device keeps its hand-rolled SVG. The kiosk uses Chart.js 4.4.7. The repository holds
a copy, so the chart draws with no internet. See §18, decision 3.

---

## 3. WQL logger ingest

**[LOCKED] Bridge, not direct MQTT.** The logger POSTs dives over HTTP as specified in
`DiveSync-To-Do.md` local mode. A small bridge service on the Pi republishes to MQTT.

Rationale: no firmware churn, and the logger's local and cloud modes keep differing only
by URL and key. One config field, one firmware.

**Threshold breaches.** The logger already implements thresholds. The station does not
implement its own in V1. It renders breaches that arrive with the dive.

### The CSV has 25 columns, not 24

**CORRECTED 2026-08-15.** An earlier version of this section called it a 24-field CSV. It
listed 19 names and said "plus GPS columns". The firmware writes **25**: 19 science
columns, then 6 GPS columns.

The authority is `firmware/src/main.cpp:258`, quoted here in full:

```
ms,utc,submerged,poi,P_mbar,depth_m,bar30T_C,poetT_mC,ugs_uV,orp_uV,ec_nA,ec_uV,pH,EC_mScm,sal_PSU,ORP_Eh_mV,cyc_V,cyc_conc,cels_T_C,gps_lat,gps_lon,gps_fix,gps_sats,gps_age_s,gps_src
```

| Group | Count | Names |
|---|---|---|
| Science | 19 | `ms` … `cels_T_C` |
| GPS | 6 | `gps_lat`, `gps_lon`, `gps_fix`, `gps_sats`, `gps_age_s`, `gps_src` |
| **Total** | **25** | |

`gps_src` is easy to miss when counting, and missing it is how 25 became 24.

**The bridge parses by position and fails loudly.** It compares the header against the 25
names above. A file with any other count, or any renamed column, is refused with HTTP 400,
and **nothing is ingested**. A firmware change breaks visibly on the first upload rather
than silently shifting every value one column to the left.

**CORRECTED 2026-08-16.** An earlier version of this section warned that a reorder would
pass the guard. That was wrong. The guard compares the header to the documented header
**in order**, so a swap is refused and both offending columns are named:

```
the column header does not match the documented header.
position 6: expected 'bar30T_C', got 'cels_T_C';
position 18: expected 'cels_T_C', got 'bar30T_C'. Nothing was ingested.
```

`ops/verify-bridge.sh` gate 7 posts exactly that file, with all 25 columns present, and
confirms the refusal and that nothing is written.

> **WHAT IS STILL OPEN.** The guard checks the NAME and the POSITION. It cannot check the
> MEANING. A firmware that keeps all 25 names in the documented order, and changes what a
> column holds, passes every check. An example: `poetT_mC` starts reporting degrees rather
> than milli degrees. The header is identical, the file is accepted, and every value is
> wrong by a factor of a thousand. Nothing tells the station which firmware version wrote
> a file. See §16.

### Dive idempotency **[LOCKED]**

A dive file never changes after it closes. `DiveSync-To-Do.md` states the contract, and
the station copies it, so one firmware works against the cloud and against the station.

- The key is **`(device_id, filename)`**.
- A second POST of the same dive returns **409** with `rows_ingested: 0`.
- The device treats 409 as "already synced, mark done".

A logger that retries after a dropped connection therefore cannot double a dive.

> **LIMIT.** The key is the NAME, not a checksum. If a logger ever rewrote `dive0007.csv`
> with different content, the station would answer 409 and keep the first copy. That is
> correct for immutable files and wrong for anything else. Nothing compares content. See
> §16.

> **VERIFY BEFORE COSTING.** Breach state does not appear in the 25 columns. If breach must
> be recomputed from `deploy.thresh[]`, that means re-implementing the firmware tile-state
> logic on the Pi and keeping two copies in sync forever. Check this before treating breach
> rendering as cheap. If it is a recompute, consider appending a breach column to the CSV
> instead — **append at end only.**

---

## 4. Data model

`stations` and `readings` are inherited unchanged from the base station design. The wide
`sensor / metric / value / unit` shape absorbs new sensors without migrations.

### New: observation grouping **[LOCKED]**

Automated rows are independent. Manual rows are not. A student records eight metrics at
one site at one moment. That is a batch, and the grouping is expensive to retrofit.

```sql
create table public.observations (
  observation_id uuid primary key,
  station_id     text not null references public.stations(station_id),
  observer       text,               -- free text in V1, roster FK later
  site_label     text,
  ts             timestamptz not null,   -- when the observation was made
  entered_at     timestamptz default now(),  -- when it was typed
  lat double precision, lon double precision,
  note           text,
  quality_flag   text                -- 'plausible' | 'implausible' | 'verified'
);

alter table public.readings
  add column observation_id uuid references public.observations(observation_id),
  add column value_raw   double precision,   -- what the student actually typed
  add column unit_raw    text,               -- the unit they typed it in
  add column ref_distance_m double precision; -- distance to reference source, see §6
```

Field rationale:

| Field | Why it exists |
|---|---|
| `observation_id` | eight metrics at one moment are one event, not eight |
| `observer` | who took it, no login required |
| `note` | "water looked cloudy after the rain" — the most valuable column in a student dataset |
| `ts` vs `entered_at` | observation time is not typing time; they enter it back at the truck |
| `value_raw` + `unit_raw` | they will enter °F; store what they typed and the canonical conversion |
| `quality_flag` | plausible, implausible, or teacher-verified |
| `ref_distance_m` | comparing a gauge to a grid cell 12 km away is a different claim than one on top of it |

### Two quality flags, not one **[LOCKED]**

`observations.quality_flag` and `readings.quality_flag` both exist. They answer different
questions, so the station needs both.

| Column | The question it answers | Migration |
|---|---|---|
| `observations.quality_flag` | Is this whole batch under review? | 0005 |
| `readings.quality_flag` | Is this one number implausible? | 0007 |

**A batch flag cannot mark one bad metric among eight.** A student records eight metrics
at one site. Seven numbers are good. The pH reads 700. The batch flag cannot say which
number is wrong, so the row carries its own flag.

Both columns take `plausible`, `implausible`, or `verified`. Neither column blocks a save.
Hard rule 1 and hard rule 12 both stand.

### Provenance

```sql
alter table public.readings
  add column provenance jsonb;   -- migration 0010
```

A generator writes here what made the row: the seed, the parameters, and the generator
version. A measurement leaves the column empty.

This column satisfies the §5 requirement that derived rows store what they came from. A
person can rebuild the exact series from any one row, months later. A row with a synthetic
source and an empty `provenance` is a defect.

### The sources registry **[LOCKED]**

```sql
create table public.sources (          -- migration 0003
  source      text primary key,
  kind        text not null,           -- measured | manual | synthetic | reconstructed | public
  is_real     boolean not null,
  render_hint text not null,           -- solid | dashed
  description text not null
);

alter table public.readings
  add constraint readings_source_fkey
  foreign key (source) references public.sources(source);
```

`readings.source` is a foreign key to this table. A source that is not in the table cannot
enter the database. A driver with a typo in its source name then fails at the write,
loudly, instead of failing silently on a chart six months later.

| Column | What it does |
|---|---|
| `is_real` | True when a person or an instrument measured the value. False for a fixture. |
| `render_hint` | How a renderer must draw the series. `solid` or `dashed`. |

**`render_hint` is the contract. Every renderer binds to it.** A renderer must not compare
source names against a list held in its own code. That list rots as soon as somebody adds
a source. Add a source with a migration, and every renderer follows without a code change.

Free text cannot enforce §5, because a typo makes a new and silent source value. This
table makes the rule structural.

### Hard rule: flag, never reject

A student enters pH 700. Warn clearly. Show the plausible range. Let them save it, flagged.

Blocking the entry teaches distrust of the tool and hides the teaching moment. Give the
teacher a review queue for implausible readings instead of a locked input.

### Hard rule: manual entry is permanent

Manual entry is not scaffolding for missing automation. A student who reads the
instrument and types the number owns that datum. That is the pedagogy.

When automation lands, manual entry becomes the **ground-truth lane**. Plot both together:
"your reading against the sensor's reading." Instrument agreement, drift, and operator
error all become visible. It is free once both paths write to the same table.

### The ground-truth lane arrived with the dive bridge

Dive metrics are stored as `sensor='water'` with `source='wql'`. A student's manual
reading is stored as `sensor='water'` with `source='manual'`.

The two therefore share a join key. A manual `water/ph` and a logger `water/ph` compare
directly, and the `sources` table keeps them apart on the screen: `wql` and `manual` are
both real and both draw solid, but they stay separate series.

**This cost nothing to build.** The lane described above is not a future feature. It is
what the wide `sensor / metric / value / unit` shape gives once two paths write the same
metric. A teacher can already put a student's pH against the logger's pH on one axis.

---

## 5. Source labelling **[LOCKED]**

Synthetic and reconstructed data must be structurally and visually unmistakable.

- A distinct `source` value. Never `manual`, never a sensor name.
- The chart renders it dashed or tinted.
- A persistent "simulated" badge stays on screen. Not a tooltip.
- Reconstructed rows store what they were derived from, so provenance survives.

**Where the last rule lives.** `readings.provenance`, a `jsonb` column added by migration
0010. A generator writes its seed and its parameters there, so a person can rebuild the
exact series from any one row. See §4, "Provenance". A row with a synthetic source and an
empty `provenance` is a defect.

**Why this is a hard rule.** The failure mode is a screenshot where synthetic and real
data look identical. Six months later a teacher analyses fake soil pH and believes it is
their creek. Reconstructed data is more persuasive than random data, which makes
mislabelling it more dangerous, not less.

**V1 status:** synthetic is a **test fixture only**. Deterministic, seeded, used to
develop the correlation UI before real data exists and to reproduce bugs. It is not a
shipped data source and it is not in the demo. See §6.

---

## 6. Public data as a comparison lane

This is the core intellectual content of the product. Three tiers, each strictly better
than the last, all shipping on the same `readings` table.

| Tier | What it does | Status |
|---|---|---|
| **1. Reconstruction** | Read a real dive, find the excursion already in it, back-fill the cause with a plausible lag | Test fixture only. Not in V1 demo. |
| **2. Public lookup** | Fetch the actual public record (NOAA, WOA) for that place and time, and overlay it | V2 |
| **3. Local vs public** | Student's own instrument against the public number for the same metric | V3 |

**Tier 2 is why the reconstruction is a fallback and not a feature.** Weather is
historic and public. Every reading carries GPS and UTC. So the honest version is a
lookup, not a generator. Nothing synthetic remains in the shipped product.

The teaching value is stronger than owning a gauge: the student does not need a weather
station, because the weather is already recorded by somebody else, publicly, and their
data can be joined to it. That teaches that a measurement has context, that public data
exists, and that joining datasets is how environmental science actually works. A rain
gauge teaches wiring.

**Tier 3 is the better lesson, and it is the one that matters beyond a classroom.**
NOAA gives the regional grid. A gauge in the schoolyard gives what fell on that creek.
They disagree, and the disagreement is the teaching. Florida convection is local — it
pours on one block and stays dry three streets over. A student who finds that gap has
learned something true about the limits of gridded data.

**[LOCKED] Public data is a comparison lane, not a data source.** A source is something
you plot. A lane is something you plot *against*, with the difference itself a
first-class quantity: residual, bias, agreement over time. `sensor` and `metric` are
already the join key, so a public row and a student row for the same metric at the same
time compare directly with no new structure.

This generalizes across the whole suite. Their air temperature against NOAA's. Their
water temperature against WOA climatology. Their soil moisture against a satellite
product. Every metric gets a "how do I compare" view.

**Framing rule.** The pitch is not "NOAA is wrong." NOAA is doing its job at its scale.
The claim is that gridded data cannot see local convection, that nobody is measuring at
this resolution, and that this tool puts a measurement there. The gap is the opportunity.
That framing survives a reader who knows how gridded precipitation products work. The
villain framing does not.

**V3 aspiration — contributed data source.** A student whose local measurement is better
than the public number, where nobody else is measuring, is making a contribution. Known
precedents exist: CoCoRaHS feeds volunteer rain gauges into forecasting, GLOBE feeds
student environmental data to NASA. This requires trust infrastructure — calibration
records, siting metadata, quality flags. The logger's `callog.csv` audit trail is the
right pattern extended to student instruments. **V1 obligation: do not preclude it.**

---

## 7. The relation builder

The generalization of tier 3, and the actual product.

Pick any two metrics, from any source, at any lag, and see whether they move together.
Sensors become one input among many rather than the whole point.

Three linked views on one screen:

1. **Overlay** — metric A and B, shared time axis, dual y-axes, normalize toggle.
2. **Scatter** — A against B, one point per matched timestamp, fitted line, r shown.
3. **Plain-language caption** — auto-generated, for example: "When rainfall rises,
   turbidity rises about 6 hours later. Correlation is strong (r = 0.78)."

**Lag slider is required, not optional.** Rain to turbidity and sun to temperature are
the correlations students will actually find, and both are lagged. A zero-lag view shows
them nothing, and they will conclude the tool is broken.

**[LOCKED] Estimate the lag by sweeping for the strongest correlation. Do not compare
peaks.**

Slide one series against the other, one step at a time. Keep the shift where the
correlation is strongest.

Peak to peak looks easier, and it is wrong. Rain keeps falling after its own peak, so the
water keeps getting fresher after it. The deepest dip therefore arrives later than the
mechanism. On the seeded fixture, peak to peak answers 7 hours where the generator used 6.
The sweep answers 6.

**The caption says "about", and that word is load bearing.** The recovered delay moves
with the sample rate. The same fixture returns 6.0 hours at hourly samples, and about 6.8
hours at 10 minute samples, because rain spread across an hour widens the response. The
number is an estimate. The caption must not pretend otherwise.

**Hard rule.** "Correlation is not causation" appears as a permanent caption on the
screen, not a tooltip. If the tool teaches data literacy, it teaches the caveat too.

---

## 8. Knowledge base

**[LOCKED] Ours in V1, Kiwix in V2.**

- **V1** — our curated articles as static markdown, in-repo, built at image bake time.
  Versioned, reviewable, tiny. Two articles is enough for a proof of concept. They exist
  to be a talking point during the demo.
- **V2** — Kiwix plus ZIM files for the long tail. ZIM files are gigabytes, so this is a
  storage and bake-time decision, not a drop-in.

**[LOCKED] Shallow, not deep.** V1 articles sit beside the charts. They do not embed
live queries against the student's own data. The deep templated version — where the pH
article opens with *your* readings from *your* last site visit — is a thing we **pitch**,
not build. Showing a live correlation from their own creek data while saying "this is
what the tutorial layer plugs into" sells the next phase harder than a half-built version
of it.

**[LOCKED] ASD-STE100.** All knowledge-base prose and UI copy uses Simplified Technical
English. Short sentences. Active voice. One instruction per sentence. Approved dictionary.
This is right for students and for ESL classrooms. **Make it a lint rule on the markdown,
not a good intention.**

Deferred third-party offline software (V2+): JupyterLab for student analysis, Datasette
for zero-code SQL exploration.

**Offline map tiles are not optional and get forgotten.** A GPS site map with no internet
is a blank grey square. Serve PMTiles or MBTiles locally. Bake a Brevard County slice at
image time. Same for historic normals — a creek bed has no route to an API, so pre-bake a
regional WOA and NOAA-normals slice and refresh it opportunistically on uplink.

---

## 9. Hardware baseline

Inherited, plus the items the Pelicase and the student user force.

- **Compute:** Raspberry Pi 5
- **Display:** ROADOM 10.1" touchscreen
- **Storage: NVMe HAT. HARD RULE.** TimescaleDB on the microSD will die.
- **Power protection: UPS HAT.** Students will unplug it. Add a graceful shutdown button
  in the UI and on GPIO.
- **Clock: Pi 5 onboard RTC with the battery fitted. REQUIRED HARDWARE, NOT OPTIONAL.**
  **The battery is not fitted today.** A power cut therefore sets the clock to 1970.
  Measured on 2026-08-15: after Scott cut the power, the kernel logged
  `setting system clock to 1970-01-01T00:00:09 UTC`. NTP repaired the clock, but only
  because a network was present. A field session has no network and may have no GPS fix.
  Every reading after a power cut would then carry a 1970 timestamp, and land 56 years in
  the past. Hard rule 13 throws those readings away, so the station records nothing rather
  than something wrong. GPS provides time outdoors. Indoors with no fix, a timestamp is
  still required. **Fit the battery.**
- **GPS:** USB or UART/I2C HAT, via `gpsd`
- **Wired sensor bus:** USB-RS485 dongle, Modbus RTU **[LOCKED]** (V2+)
- **Buoy link:** LoRa HAT, US915, point-to-point **[LOCKED]** (V3+)
- **Uplink radio:** OPEN. Ethernet and/or USB WiFi and/or cellular. See §10.
- **No onboard ADC. HARD RULE: buy Modbus, SDI-12, or digital sensor variants, never
  analog.** An ADC HAT for two sensors is a non-goal.

**Software deployment: native Debian packages under systemd. No Docker.** See §2.
TimescaleDB comes from the Timescale packagecloud repository, because the Debian package
holds the Apache edition and has no continuous aggregates. The classroom image therefore
depends on a third-party repository.

**Unmodelled and it will bite:**

| Item | Concern |
|---|---|
| Power budget | Pi5 + 10.1" screen ≈ 15–25 W. A 5-hour field day needs ~100–150 Wh. That is a battery, not a power bank. |
| Thermal | Sealed Pelicase + Pi5 + Florida sun. Lid-open operation only, or active cooling and a vent. **Model this before mechanical firms up.** |
| Kiosk escape | Chromium kiosk, no window-manager chrome, no keyboard shortcuts out. Assume adversarial curiosity. |

---

## 10. Network topology **[LOCKED]**

The Pi's single built-in WiFi cannot be the loggers' AP and reach the internet on the
same radio. Concurrent AP+STA on one chip exists via virtual interfaces, but it is
channel-locked and unreliable. Same constraint the ESP32 has, one layer up. Resolved the
same way: **a separate radio for the separate job.**

```
  WQL loggers ──WiFi──▶ [ wlan0: hostapd AP ]  Pi5  [ uplink iface ]──▶ Internet ──▶ Supabase
                         (dnsmasq, local net)         eth0 / wlan1 / wwan0
```

- **[LOCKED] Pi-as-AP.** `wlan0` runs `hostapd` and `dnsmasq`. Loggers always have an AP.
- **[LOCKED] Route-agnostic offload.** The offload service watches for *any* default
  route. It does not care which interface provides it. The Pi buffers to Timescale when
  offline and drains when a route appears. The station is never required to be always
  online, only eventually.

| Uplink | Best for | Cost / caveat |
|---|---|---|
| Ethernet (`eth0`) | lab or dock with a drop | free, no radio, useless in bare field |
| USB WiFi (`wlan1`) | site WiFi or tethered hotspot | ~$15, pick a mainline ARM64 driver |
| Cellular (`wwan0`) | field with zero infrastructure | SIM + plan + antenna; the only truly autonomous option |

**OPEN:** which uplink radios ship. Lean: ethernet plus one field uplink.

---

## 11. Cloud offload **[LOCKED]**

The Pi is a **trusted server**, not a sealed ESP32. It holds the secret key
(`sb_secret_…`) and writes `stations` and `readings` directly via PostgREST or a direct
Postgres connection. No publishable-key or MAC-allowlist dance — that path belongs to the
sealed logger only, and it is unchanged.

Secret lives in `.env`. Never in git.

Mirror `readings` in Timescale as the buffer. Offload is a straight
`select here → insert there` because both ends are Postgres.

---

## 12. Identity **[LOCKED]**

**No login screen in V1.** The **station** is the identity.

`observation.observer` is a free-text field in V1. A minimal roster — the teacher types a
list of names, the student picks one from a dropdown, no auth — comes in V2. A grouping
with no owner is half a feature, but a text field closes that gap for a proof of concept.

No passwords. No reset support burden. No lost-account class disruption. Cloud-side
multi-tenancy arrives when a district asks for it.

---

## 13. Deferred sensor suite (V2+)

Full eventual suite. Interface column is the target ingest path.

| # | Sensor | Parameters | Target interface | Tier |
|---|---|---|---|---|
| 1 | WQL Logger | full dive suite | HTTP → bridge → MQTT | **V1** |
| 2 | GPS | lat/lon/time | USB/UART, `gpsd` | **V1** |
| 3 | Apera PC60 | ORP, pH, EC, temp | manual entry card | **V1** |
| 4 | Soil probe | pH, temp, moisture, air humidity, light, fertility | RS485/Modbus | V2 |
| 5 | Air probe | PPM, wind speed, wind dir, temp, humidity, UV | RS485/Modbus | V2 |
| 6 | Rain gauge | tipping-bucket rainfall | **by hand in V1**, GPIO pulse in V2 | **V1** |
| 7 | Noise | dB SPL | RS485 or I2S | V3 |
| 8 | Creek current | flow/velocity | RS485 or SDI-12 | V3 |
| 9 | Buoy current | speed + velocity | LoRa | V3 |

### The rain gauge is a working sensor today **[LOCKED]**

**CORRECTED 2026-08-16.** The rain gauge was listed as planned. It is not planned. Scott
reads it and types the number three times a day, and manual entry is built and gated.

**Absence of data is not absence of capability.** A gauge that nobody read this morning
still works. It therefore carries the manual chip, beside the Apera PC60, and the station
counts 3 of 9 sensors working: one live, two by hand.

The tile reads `rain / rainfall` from source `manual` ONLY. The synthetic fixture
publishes rainfall on every run, and that number must never appear beside a real sensor.
Two doors keep it out: the tile names its permitted sources, and the query demands
`is_real`.

GPIO on a tipping bucket replaces the typing in V2. That changes who does the work. It
does not change whether the station can measure rain.

Items 4, 5, 7, and 8 all target one shared RS485 twisted pair. The "nine protocols"
problem collapses to one Modbus poller, plus GPIO, `gpsd`, LoRa rx, the logger bridge,
and the Apera manual card.

**Draft Modbus address map** (assign now, even though the bus is V2):

| Addr | Sensor |
|---|---|
| 0x01 | Soil 7-in-1 |
| 0x02 | Air probe |
| 0x03 | Noise, if a Modbus variant is sourced |
| 0x04 | Creek current |

**Wiring rules:** 120 Ω termination at **both** ends. Daisy-chain, never star. Common
ground reference across all nodes. Fail-safe biasing resistors at the master.

**LoRa:** US915 (Florida). Point-to-point, not LoRaWAN — one buoy to one base needs no
network server. Revisit only if buoy count grows.

### Apera PC60

Confirmed a dumb LCD with buttons. No data port. Reverse engineering is required *if* we
want it automated. Cheapest-signal-first:

1. **Open and logic-analyze the MCU pins.** Best case: an internal UART or I2C already
   carries live readings. ~1 hour with a $10 analyzer. It wins outright or rules itself
   out. **Do this first.**
2. **Sniff the LCD bus.** If an identifiable I2C/SPI controller drives the glass, capture
   traffic and rebuild the segment-to-digit map. Dead end if it is a glob-top COB.
3. **OCR the LCD with a small camera.** Always-works fallback, `ssocr`-class. Needs stable
   mounting and lighting.

**Reality check:** a PC60 is a handheld spot-check tool, not a continuous logger.
Auto-off, battery life, and probes not rated for permanent immersion all fight continuous
deployment. Its real value is **manual ground truth** to validate the fixed Modbus
sensors. If so, "integration" is the manual entry card, which ships in V1 anyway.

---

## 14. V1 line

**IN:** kiosk UI · local API · TimescaleDB · manual entry with `observation_id` grouping ·
free-text observer · `gpsd` · RTC · WQL bridge ingest · two-metric overlay chart ·
**lag slider with an auto-caption** · logger threshold breach display ·
two static markdown articles · CSV export · seeded synthetic test fixture.

**OUT:** Modbus drivers · LoRa buoy · noise · creek · Apera reverse engineering ·
cloud offload · NOAA lookup · **scatter plot** · roster management ·
**teacher review queue** · threshold configuration UI · Jupyter · Kiwix ·
deep templated tutorials.

> **CORRECTION, 2026-08-15. The teacher review queue moves to OUT.** §4 promises one:
> "Give the teacher a review queue for implausible readings instead of a locked input."
> It is not built, so this section must say so rather than leave the promise hanging.
>
> What IS built: an implausible value saves, carries `quality_flag='implausible'` on both
> the row and the batch, and shows a FLAGGED tag on the entry screen. What is NOT built:
> anything that collects those flags. Nothing lists them, filters them, or tells a teacher
> they exist. A person must already be looking at the right screen.
>
> **A flag nobody reviews does nothing.** The column is honest and the seam is cheap, but
> the promise in §4 is not kept until something gathers the flags.
>
> **The seam for V2 is `/api/flagged`**, one endpoint returning every reading with
> `quality_flag='implausible'` and its observation. The data is already there. The work is
> the endpoint and a screen, not a schema change.

> **CORRECTION, 2026-08-15.** An earlier version of this section listed "scatter and lag
> correlation" as OUT. That contradicted §7, which makes the lag slider required, not
> optional. The correct reading is: **the lag slider is IN, and the scatter plot is OUT.**
> §7 wins. The overlay chart carries the lag slider and the plain-language caption. The
> scatter view, the fitted line, and the printed r stay OUT of V1.

**Rationale for the cut.** V1's job is to win the decision to build more. The audience is
the buyer, not the student. A demo needs a moment where someone says "I see it." Ingest
plus charts alone looks like a spreadsheet with extra steps. The moment comes from two
metrics on one time axis with a visible relationship. So the two-metric overlay stays
firmly in, and single-metric charts are whatever falls out of building it.

Every deferred item slots in without rework, because of the MQTT spine.

---

## 15. Hard rules

1. **Flag, never reject.** Implausible student entries save with a flag. Never block.
2. **Manual entry is permanent.** It is the ground-truth lane, not scaffolding.
3. **Synthetic and reconstructed data are unmistakable.** Distinct `source`, dashed
   render, persistent badge, stored provenance.
4. **Buy digital, never analog.** Modbus, SDI-12, or digital variants only. No ADC HAT.
5. **CSV schema is append-only.** New columns go at the end, to preserve the portal chart
   parser's column-index assumptions.
6. **Secrets never in git.** `.env` and Supabase secrets only.
7. **Schema changes via CLI migration**, never the dashboard.
8. **ASD-STE100 for all knowledge-base and UI prose.** Lint it.
9. **TimescaleDB on NVMe**, never microSD.
ACTIVE EXCEPTION, dev cycle only, opened 2026-08-15 by Scott. NVMe not yet in
hand. Dev and the 20th demo run on microSD. Load is minimal. This exception closes
when the NVMe arrives. It does not survive into any classroom deployment.
Mitigation: nightly pg_dump off the card, see §16.
10. **Correlation is not causation** is permanent on-screen text.
11. **No `#` comments in bash.**
12. **Flag, never reject — student values only.** An implausible number a student typed saves with quality_flag. Never block the input. This does not extend to driver metadata: an unrecognized source is rejected at insert, loudly, because silently accepting one is how a synthetic row ends up rendering as real.
13. **Reject an implausible clock.** Refuse any reading with a timestamp before
    2026-01-01, or more than 24 hours in the future. Log the payload at error with
    `reason=implausible_clock`. Count the rejection. **A missing reading beats a corrupt
    one.** The RTC battery is not fitted, so a power cut sets the clock to 1970 and every
    later reading is silently wrong. This rule discards the timestamp. It does not repair
    the clock. See §9.
14. **Refresh the rollup after a backdated write.**

    > Any write path that inserts or modifies data outside the real-time
    > aggregation window must refresh the affected rollup ranges before
    > returning. The chart reads rollups. A write that skips the refresh is
    > invisible or wrong on screen while appearing to succeed. Found three
    > times: corrections, deletions, and backdated dive ingest. Every dive is
    > backdated - the logger records under water and uploads on surfacing.

    Only the owner of a continuous aggregate may refresh it, so migration 0012 gives the
    application role that ownership. A `SECURITY DEFINER` wrapper cannot work, because
    `refresh_continuous_aggregate` controls its own transactions and PostgreSQL forbids
    that inside a `SECURITY DEFINER` routine. See §16 for what that ownership costs.

---

## 16. Known blind spots

Locked section. An open blind spot is never dropped at purge.

| Gate / claim | This proves | This does **not** prove | Status |
|---|---|---|---|
| Threshold breach rendering | breaches arrive with the dive | that breach state is **in** the CSV. It is not, in the 25 columns the firmware writes. May require recompute of firmware tile-state logic on the Pi. | **OPEN** — verify before costing, §3 |
| MQTT spine absorbs future drivers | manual entry and Modbus share a record shape | that Modbus timing, error, and retry semantics fit the same driver contract. No Modbus driver has been written. | **OPEN** — closes when driver #1 lands |
| `readings` absorbs public data | schema needs no migration for a NOAA row | that fetch, cache, and offline behaviour are solved. They are not designed. | **OPEN** — closes in V2 |
| `observation_id` grouping | manual batches are modelled correctly | that the free-text observer survives contact with a classroom. It may collide, be misspelled, or be left blank. | **OPEN** — closes with V2 roster |
| Source labelling rule | the data layer distinguishes synthetic, **and the overlay chart honours it**. 30 headless Chromium checks pass against `chart-core.js`, the same file the live page loads. They include the fail-closed cases: a missing, null, empty, wrongly cased, or numeric `render_hint` draws dashed and raises the banner. A series that claims `is_real: true` with a broken hint still draws as not real. A control case proves a properly labelled real series still draws solid. | that **any other renderer** honours it. The rule lives in JavaScript, not in the data. A second chart, a live tile, a kiosk widget, or a CSV export can still get it wrong. The rule closes one renderer at a time, and it never closes globally. | **PART DONE** — closes per renderer, §17 |
| Pelicase thermal | nothing yet | that a sealed case in Florida sun stays under thermal throttle. Unmodelled. | **OPEN** — blocks mechanical |
| Power budget | nothing yet | that a field session runs to completion. Unmodelled. | **OPEN** — blocks BOM |
| Demo schedule | nothing yet | that a divergent storm occurs before the pitch date. Unbounded wait, no engineering fix. | **OPEN** — see `MobileLab-Demo-Story.md` |
| Storage on microSD | the stack runs and the demo works | that the card survives sustained write load. Postgres write amplification kills SD cards. Zero endurance evidence. | **OPEN** — exception, closes on NVMe arrival |
| RTC battery absent | nothing yet | that a timestamp taken after a power cut is right. The battery is not fitted, so the clock reads 1970 until NTP repairs it, and a field session has no network. Hard rule 13 discards those readings, so the station records nothing instead of something wrong. That is data loss, chosen on purpose. | **OPEN** — closes when the battery is fitted, §9 |
| `data_checksums` off | nothing yet | that PostgreSQL can detect a corrupt page. Debian leaves checksums off by default, so corruption stays silent. This matters more while hard rule 9 runs under its microSD exception, because a worn card corrupts quietly. | **OPEN** — closes with `pg_checksums --enable` on a stopped cluster |
| MQTT durability | a stopped writer loses nothing. The broker holds QoS 1 messages for a persistent session and delivers every one at reconnect. | that a power cut loses nothing. Mosquitto writes its queue to disk every 60 seconds, so a power cut can lose up to a minute of queued messages. The test stopped the writer, not the broker. | **OPEN** — closes with a shorter autosave interval, or with a UPS HAT |
| Continuous aggregate correctness | a wide query reads a rollup and not a raw scan | that the rollup matches the raw table after a deletion. Deleting a raw row does **not** remove its aggregate bucket. Measured on 2026-08-15: 52 hour buckets survived with no raw row behind them, and the chart would have drawn deleted data. The refresh policy repairs this inside its window only. A correction older than the window stays wrong indefinitely. | **OPEN** — needs a correction procedure in the runbook, see `db/README.md` |
| Local API and bridge exposure | the kiosk browser, a teacher laptop, and a WQL logger all reach the station | that it is safe on a shared network. The API binds `0.0.0.0` with no authentication and `/docs` is open, and the bridge does the same on port 8081. **CORRECTED 2026-08-15: the API is NOT read only.** It was when that claim was written. Since the entry form landed, anybody on the network can save, correct, or delete a reading, and anybody can upload a dive. The README carried the stale "read only" claim and has been fixed. | **OPEN** — dev cycle only, must close before any classroom network |
| CSV header validation | **CORRECTED 2026-08-16.** A wrong COUNT is refused, a RENAMED column is refused, and a REORDER is refused. The guard compares the header to the documented header in order and names the offending columns and positions. `verify-bridge.sh` gate 7 proves it with two same-typed columns swapped and all 25 columns kept. An earlier version of this row said a reorder would pass. It does not. | that the station reads the MEANING right. The guard checks names and positions, not units. A firmware that keeps all 25 names in order and changes what a column holds, such as `poetT_mC` in degrees rather than milli degrees, passes every check and is stored wrong. Nothing records which firmware version wrote a file. | **OPEN** — needs a firmware version field in the meta header, §3 |
| Dive idempotency | a repeat upload of the same file answers 409 and writes nothing | that an EDITED file is caught. The key is `(device_id, filename)`, not a checksum. A logger that rewrote `dive0007.csv` with new content would be turned away and the first copy kept. Correct for immutable files, wrong for anything else. | **OPEN** — closes with a content hash on the manifest, §3 |
| Dive completeness | rejected rows are counted, logged, and stored on the manifest | that a dive with gaps reads as a dive with gaps. A dive that lost samples to a bad clock ingests as a whole dive. `rows_rejected` records it on the manifest, but no chart marks the gap, and a reader sees an unbroken profile. | **OPEN** — needs a gap marker on the chart |
| Teacher review queue | a flag is written on the row and the batch, and the entry screen shows it | that anybody reviews it. Nothing collects flagged rows. There is no list, no filter, and no alert. A flag nobody reviews does nothing. §4 promises this queue and §14 now records it as OUT for V1. | **OPEN** — `/api/flagged` is the seam, §14 |
| Deletion is not auditable | a removed reading leaves the raw table and its rollup bucket | that anybody can tell what was removed. Nothing records who deleted a row, when, or what it held. A student can quietly remove a reading that did not suit them. | **OPEN** — needs an audit table, the logger's `callog.csv` is the pattern, §6 |
| Aggregate ownership | the application role can refresh a rollup, which hard rule 14 requires | that the role is least privilege. Migration 0012 makes `mobilelab` the OWNER of both continuous aggregates, so the role can also DROP them. A `SECURITY DEFINER` wrapper cannot replace this, because `refresh_continuous_aggregate` controls its own transactions. | **OPEN** — accepted cost, revisit if a stricter role model is needed |
| Bridge parse path | the parser reads the documented 25 column FORMAT, proven by a generated file | that it reads a REAL dive. **No WQL logger has ever POSTed to this station.** Every gate used `mobilelab.divefixture`. A real file may carry meta lines, blank channels, or edge cases the generator never produces. | **OPEN** — closes on the first real upload |
| **GPS bridge baud workaround** | the relay can hold the port at a non-standard rate, and the rate is configuration and not code. `MOBILELAB_GPS_BAUD` in `.env` carries it, 9600 is the documented correct value, and the relay logs a loud warning at every start while the value is not 9600. Proven both ways on 2026-08-18. | that GPS works. The PL2303 transmits about 8.5 percent fast and reading faster only compensates for a broken part. **On 2026-08-18 the receiver went silent and delivers ZERO bytes at 9600, 10000, 10200, 10416 and 10600, before and after a USB unbind and rebind.** So the workaround is configured and unproven on live data, and no green badge has ever been observed. | **OPEN** — ACTIVE EXCEPTION. It closes when the CP2102 or FT232R is fitted and `MOBILELAB_GPS_BAUD` returns to 9600. It must not become permanent. |

---

## 17. Negative tests, standing rule

Every hardware or state gate ships with a companion test that deliberately breaks the
condition the gate exists to catch, and confirms the gate reports the break.

Required at V1:

- **Source labelling.** Inject a synthetic row into a real dataset. Confirm the chart
  renders it dashed and the badge appears. A synthetic row that renders as real is a
  defect.
- **Implausible entry.** Enter pH 700. Confirm the row saves, carries
  `quality_flag='implausible'`, and appears in the review queue. A rejected entry is a
  defect. A silently accepted one is also a defect.
- **Offline buffer.** Pull the uplink mid-session. Confirm readings continue to land in
  Timescale, and drain when the route returns.
- **Power yank.** Cut mains with the UPS HAT fitted. Confirm graceful shutdown and no
  database corruption.

A gate that stays green under a deliberate break is a defect found on our terms.

### Standing rule: gates run at demo scale

> Gates validated at toy scale prove the code path, not the behaviour. Any
> gate that touches aggregation, retention, or a time window must run at
> demo scale before it counts as passed. The 0011 defect - readings_1m
> refreshing only a 3 hour window, leaving 45 of any 48 hours never
> materialised - passed three separate suites at toy scale.

State the row count and the time span each gate ran against. A gate that does not report
its scale has not reported its result.

---

## 18. Open decisions

| # | Decision | Lean | Blocks |
|---|---|---|---|
| 1 | Uplink radios — ethernet / USB WiFi / cellular | ethernet + one field uplink | enclosure, power, BOM |
| 2 | Local API stack — FastAPI or Node | **CLOSED 2026-08-15: FastAPI.** Python matches the driver layer, so the services share one virtual environment and one record model. | nothing, it is built |
| 3 | Charting library choice | **CLOSED 2026-08-15: Chart.js 4.4.7.** The repository holds a copy, so the chart draws with no internet. | nothing, it is built |
| 4 | Breach state: CSV column or Pi recompute | append a CSV column | §3, §16 |
| 5 | Battery chemistry and capacity | — | Pelicase mechanical |
| 6 | Cellular carrier and SIM, if cellular ships | — | field autonomy |
| 7 | Which dive carries the demo excursion | — | pending dive CSVs, see story doc |

---

## 19. Harvest record

Decisions harvested from `docs/BaseStation-Arch.md` into this document. Once Scott
verifies this list, that document and the monorepo `basestation/` folder can be purged.

| Base station decision | Landed here |
|---|---|
| Pi-as-AP on `wlan0` | §10 |
| Separate route-agnostic uplink | §10 |
| RS485/Modbus for wired sensors, never analog | §9, §13 |
| Modbus draft address map and wiring rules | §13 |
| LoRa US915 point-to-point for the buoy | §9, §13 |
| TimescaleDB as local store | §2 |
| Custom kiosk UI in Chromium | §2 |
| Secret-key direct offload, Pi as trusted server | §11 |
| `stations` + generic wide `readings` schema | §4 |
| Apera reverse-engineering decision tree | §13 |
| Apera manual-entry card ships either way | §4, §13 |
| Local-sink endpoint mirrors the Supabase contract | §3 |
| Store-and-forward at every hop | §1, §10 |

**Superseded, deliberately:** the base station's implicit V1 ordering, which put the
Modbus driver layer on the critical path. See §1.

**Not yet purged.** `docs/BaseStation-Arch.md` and `basestation/CLAUDE.md` carry a
succession notice. Purge is a five-beats action and only Scott triggers it.
