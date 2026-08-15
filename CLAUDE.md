# CLAUDE.md — Mobile Lab Station (Raspberry Pi 5)

Field aggregator, environmental station, cloud gateway, and STEM teaching instrument.

**Authority document: `docs/MobileLab-Arch.md`.** This file is a summary. When the two
disagree, the arch document wins. Read it before any structural work.

**Staleness rule.** This file goes stale faster than the code. Before you rely on a
statement here, check it against `docs/MobileLab-Arch.md` and against the tree. If you
find a mismatch, stop and report it with the specific file and marker. Do not proceed on
a stale base.

Supersedes `basestation/CLAUDE.md` in the `WaterQualitySensor` monorepo. That folder
carries a succession notice and is not yet purged.

## Status
V1 = proof of concept. Its job is to win the decision to build more.

## Spine (locked)
```
manual entry form ─┐
gpsd ──────────────┼─▶ Mosquitto ─▶ writer ─▶ TimescaleDB ─▶ local API ─▶ kiosk UI
WQL bridge ────────┤                                       └─▶ offload svc ─▶ Supabase
synthetic fixture ─┘
```
- The manual entry form IS an acquisition driver. It publishes to MQTT with
  `source: "manual"`, same record shape as any sensor driver.
- One process per protocol family. Normalize, then publish. Adding sensor #10 = write a
  driver, publish a topic. Nothing downstream changes.
- Timescale: hypertables + continuous aggregates. Mirrors the Supabase `readings` schema.
- Kiosk: Chromium, ROADOM 10.1". Local API serves history over REST, live tiles over
  websocket.

## V1 scope
IN: kiosk UI, local API, Timescale, manual entry with `observation_id` grouping,
free-text observer, gpsd, RTC, WQL bridge ingest, two-metric overlay chart, logger
threshold breach display, two static markdown articles, CSV export, seeded synthetic
test fixture.

OUT: Modbus drivers, LoRa, noise, creek, Apera RE, cloud offload, NOAA lookup,
scatter/lag correlation, roster management, threshold config UI, Jupyter, Kiwix,
templated tutorials.

## Hard rules
1. Flag, never reject. Implausible student entries save with `quality_flag`. Never block
   the input.
2. Manual entry is permanent, not scaffolding. It is the ground-truth lane.
3. Synthetic and reconstructed data are unmistakable: distinct `source`, dashed render,
   persistent on-screen badge, stored provenance. A synthetic row that renders as real is
   a defect.
4. Buy digital, never analog. Modbus, SDI-12, or digital variants only. No ADC HAT.
5. CSV schema is append-only. New columns at the end, to preserve the portal chart
   parser's column-index assumptions.
6. Secrets never in git. `.env` and Supabase secrets only.
7. Schema changes via CLI migration, never the dashboard.
8. ASD-STE100 for all knowledge-base and UI prose. Short sentences. Active voice. One
   instruction per sentence. Lint it.
9. TimescaleDB on NVMe, never microSD.
10. "Correlation is not causation" is permanent on-screen text, not a tooltip.
11. No `#` comments in bash.

## Charting
Do NOT reuse the firmware portal SVG renderer (`parseCsv`, `miniChart`, `drawCharts`).
That renderer is correct for 240x320 device tiles. The kiosk uses a charting library.

## WQL ingest
Bridge, not direct MQTT. The logger POSTs over HTTP per `DiveSync-To-Do.md` local mode.
A bridge service republishes to MQTT. This keeps logger local and cloud modes differing
only by URL and key.

OPEN: threshold breach state is not in the known 24-column CSV. Verify whether it is
appended or must be recomputed from `deploy.thresh[]` before costing it as cheap.

## Data model
`stations` + wide `readings` (`sensor` / `metric` / `value` / `unit` / `source`) absorbs
new sensors without migrations. Plus `observations` for manual batches: eight metrics at
one site at one moment is ONE event.

Manual-specific columns: `observer`, `note`, `ts` vs `entered_at`, `value_raw` +
`unit_raw`, `quality_flag`, `ref_distance_m`.

## Public data
It is a comparison LANE, not a data source. You plot against it. The difference is the
first-class quantity. Three tiers: reconstruction (test fixture only) -> public lookup
(V2) -> local instrument vs public number (V3).

Framing: never "NOAA is wrong". Gridded products cannot see local convection. The gap is
the opportunity.

## Network (locked)
- Pi-as-AP: `wlan0` = hostapd + dnsmasq, the AP WQL loggers join.
- Separate uplink: `eth0` / USB-WiFi `wlan1` / cellular `wwan0`. NEVER the AP radio.
- Route-agnostic offload: watch for ANY default route. Buffer to Timescale when offline,
  drain when a route appears. Never required to be always-online.

## Cloud
Pi is a TRUSTED SERVER. It holds the secret key and writes `stations` and `readings`
directly. No publishable-key or MAC-allowlist dance — that is the sealed-logger path only.

## Negative tests, standing rule
Every gate ships with a companion test that deliberately breaks the condition the gate
exists to catch. Required at V1: source labelling, implausible entry (BOTH failure modes
— rejected is a defect, silently accepted is also a defect), offline buffer, power yank.

## Known blind spots
See `docs/MobileLab-Arch.md` §16. Eight open. Do not close one by declaring it.
