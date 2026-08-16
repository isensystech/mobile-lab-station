#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VENV_PY="${REPO_ROOT}/.venv/bin/python"

if [ ! -f "${REPO_ROOT}/.env" ]; then
  echo "STOP. ${REPO_ROOT}/.env does not exist. Run the install steps first." >&2
  exit 1
fi

set -a
. "${REPO_ROOT}/.env"
set +a

STATION_ID="${MOBILELAB_STATION_ID:-lab01}"
MQTT_HOST="${MOBILELAB_MQTT_HOST:-127.0.0.1}"
API_PORT="${MOBILELAB_API_PORT:-8000}"
LAN_IP="$(hostname -I | awk '{print $1}')"
BASE="http://${LAN_IP}:${API_PORT}"

RULE="----------------------------------------------------------------------"

say() {
  echo
  echo "${RULE}"
  echo "$1"
  echo "${RULE}"
}

tell() {
  echo "  $1"
}

ask() {
  echo
  echo "  QUESTION: $1"
  echo "  I ask the API like this:"
  echo "    $2"
  echo
}

pyq() {
  "${VENV_PY}" -c "import sys,json
d=json.load(sys.stdin)
$1"
}

clear
cat <<'BANNER'
======================================================================
          MOBILE LAB STATION - EYEWITNESS TEST, LOCAL API
======================================================================

The last test showed data going into the database. This test shows it
coming back OUT, through the local API.

The API is the part the kiosk screen will talk to. Every chart you
will ever see gets its numbers from the addresses below. So if this
test looks right, the chart has good numbers to draw.

There are six steps.

  1. Ask the API if it is well.
  2. Ask what kinds of data exist, and which are real.
  3. Ask what happened over the last 48 hours.
  4. Ask for two measurements on one time axis.
  5. Draw that answer as a chart, from the API.
  6. Watch a live reading arrive.

BANNER
sleep 3

say "STEP 1 of 6. Ask the API if it is well."
tell "The API answers at ${BASE}"
tell "It listens on every network address, so the kiosk browser and a"
tell "teacher laptop can both reach it."
ask "Are you working?" "GET ${BASE}/health"
curl -sS "${BASE}/health" | pyq "
print('  overall status   ', d['status'])
print('  database         ', 'connected' if d['database']['connected'] else 'NOT CONNECTED')
print('  message broker   ', 'connected' if d['broker']['connected'] else 'NOT CONNECTED')
w = d['writer']
if w is None:
    print('  writer           NO REPORT')
else:
    print('  writer accepted  ', w['accepted_total'], 'readings stored')
    print('  writer rejected  ', w['rejected_total'], 'readings refused')
    print('  writer reasons   ', w['rejected_by_reason'] or 'none')
    print('  report age       ', f\"{w['age_seconds']:.1f} seconds\" if w['age_seconds'] is not None else 'unknown')
"
echo
tell "The two counts start again from zero each time the writer starts."
tell "A low number here does not mean data was lost. It means the writer"
tell "started recently."
echo
tell "You want status ok, both parts connected, and a fresh report age."
sleep 3

say "STEP 2 of 6. Ask what kinds of data exist, and which are real."
tell "This is the most important question on the screen."
tell "A source says who made a number. Some sources are real. Some are"
tell "test data. The API always says which."
ask "What sources exist?" "GET ${BASE}/api/sources"
curl -sS "${BASE}/api/sources" | pyq "
print(f\"  {'source':16s} {'real?':8s} {'draw as':10s} {'what it means'}\")
print('  ' + '-'*74)
for s in d:
    real = 'REAL' if s['is_real'] else 'NOT REAL'
    print(f\"  {s['source']:16s} {real:8s} {s['render_hint']:10s} {s['description'][:38]}\")
"
echo
tell "A chart must draw every NOT REAL source dashed. Never solid."
sleep 3

say "STEP 3 of 6. Ask what happened over the last 48 hours."
FROM="$(date -u -d '-48 hours' +%Y-%m-%dT%H:%M:%SZ)"
TO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
tell "A student asks: how much rain fell in the last two days?"
ask "Show me the rainfall" "GET ${BASE}/api/readings?sensor=rain&metric=rainfall&from=${FROM}&to=${TO}"
curl -sS "${BASE}/api/readings?sensor=rain&metric=rainfall&from=${FROM}&to=${TO}" | pyq "
print('  time range     ', d['from'], 'to', d['to'])
print('  answered from  ', d['served_from'])
print('  grouped into   ', d['bucket'] or 'no grouping, full detail')
print()
for s in d['series']:
    real = 'REAL' if s['is_real'] else 'NOT REAL'
    print(f\"  {s['point_count']} points from source '{s['source']}' ({real}, draw {s['render_hint']})\")
    vals = [p['value'] for p in s['points'] if p['value'] is not None]
    if vals:
        print(f\"    highest {max(vals):.2f} {s['unit']}, total {sum(vals):.2f} {s['unit']}\")
"
echo
tell "Look at 'answered from'. It says public.readings_1m."
tell "That is a rollup table, made in advance. The station did not read"
tell "two days of raw numbers to answer this. That is why it is fast."
sleep 3

say "STEP 4 of 6. Ask for two measurements on one time axis."
tell "This is the question the whole product exists to answer."
tell "Rainfall and salinity, side by side, on the same clock."
ask "Do rainfall and salinity move together?" \
    "GET ${BASE}/api/series/pair?a_sensor=rain&a_metric=rainfall&b_sensor=water&b_metric=salinity..."
curl -sS "${BASE}/api/series/pair?a_sensor=rain&a_metric=rainfall&a_source=synthetic&b_sensor=water&b_metric=salinity&b_source=synthetic&from=${FROM}&to=${TO}" | pyq "
print('  answered from  ', d['served_from'])
print('  shared axis    ', len(d['axis']), 'time slots')
for s in d['series']:
    real = 'REAL' if s['is_real'] else 'NOT REAL'
    print(f\"  series {s['key']}: {s['sensor']}/{s['metric']} in {s['unit']}, {len(s['values'])} values, {real}\")
print()
print('  Both series have the same number of values as the axis.')
print('  Slot 7 in the first series is the same moment as slot 7 in')
print('  the second. The chart can draw them straight over each other.')
print()
print('  ', d['caption'])
"
sleep 3

say "STEP 5 of 6. Draw that answer as a chart, from the API."
tell "Now the same answer, drawn. These numbers came from the API, not"
tell "from the generator and not from the database directly. This is"
tell "the exact path the kiosk chart will use."
echo
sleep 2
PYTHONPATH="${REPO_ROOT}/services" "${VENV_PY}" -m mobilelab.plot \
  --api-url "${BASE}" --source synthetic --hours 48 2>&1 | sed 's/^/  /'
sleep 2

say "STEP 6 of 6. Watch a live reading arrive."
tell "The chart also needs new numbers as they happen. The API sends"
tell "those over a websocket. Nothing has to ask for them."
tell "I open a listener, then publish one reading, and we watch it land."
echo
PYTHONPATH="${REPO_ROOT}/services" "${VENV_PY}" -m mobilelab.wslisten \
  --host "${LAN_IP}" --port "${API_PORT}" \
  --count 1 --timeout 12 > /tmp/eyewitness-ws.txt 2>&1 &
WSPID=$!
sleep 2
tell "publishing one soil moisture reading now..."
mosquitto_pub -h "${MQTT_HOST}" -q 1 -t "station/${STATION_ID}/soil/moisture" \
  -m "{\"station_id\":\"${STATION_ID}\",\"sensor\":\"soil\",\"metric\":\"moisture\",\"value\":36.5,\"unit\":\"pct\",\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"source\":\"manual\",\"quality_flag\":\"plausible\"}"
wait "${WSPID}" 2> /dev/null
echo
tell "the websocket delivered:"
sed 's/^/    /' /tmp/eyewitness-ws.txt
rm -f /tmp/eyewitness-ws.txt
echo
tell "The time in brackets is how long the listener waited. The reading"
tell "arrived already marked REAL, with its draw style. The chart does"
tell "not have to ask a second question to know what it is looking at."
sleep 2

say "What to look for."
cat <<'LOOK'
  WHAT IS GOOD. Look for these six things.

  1. Step 1 says status ok, and the report age is a few seconds.

  2. Step 2 lists synthetic and reconstructed as NOT REAL, and lists
     manual, wql and gps as REAL.

  3. Step 3 says "answered from public.readings_1m". A two day
     question must not read raw numbers.

  4. Step 4 shows both series with the SAME number of values as the
     shared axis. Different numbers mean the chart would draw one
     line shifted against the other.

  5. Step 5 shows the SIMULATED marking, draws with the dashed fill,
     puts R before S, and prints CORRELATION IS NOT CAUSATION.

  6. Step 6 delivers the live reading in about a second, already
     marked REAL.

  WHAT IS A PROBLEM. Stop and report any of these.

  1. Step 1 says degraded, or the writer report age keeps growing.
     The writer has stopped. Look at:
       journalctl -u mobilelab-writer -n 50

  2. Step 3 says "answered from public.readings" for a two day
     question. The rollup is not being used and the screen will get
     slow as data grows.

  3. Step 4 shows 0 time slots, or the two series have different
     lengths.

  4. Step 5 draws the test data SOLID, or the SIMULATED marking is
     missing. Fake data is pretending to be real. This is the worst
     failure on this list. Stop the demo.

  5. Step 5 shows no chart and says no rows came back. The fixture
     data is outside the window, or the rollup is empty. Run:
       sudo ops/verify-api.sh

  6. Step 6 times out. The websocket is not delivering, and live
     tiles will stay blank.

LOOK

say "The test is finished."
tell "To run it again, type:"
tell "  ${SCRIPT_DIR}/eyewitness-api.sh"
echo
tell "To read the API documentation in a browser, open:"
tell "  ${BASE}/docs"
echo
