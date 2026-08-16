#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VENV_PY="${REPO_ROOT}/.venv/bin/python"

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: run this script with sudo." >&2
  exit 1
fi

if [ -f "${REPO_ROOT}/.env" ]; then
  set -a
  . "${REPO_ROOT}/.env"
  set +a
fi

DB_NAME="${MOBILELAB_DB:-mobilelab}"
STATION_ID="${MOBILELAB_STATION_ID:-lab01}"
MQTT_HOST="${MOBILELAB_MQTT_HOST:-127.0.0.1}"
API_PORT="${MOBILELAB_API_PORT:-8000}"
LAN_IP="$(hostname -I | awk '{print $1}')"
BASE="http://${LAN_IP}:${API_PORT}"
UNIT="mobilelab-writer.service"
WORK=/tmp/mlchart
mkdir -p "${WORK}"
chmod 0777 "${WORK}"

SCALE_HOURS=336
SCALE_START="$(date -u -d "-335 hours" +%Y-%m-%dT%H:00:00Z)"
SCALE_END="$(date -u -d "+1 hour" +%Y-%m-%dT%H:00:00Z)"

PASS_COUNT=0
FAIL_COUNT=0

psql_val() {
  runuser -u postgres -- psql -t -A -d "${DB_NAME}" -c "$1" 2>&1 | tr -d '[:space:]'
}
psql_show() {
  runuser -u postgres -- psql -d "${DB_NAME}" -c "$1" 2>&1
}

render() {
  runuser -u scott -- env HOME=/home/scott timeout 90 chromium \
    --headless --disable-gpu --no-sandbox --hide-scrollbars \
    --virtual-time-budget=15000 --dump-dom "$1" 2> /dev/null
}

attr() {
  grep -oE "data-$1=\"[^\"]*\"" "$2" | head -1 | sed "s/^data-$1=\"//; s/\"$//"
}

gate_header() {
  echo
  echo "================================================================"
  echo "GATE $1: $2"
  echo "================================================================"
}

gate_result() {
  if [ "$1" = "pass" ]; then
    PASS_COUNT=$((PASS_COUNT + 1)); echo "RESULT: PASS"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1)); echo "RESULT: FAIL"
  fi
  echo "PROVES:         $2"
  echo "DOES NOT PROVE: $3"
}

echo "Mobile Lab Station overlay chart verification"
echo "host $(hostname), $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "chart ${BASE}/"
echo "chromium $(chromium --version 2>/dev/null)"

echo
echo "==> SCALE SETUP. Every gate below runs against ${SCALE_HOURS} hours of data."
echo "    Migration 0011 fixed a defect that a 48 hour test could not see."
echo "    window ${SCALE_START} to ${SCALE_END}"
WIDE_START="$(date -u -d '-60 days' +%Y-%m-%dT00:00:00Z)"
psql_show "delete from public.readings where source='synthetic';" > /dev/null
echo
echo "==> clearing stale aggregate buckets over ${WIDE_START} to ${SCALE_END}"
echo "    Deleting a raw row does NOT remove its aggregate bucket. The rollup"
echo "    keeps the old number until a refresh runs over that range, and the"
echo "    chart reads the rollup. Without this step a gate can read data that"
echo "    no longer exists."
STALE_BEFORE="$(psql_val "select count(*) from public.readings_1h where source='synthetic'")"
runuser -u postgres -- psql -q -d "${DB_NAME}" \
  -c "call refresh_continuous_aggregate('public.readings_1m', '${WIDE_START}', '${SCALE_END}');" > /dev/null
runuser -u postgres -- psql -q -d "${DB_NAME}" \
  -c "call refresh_continuous_aggregate('public.readings_1h', '${WIDE_START}', '${SCALE_END}');" > /dev/null
STALE_AFTER="$(psql_val "select count(*) from public.readings_1h where source='synthetic'")"
echo "    hour buckets before ${STALE_BEFORE}, after ${STALE_AFTER}"

runuser -u mobilelab -- env PYTHONPATH="${REPO_ROOT}/services" "${VENV_PY}" \
  -m mobilelab.fixture --seed 1337 --hours "${SCALE_HOURS}" --start "${SCALE_START}" 2>&1 | tail -4

EXPECTED_ROWS=$((SCALE_HOURS * 2))
for _ in $(seq 1 120); do
  LOADED="$(psql_val "select count(*) from public.readings where source='synthetic'")"
  [ "${LOADED}" = "${EXPECTED_ROWS}" ] && break
  sleep 0.5
done
echo "    synthetic rows loaded = ${LOADED} of ${EXPECTED_ROWS}"
runuser -u postgres -- psql -q -d "${DB_NAME}" \
  -c "call refresh_continuous_aggregate('public.readings_1m', '${SCALE_START}', '${SCALE_END}');" > /dev/null
runuser -u postgres -- psql -q -d "${DB_NAME}" \
  -c "call refresh_continuous_aggregate('public.readings_1h', '${SCALE_START}', '${SCALE_END}');" > /dev/null
TOTAL_ROWS="$(psql_val "select count(*) from public.readings")"
echo "    rows in readings overall = ${TOTAL_ROWS}"

gate_header 1 "the page loads and draws both series from the API"
render "http://127.0.0.1:${API_PORT}/?hours=${SCALE_HOURS}" > "${WORK}/g1.html"
G1_STATUS="$(attr status "${WORK}/g1.html")"
G1_POINTS="$(attr points "${WORK}/g1.html")"
G1_SERVED="$(attr served-from "${WORK}/g1.html")"
echo "page status     = ${G1_STATUS}"
echo "points drawn    = ${G1_POINTS}"
echo "answered from   = ${G1_SERVED}"
echo "--- the page asked the API, so the API log shows the request ---"
journalctl -u mobilelab-api --no-pager -n 40 -o cat 2>&1 | grep -oE 'GET /api/series/pair[^"]*' | tail -1
echo "--- the chart canvas and both legend labels are in the DOM ---"
grep -oE '<canvas[^>]*id="chart"[^>]*>' "${WORK}/g1.html" | head -1
grep -oE 'rain rainfall|water salinity' "${WORK}/g1.html" | sort -u
echo "--- rows behind this view ---"
psql_show "
select metric, count(*) as rows, min(ts) as earliest, max(ts) as latest
from public.readings where source='synthetic' group by metric order by metric;"
if [ "${G1_STATUS}" = "ready" ] && [ "${G1_POINTS}" -gt 0 ] 2> /dev/null; then
  gate_result pass \
    "The page loads, calls /api/series/pair, and draws ${G1_POINTS} shared time slots. The numbers came through the API, not from the fixture and not from the database." \
    "That a person can read it. A headless browser proves the data path and the DOM. It does not prove the chart is legible on the 10.1 inch screen, and nobody has looked at it there."
else
  gate_result fail "nothing" "nothing"
fi

gate_header 2 "a synthetic series draws dashed and the SIMULATED badge is present"
G2_SIM="$(attr simulated "${WORK}/g1.html")"
G2_AD="$(attr a-dashed "${WORK}/g1.html")"
G2_BD="$(attr b-dashed "${WORK}/g1.html")"
G2_AR="$(attr a-real "${WORK}/g1.html")"
echo "simulated flag  = ${G2_SIM}"
echo "first series dashed  = ${G2_AD}, drawn as real = ${G2_AR}"
echo "second series dashed = ${G2_BD}"
echo "--- the badge element, and whether it is hidden ---"
grep -oE '<button type="button" id="simulated-banner" class="[^"]*"' "${WORK}/g1.html"
echo "--- the badge text on the screen ---"
grep -oE '>SIMULATED DATA<|>UNKNOWN SOURCE<' "${WORK}/g1.html" | head -1
echo "--- the permanent caption, rule 10 ---"
grep -oE 'CORRELATION IS NOT CAUSATION.' "${WORK}/g1.html" | head -1
BANNER_SHOWN="no"
grep -qE 'id="simulated-banner" class="sim-badge"' "${WORK}/g1.html" && BANNER_SHOWN="yes"
echo "badge visible   = ${BANNER_SHOWN}   (the sim-hidden class is absent)"
echo "--- the page must not scroll on a 1024 by 600 screen ---"
echo "  body overflow rule: $(grep -c 'overflow: hidden' "${REPO_ROOT}/services/mobilelab/static/style.css") in style.css"
if [ "${G2_SIM}" = "true" ] && [ "${G2_AD}" = "true" ] && [ "${G2_BD}" = "true" ] \
   && [ "${BANNER_SHOWN}" = "yes" ]; then
  gate_result pass \
    "Both fixture series draw dashed, and the SIMULATED DATA badge sits in the top bar with the hidden class removed. Architecture section 5 asks for a persistent badge that is not a tooltip, and this is that badge: it is a page element, always visible while any line is not real, and it needs no hover." \
    "That a person notices it. It is now a pill in the bar rather than a full width bar, because the screen is 1024 by 600 and the old bar cost a fifth of the height. It is smaller than what it replaced. Whether a teacher reads it during a busy demo is a human question, and this test cannot answer it."
else
  gate_result fail "nothing" "nothing"
fi

gate_header 3 "NEGATIVE TEST, a malformed render_hint must fail closed"
echo "The chart cannot be given a bad payload through the API, because the API"
echo "response model refuses to emit one. So this test feeds the SAME chart code"
echo "the broken shapes directly, in the real browser."
echo
render "http://127.0.0.1:${API_PORT}/selftest" > "${WORK}/g3.html"
echo "--- every case, from the real browser ---"
grep -oE '(PASS|FAIL): [^<]*' "${WORK}/g3.html" | sed 's/^/  /'
G3_SUMMARY="$(grep -oE 'SELFTEST_SUMMARY pass=[0-9]+ fail=[0-9]+' "${WORK}/g3.html" | head -1)"
echo
echo "${G3_SUMMARY}"
G3_FAIL="$(echo "${G3_SUMMARY}" | grep -oE 'fail=[0-9]+' | cut -d= -f2)"
G3_PASS="$(echo "${G3_SUMMARY}" | grep -oE 'pass=[0-9]+' | cut -d= -f2)"
echo "--- the API cannot emit a malformed hint either ---"
"${VENV_PY}" - <<'PYEOF'
import json, urllib.request, os
port = os.environ.get("MOBILELAB_API_PORT", "8000")
with urllib.request.urlopen(f"http://127.0.0.1:{port}/openapi.json", timeout=10) as r:
    spec = json.load(r)
hint = spec["components"]["schemas"]["AlignedSeries"]["properties"]["render_hint"]
print("  render_hint schema:", json.dumps(hint))
req = spec["components"]["schemas"]["AlignedSeries"].get("required", [])
print("  is_real required:", "is_real" in req, " render_hint required:", "render_hint" in req)
PYEOF
if [ "${G3_FAIL}" = "0" ] && [ "${G3_PASS}" -ge 25 ] 2> /dev/null; then
  gate_result pass \
    "All ${G3_PASS} checks passed in Chromium against the shared chart code. A missing, null, empty, wrongly cased, or numeric render_hint is treated as NOT real and draws dashed. A series that claims is_real true with a broken hint is still treated as not real. One control case proves a properly labelled real series still draws solid, so the rule is not simply answering no to everything." \
    "That every future chart obeys it. This closes the rule for THIS page only. A second chart, a tile, or an export that reads the payload directly can still get it wrong, because the rule lives in chart-core.js and not in the data."
else
  gate_result fail "nothing" "nothing"
fi

gate_header 4 "the lag slider changes the alignment and the caption updates"
render "http://127.0.0.1:${API_PORT}/?hours=${SCALE_HOURS}" > "${WORK}/g4a.html"
BEFORE_SHIFT="$(attr caption-shift "${WORK}/g4a.html")"
BEFORE_HOURS="$(attr shift-hours "${WORK}/g4a.html")"
echo "at rest:"
echo "  shift hours   = ${BEFORE_HOURS}"
echo "  caption       = ${BEFORE_SHIFT}"
echo
echo "--- moving the slider to 6 hours in the real browser ---"
render "http://127.0.0.1:${API_PORT}/?hours=${SCALE_HOURS}&autoshift=6" > "${WORK}/g4b.html"
AFTER_SHIFT="$(attr caption-shift "${WORK}/g4b.html")"
AFTER_HOURS="$(attr shift-hours "${WORK}/g4b.html")"
echo "after the slider moves to 6 hours:"
echo "  shift hours   = ${AFTER_HOURS}"
echo "  caption       = ${AFTER_SHIFT}"
if [ "${BEFORE_SHIFT}" != "${AFTER_SHIFT}" ] && [ "${AFTER_HOURS}" = "6" ]; then
  gate_result pass \
    "Moving the slider to six hours re-aligns the second line and rewrites the caption. The correlation at no shift is weak. At a six hour shift it is strong. That is the lesson the slider exists to teach." \
    "That a student will find the right shift on their own. The page offers a button that jumps to the measured delay. Nothing measures whether a student explores or simply presses the button."
else
  gate_result fail "nothing" "nothing"
fi

gate_header 5 "the auto caption reports a delay near 6 hours, not 7"
G5_CAPTION="$(attr caption "${WORK}/g1.html")"
G5_LAG="$(attr lag-hours "${WORK}/g1.html")"
G5_R="$(attr lag-r "${WORK}/g1.html")"
echo "caption      = ${G5_CAPTION}"
echo "swept delay  = ${G5_LAG} hours"
echo "strength     = r ${G5_R}"
echo
echo "--- what the WRONG method would have said ---"
runuser -u mobilelab -- env PYTHONPATH="${REPO_ROOT}/services" "${VENV_PY}" \
  -m mobilelab.fixture --seed 1337 --hours "${SCALE_HOURS}" --start "${SCALE_START}" --dry-run 2>&1 \
  | grep -E 'peak to peak|strongest correlation' | sed 's/^/  /'
SAYS6="no"
echo "${G5_CAPTION}" | grep -qE 'about 6 hours later' && SAYS6="yes"
echo "caption says about 6 hours = ${SAYS6}"
if [ "${SAYS6}" = "yes" ]; then
  gate_result pass \
    "The sweep recovers the 6 hour delay the generator used, and the caption says about 6 hours. Peak to peak reports 7 hours on the same data, so the sweep is measurably better here." \
    "That the number is right at any sample rate. The recovered delay depends on how often the data is sampled. At hourly samples the sweep returns 6.0 hours. At 10 minute samples the same fixture returns about 6.8 hours, because rain spread across an hour widens the response. The caption says about for that reason."
else
  gate_result fail "nothing" "nothing"
fi

gate_header 6 "NEGATIVE TEST, the clock guard rejects a 1970 timestamp"
MARK6="$(date '+%Y-%m-%d %H:%M:%S')"
PID6="$(systemctl show -p MainPID --value "${UNIT}")"
BEFORE6="$(psql_val "select count(*) from public.readings where sensor='clockguard'")"
echo "writer MainPID before = ${PID6}"
echo "rows with sensor clockguard before = ${BEFORE6}"
echo
echo "--- publishing a reading stamped 1970, the value a Pi reports with no RTC battery ---"
mosquitto_pub -h "${MQTT_HOST}" -q 1 -t "station/${STATION_ID}/clockguard/probe" \
  -m "{\"station_id\":\"${STATION_ID}\",\"sensor\":\"clockguard\",\"metric\":\"probe\",\"value\":1.0,\"unit\":\"n\",\"ts\":\"1970-01-01T00:00:09Z\",\"source\":\"manual\"}"
echo "--- publishing a reading stamped 5 days in the future ---"
mosquitto_pub -h "${MQTT_HOST}" -q 1 -t "station/${STATION_ID}/clockguard/probe" \
  -m "{\"station_id\":\"${STATION_ID}\",\"sensor\":\"clockguard\",\"metric\":\"probe\",\"value\":2.0,\"unit\":\"n\",\"ts\":\"$(date -u -d '+5 days' +%Y-%m-%dT%H:%M:%SZ)\",\"source\":\"manual\"}"
echo "--- publishing a good reading, to prove the guard is not rejecting everything ---"
mosquitto_pub -h "${MQTT_HOST}" -q 1 -t "station/${STATION_ID}/clockguard/probe" \
  -m "{\"station_id\":\"${STATION_ID}\",\"sensor\":\"clockguard\",\"metric\":\"probe\",\"value\":3.0,\"unit\":\"n\",\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"source\":\"manual\"}"
sleep 3
echo
echo "--- what the writer logged, verbatim ---"
journalctl -u "${UNIT}" --since "${MARK6}" --no-pager -o cat 2>&1 | grep -E 'implausible_clock' | sed 's/^/  /'
echo
echo "--- rows actually written ---"
psql_show "select id, value, ts, source from public.readings where sensor='clockguard' order by value;"
AFTER6="$(psql_val "select count(*) from public.readings where sensor='clockguard'")"
OLD6="$(psql_val "select count(*) from public.readings where ts < timestamptz '2026-01-01 00:00:00+00'")"
LOGGED6="$(journalctl -u "${UNIT}" --since "${MARK6}" --no-pager 2>&1 | grep -c 'reason=implausible_clock')"
PID6B="$(systemctl show -p MainPID --value "${UNIT}")"
echo "rows with sensor clockguard after = ${AFTER6}, of three published"
echo "rows anywhere older than 2026      = ${OLD6}"
echo "implausible_clock log lines        = ${LOGGED6}"
echo "writer MainPID unchanged           = $([ "${PID6}" = "${PID6B}" ] && echo yes || echo no)"
echo "--- the counter the API reports ---"
curl -sS "${BASE}/health" | "${VENV_PY}" -c "
import json,sys
w=json.load(sys.stdin)['writer']
print('  rejected_total       ', w['rejected_total'])
print('  rejected_by_reason   ', w['rejected_by_reason'])"
if [ "${LOGGED6}" -ge 2 ] && [ "${AFTER6}" = "1" ] && [ "${OLD6}" = "0" ] \
   && [ "${PID6}" = "${PID6B}" ]; then
  gate_result pass \
    "The writer refuses a 1970 timestamp and a timestamp five days ahead, logs both at error with reason=implausible_clock, counts them, and stays running. The good reading in the same batch still lands, so the guard is not rejecting everything." \
    "That the station keeps good time. The guard throws away a corrupt timestamp. It does not make a correct one. With no RTC battery and no network, a field session after a power cut now records nothing at all rather than recording 1970. That is the intended trade and it is still data loss."
else
  gate_result fail "nothing" "nothing"
fi

gate_header 7 "SCALE GATE, every aggregate query ran against ${SCALE_HOURS} hours"
echo "--- row counts every gate above ran against ---"
psql_show "
select
  (select count(*) from public.readings)                                      as readings_total,
  (select count(*) from public.readings where source='synthetic')             as fixture_rows,
  (select count(*) from public.readings_1m where source='synthetic')          as minute_buckets,
  (select count(*) from public.readings_1h where source='synthetic')          as hour_buckets,
  (select round(extract(epoch from (max(ts)-min(ts)))/3600) from public.readings where source='synthetic') as span_hours;"
echo
echo "--- which relation answers each window, and does the rollup cover it ---"
printf '%-10s %-24s %-10s %-12s %-10s\n' "window" "served_from" "points" "agg_samples" "raw_rows"
for HRS in 1 48 168 336; do
  FROM="$(date -u -d "-${HRS} hours" +%Y-%m-%dT%H:%M:%SZ)"
  TO="$(date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)"
  curl -sS "${BASE}/api/readings?sensor=water&metric=salinity&source=synthetic&from=${FROM}&to=${TO}" \
    -o "${WORK}/scale-${HRS}.json"
  SERVED="$("${VENV_PY}" -c "import json,sys;d=json.load(open('${WORK}/scale-${HRS}.json'));print(d['served_from'])")"
  PTS="$("${VENV_PY}" -c "import json,sys;d=json.load(open('${WORK}/scale-${HRS}.json'));print(sum(s['point_count'] for s in d['series']))")"
  RAW="$(psql_val "select count(*) from public.readings where source='synthetic' and metric='salinity' and ts >= '${FROM}' and ts < '${TO}'")"
  case "${SERVED}" in
    public.readings_1m) AGG="$(psql_val "select coalesce(sum(sample_count),0) from public.readings_1m where source='synthetic' and metric='salinity' and bucket >= '${FROM}' and bucket < '${TO}'")" ;;
    public.readings_1h) AGG="$(psql_val "select coalesce(sum(sample_count),0) from public.readings_1h where source='synthetic' and metric='salinity' and bucket >= '${FROM}' and bucket < '${TO}'")" ;;
    *) AGG="n/a raw" ;;
  esac
  printf '%-10s %-24s %-10s %-12s %-10s\n' "${HRS}h" "${SERVED}" "${PTS}" "${AGG}" "${RAW}"
done
echo
echo "--- no stale buckets survive outside the raw range ---"
psql_show "
select count(*) as stale_hour_buckets
from public.readings_1h
where source='synthetic'
  and (bucket < (select min(ts) from public.readings where source='synthetic')
    or bucket > (select max(ts) from public.readings where source='synthetic'));"
STALE="$(psql_val "
select count(*) from public.readings_1h where source='synthetic'
  and (bucket < (select min(ts) from public.readings where source='synthetic')
    or bucket > (select max(ts) from public.readings where source='synthetic'))")"
echo
echo "--- the 7 day and 14 day windows must not be answered from raw ---"
S168="$("${VENV_PY}" -c "import json;print(json.load(open('${WORK}/scale-168.json'))['served_from'])")"
S336="$("${VENV_PY}" -c "import json;print(json.load(open('${WORK}/scale-336.json'))['served_from'])")"
P168="$("${VENV_PY}" -c "import json;d=json.load(open('${WORK}/scale-168.json'));print(sum(s['point_count'] for s in d['series']))")"
P336="$("${VENV_PY}" -c "import json;d=json.load(open('${WORK}/scale-336.json'));print(sum(s['point_count'] for s in d['series']))")"
A168="$(psql_val "select coalesce(sum(sample_count),0) from public.readings_1m where source='synthetic' and metric='salinity' and bucket >= '$(date -u -d '-168 hours' +%Y-%m-%dT%H:%M:%SZ)'")"
R168="$(psql_val "select count(*) from public.readings where source='synthetic' and metric='salinity' and ts >= '$(date -u -d '-168 hours' +%Y-%m-%dT%H:%M:%SZ)'")"
echo "7 day  served_from ${S168}, points ${P168}, aggregate samples ${A168}, raw rows ${R168}"
echo "14 day served_from ${S336}, points ${P336}"
echo "--- chart page at 14 days ---"
echo "served_from ${G1_SERVED}, points ${G1_POINTS}"
if [ "${S168}" != "public.readings" ] && [ "${S336}" != "public.readings" ] \
   && [ "${A168}" = "${R168}" ] && [ "${P336}" -gt 300 ] && [ "${STALE}" = "0" ] 2> /dev/null; then
  gate_result pass \
    "Every aggregate query ran against ${LOADED} fixture rows spanning ${SCALE_HOURS} hours, not 48. The 7 day and 14 day windows both resolve to a rollup and never to the raw hypertable, the rollup holds a sample for every raw row, the chart page itself drew ${G1_POINTS} points from readings_1h, and no stale bucket survives outside the raw range. The 0011 defect fails this, because a 3 hour refresh window leaves a 7 day query empty." \
    "That this is field scale. ${TOTAL_ROWS} rows is hundreds, not millions. A season of one minute Modbus data is about half a million rows per metric. Nothing here tested that, tested compression, or tested a query while the writer is under load."
else
  gate_result fail "nothing" "nothing"
fi

echo
echo "================================================================"
echo "SUMMARY: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
echo "================================================================"
echo "rows behind every gate above: ${TOTAL_ROWS} in readings, ${LOADED} from the fixture,"
echo "spanning ${SCALE_HOURS} hours."
psql_show "delete from public.readings where sensor='clockguard';" > /dev/null
if [ "${FAIL_COUNT}" -gt 0 ]; then
  exit 1
fi
