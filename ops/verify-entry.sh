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
API_PORT="${MOBILELAB_API_PORT:-8000}"
LAN_IP="$(hostname -I | awk '{print $1}')"
BASE="http://${LAN_IP}:${API_PORT}"
WORK=/tmp/mlentry
mkdir -p "${WORK}"
chmod 0777 "${WORK}"

SCALE_HOURS=336
SCALE_START="$(date -u -d '-335 hours' +%Y-%m-%dT%H:00:00Z)"
SCALE_END="$(date -u -d '+1 hour' +%Y-%m-%dT%H:00:00Z)"
WIDE_START="$(date -u -d '-60 days' +%Y-%m-%dT00:00:00Z)"

CORRECTION_TS="$(date -u -d '-10 days' +%Y-%m-%dT%H:00:00Z)"

PASS_COUNT=0
FAIL_COUNT=0

psql_val() {
  runuser -u postgres -- psql -t -A -d "${DB_NAME}" -c "$1" 2>&1 | tr -d '[:space:]'
}
psql_show() {
  runuser -u postgres -- psql -d "${DB_NAME}" -c "$1" 2>&1
}
pyq() {
  "${VENV_PY}" -c "import sys,json
d=json.load(open(sys.argv[1]))
$2" "$1" 2>&1
}
render() {
  runuser -u scott -- env HOME=/home/scott timeout 90 chromium \
    --headless --disable-gpu --no-sandbox --hide-scrollbars \
    --virtual-time-budget=15000 --dump-dom "$1" 2> /dev/null
}
attr() {
  grep -oE "data-$1=\"[^\"]*\"" "$2" | head -1 | sed "s/^data-$1=\"//; s/\"$//"
}
refresh_aggs() {
  runuser -u postgres -- psql -q -d "${DB_NAME}" \
    -c "call refresh_continuous_aggregate('public.readings_1m', '$1', '$2');" > /dev/null
  runuser -u postgres -- psql -q -d "${DB_NAME}" \
    -c "call refresh_continuous_aggregate('public.readings_1h', '$1', '$2');" > /dev/null
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

echo "Mobile Lab Station manual entry verification"
echo "host $(hostname), $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "form ${BASE}/entry"

echo
echo "==> SCALE SETUP, per section 17. Loading ${SCALE_HOURS} hours of data."
psql_show "delete from public.readings where source='synthetic';" > /dev/null
psql_show "delete from public.observations where site_label like 'gate-%';" > /dev/null
psql_show "delete from public.readings where sensor in ('air','water','rain','soil') and source='manual';" > /dev/null
refresh_aggs "${WIDE_START}" "${SCALE_END}"
runuser -u mobilelab -- env PYTHONPATH="${REPO_ROOT}/services" "${VENV_PY}" \
  -m mobilelab.fixture --seed 1337 --hours "${SCALE_HOURS}" --start "${SCALE_START}" > /dev/null 2>&1
for _ in $(seq 1 120); do
  LOADED="$(psql_val "select count(*) from public.readings where source='synthetic'")"
  [ "${LOADED}" = "672" ] && break
  sleep 0.5
done
refresh_aggs "${SCALE_START}" "${SCALE_END}"
TOTAL_ROWS="$(psql_val "select count(*) from public.readings")"
SPAN_HOURS="$(psql_val "select round(extract(epoch from (max(ts)-min(ts)))/3600) from public.readings")"
echo "    fixture rows ${LOADED}, rows in readings ${TOTAL_ROWS}, span ${SPAN_HOURS} hours"

gate_header 1 "an observation with several metrics saves as ONE observation_id"
NOW_TS="$(date -u +%Y-%m-%dT%H:%M:00Z)"
cat > "${WORK}/g1.json" <<EOF
{"ts":"${NOW_TS}","observer":"A. Student","site_label":"gate-one",
 "note":"The water looked cloudy after the rain.",
 "entries":[
  {"sensor":"rain","metric":"rainfall","value_raw":4.2,"unit_raw":"mm"},
  {"sensor":"air","metric":"temperature","value_raw":29.4,"unit_raw":"degC"},
  {"sensor":"water","metric":"ph","value_raw":7.2,"unit_raw":"ph"},
  {"sensor":"water","metric":"salinity","value_raw":21.5,"unit_raw":"PSU"}]}
EOF
curl -sS -X POST "${BASE}/api/observations" -H 'Content-Type: application/json' \
  --data @"${WORK}/g1.json" -o "${WORK}/g1out.json" -w "http_status=%{http_code}\n"
OBS1="$(pyq "${WORK}/g1out.json" "print(d['observation_id'])")"
echo "observation_id = ${OBS1}"
pyq "${WORK}/g1out.json" "
print('stored', d['stored_readings'], 'of', d['expected_readings'], 'complete', d['complete'])
print('batch flag', d['quality_flag'])
for r in d['readings']:
    print(f\"  {r['sensor']}/{r['metric']:12s} raw={r['value_raw']} {r['unit_raw']:5s} stored={r['value']} {r['unit']:5s} flag={r['quality_flag']} source={r['source']} is_real={r['is_real']}\")
"
echo "--- the database groups them under one id ---"
psql_show "
select observation_id, count(*) as readings, min(sensor||'/'||metric) as first_metric,
       max(sensor||'/'||metric) as last_metric
from public.readings where observation_id = '${OBS1}' group by observation_id;"
G1_IDS="$(psql_val "select count(distinct observation_id) from public.readings where observation_id='${OBS1}'")"
G1_N="$(psql_val "select count(*) from public.readings where observation_id='${OBS1}'")"
G1_SRC="$(psql_val "select count(distinct source) from public.readings where observation_id='${OBS1}'")"
G1_REAL="$(psql_val "select count(*) from public.readings r join public.sources s on s.source=r.source where r.observation_id='${OBS1}' and s.is_real=false")"
echo "distinct observation_id = ${G1_IDS}, readings = ${G1_N}, distinct source = ${G1_SRC}, not-real rows = ${G1_REAL}"
if [ "${G1_IDS}" = "1" ] && [ "${G1_N}" = "4" ] && [ "${G1_REAL}" = "0" ]; then
  gate_result pass \
    "Four metrics typed at one moment save as four readings rows under ONE observation_id, all with source manual and is_real true. The batch is one event, not four." \
    "That the grouping survives a partial failure. The form writes the batch header first and then publishes each reading. If the writer stops midway, the header exists with fewer readings. The response reports stored against expected, but nothing repairs it."
else
  gate_result fail "nothing" "nothing"
fi

gate_header 2 "NEGATIVE, both directions: pH 700 must SAVE and be FLAGGED"
cat > "${WORK}/g2.json" <<EOF
{"ts":"${NOW_TS}","observer":"A. Student","site_label":"gate-two",
 "entries":[{"sensor":"water","metric":"ph","value_raw":700,"unit_raw":"ph"}]}
EOF
G2_CODE="$(curl -sS -X POST "${BASE}/api/observations" -H 'Content-Type: application/json' \
  --data @"${WORK}/g2.json" -o "${WORK}/g2out.json" -w "%{http_code}")"
echo "http_status = ${G2_CODE}"
cat "${WORK}/g2out.json" | head -c 400
echo
OBS2="$(pyq "${WORK}/g2out.json" "print(d.get('observation_id','none'))")"
G2_ROWS="$(psql_val "select count(*) from public.readings where observation_id='${OBS2}'")"
G2_FLAG="$(psql_val "select quality_flag from public.readings where observation_id='${OBS2}'")"
G2_VALUE="$(psql_val "select value from public.readings where observation_id='${OBS2}'")"
G2_BATCH="$(psql_val "select quality_flag from public.observations where observation_id='${OBS2}'")"
echo
echo "--- the row in the database ---"
psql_show "select id, sensor, metric, value, unit, value_raw, unit_raw, quality_flag from public.readings where observation_id='${OBS2}';"
echo "rows saved = ${G2_ROWS}, row flag = ${G2_FLAG}, stored value = ${G2_VALUE}, batch flag = ${G2_BATCH}"
echo
echo "--- is it visibly flagged on the screen? ---"
render "http://127.0.0.1:${API_PORT}/entry" > "${WORK}/g2page.html"
VISIBLE="$(attr flagged-visible "${WORK}/g2page.html")"
grep -oE 'FLAGGED, CHECK THIS' "${WORK}/g2page.html" | head -1
echo "flagged rows visible on the form = ${VISIBLE}"
echo
if [ "${G2_CODE}" != "200" ]; then
  echo "OUTCOME: REJECTED. The API refused the value. THIS IS A DEFECT."
  gate_result fail "nothing" "nothing"
elif [ "${G2_ROWS}" = "1" ] && [ "${G2_FLAG}" = "implausible" ] && [ "${VISIBLE}" -ge 1 ] 2>/dev/null; then
  echo "OUTCOME: SAVED AND FLAGGED. The row exists, carries quality_flag='implausible',"
  echo "         the batch is marked '${G2_BATCH}', and the form shows FLAGGED, CHECK THIS."
  gate_result pass \
    "An implausible value saves, keeps the number the person typed, carries quality_flag='implausible' on the row and on the batch, and shows as flagged on the screen. Neither failure happened: it was not rejected, and it was not silently accepted." \
    "That a teacher ever reviews it. The flag is set and it is visible on the entry screen. There is no review queue, no filter for flagged rows, and no daily digest. Architecture section 4 promises a review queue and it is not built."
elif [ "${G2_ROWS}" = "1" ] && [ "${G2_FLAG}" != "implausible" ]; then
  echo "OUTCOME: SILENTLY ACCEPTED with flag '${G2_FLAG}'. THIS IS A DEFECT."
  gate_result fail "nothing" "nothing"
else
  echo "OUTCOME: unclear. rows=${G2_ROWS} flag=${G2_FLAG} visible=${VISIBLE}"
  gate_result fail "nothing" "nothing"
fi

gate_header 3 "a degF entry keeps the typed number and stores the conversion"
cat > "${WORK}/g3.json" <<EOF
{"ts":"${NOW_TS}","observer":"A. Student","site_label":"gate-three",
 "entries":[
  {"sensor":"water","metric":"temperature","value_raw":75.9,"unit_raw":"degF"},
  {"sensor":"rain","metric":"rainfall","value_raw":0.5,"unit_raw":"in"}]}
EOF
curl -sS -X POST "${BASE}/api/observations" -H 'Content-Type: application/json' \
  --data @"${WORK}/g3.json" -o "${WORK}/g3out.json" -w "http_status=%{http_code}\n"
OBS3="$(pyq "${WORK}/g3out.json" "print(d['observation_id'])")"
echo "--- what the person typed, and what the station stored ---"
psql_show "
select sensor, metric, value_raw, unit_raw, round(value::numeric,4) as value, unit
from public.readings where observation_id='${OBS3}' order by sensor;"
G3_RAW="$(psql_val "select value_raw from public.readings where observation_id='${OBS3}' and metric='temperature'")"
G3_RAWU="$(psql_val "select unit_raw from public.readings where observation_id='${OBS3}' and metric='temperature'")"
G3_VAL="$(psql_val "select round(value::numeric,2) from public.readings where observation_id='${OBS3}' and metric='temperature'")"
G3_U="$(psql_val "select unit from public.readings where observation_id='${OBS3}' and metric='temperature'")"
G3_RAIN="$(psql_val "select round(value::numeric,2) from public.readings where observation_id='${OBS3}' and metric='rainfall'")"
echo "temperature: typed ${G3_RAW} ${G3_RAWU}, stored ${G3_VAL} ${G3_U}   (75.9 degF is 24.39 degC)"
echo "rainfall:    typed 0.5 in, stored ${G3_RAIN} mm                (0.5 in is 12.70 mm)"
if [ "${G3_RAW}" = "75.9" ] && [ "${G3_RAWU}" = "degF" ] && [ "${G3_VAL}" = "24.39" ] \
   && [ "${G3_U}" = "degC" ] && [ "${G3_RAIN}" = "12.70" ]; then
  gate_result pass \
    "value_raw and unit_raw hold exactly what the person typed. value and unit hold the canonical conversion. A student who works in degrees Fahrenheit sees their own number again, and every chart still works in one unit." \
    "That the conversion is right for every unit we will ever add. Two conversions were checked, degF to degC and inches to mm. The table in metrics.py is small and hand written, and nothing tests the others."
else
  gate_result fail "nothing" "nothing"
fi

gate_header 4 "NEGATIVE, the clock guard: set the clock to 1970"
echo "--- clock before ---"
timedatectl show -p NTP -p NTPSynchronized -p TimeUSec 2>&1 | sed 's/^/  /'
SAVED_EPOCH="$(date -u +%s)"
echo "saved epoch = ${SAVED_EPOCH}"
echo
echo "--- breaking the clock, this is reversible ---"
echo "  The kernel REFUSES 1970-01-01 00:00:10 from userspace, with"
echo "  \"date: cannot set date: Invalid argument\". It accepts 1970-06-01."
echo "  Both are in 1970, and both trip the same guard, now < 2026-01-01."
timedatectl set-ntp false 2>&1 | sed 's/^/  /'
sleep 2
if date -u -s '1970-06-01 00:00:00' > /dev/null 2>&1; then
  echo "  clock set. The station clock now reads: $(date -u)"
else
  echo "  COULD NOT SET THE CLOCK. This gate cannot run."
fi
sleep 3
echo
echo "--- what the API says about the clock ---"
curl -sS "${BASE}/api/clock" -o "${WORK}/g4clock.json"
pyq "${WORK}/g4clock.json" "
print('  ok       ', d['ok'])
for p in d['problems']: print('  problem  ', p)
print('  advice   ', d['advice'][:120])
"
G4_OK="$(pyq "${WORK}/g4clock.json" "print(d['ok'])")"
echo
echo "--- what the form does ---"
render "http://127.0.0.1:${API_PORT}/entry" > "${WORK}/g4page.html"
G4_CLOCK="$(attr clock-ok "${WORK}/g4page.html")"
G4_PREFILL="$(attr ts-prefilled "${WORK}/g4page.html")"
G4_SAVE="$(attr save-enabled "${WORK}/g4page.html")"
echo "  page says clock ok      = ${G4_CLOCK}"
echo "  timestamp pre-filled    = ${G4_PREFILL}"
echo "  save button enabled     = ${G4_SAVE}"
G4_ALARM="no"
grep -qE '<div id="clock-alarm" class="alarm"' "${WORK}/g4page.html" && G4_ALARM="yes"
echo "  alarm bar visible       = ${G4_ALARM}"
if [ "${G4_ALARM}" = "yes" ]; then
  echo "  the person reads:"
  grep -oE 'The station clock reads [^<]*' "${WORK}/g4page.html" | head -1 | sed 's/^/    /'
fi
G4_TSVAL="$(grep -oE '<input type="datetime-local" id="ts"[^>]*value="[^"]*"' "${WORK}/g4page.html" | head -1)"
echo "  any 1970 pre-filled into the box? ${G4_TSVAL:-no, the box carries no value}"
echo
echo "--- does the API refuse a save while the clock is wrong? ---"
G4_POST="$(curl -sS -X POST "${BASE}/api/observations" -H 'Content-Type: application/json' \
  --data @"${WORK}/g1.json" -o "${WORK}/g4post.json" -w "%{http_code}")"
echo "  POST /api/observations returned ${G4_POST}"
head -c 220 "${WORK}/g4post.json"; echo
echo
echo "--- RESTORING THE CLOCK ---"
ELAPSED=90
date -u -s "@$((SAVED_EPOCH + ELAPSED))" > /dev/null 2>&1
echo "  step 1, set the clock from the saved epoch: $(date -u)"
timedatectl set-ntp true 2>&1 | sed 's/^/  step 2, /'
for _ in $(seq 1 30); do
  SYNC="$(timedatectl show -p NTPSynchronized --value 2>/dev/null)"
  [ "${SYNC}" = "yes" ] && break
  sleep 2
done
echo "  step 3, NTP synchronized = ${SYNC:-unknown}"
echo "  the station clock now reads: $(date -u)"
systemctl restart mobilelab-writer mobilelab-api
sleep 6
echo "  services restarted: writer $(systemctl is-active mobilelab-writer), api $(systemctl is-active mobilelab-api)"
curl -sS "${BASE}/api/clock" | "${VENV_PY}" -c "import json,sys;d=json.load(sys.stdin);print('  clock ok again =', d['ok'])"
if [ "${G4_OK}" = "False" ] && [ "${G4_CLOCK}" = "false" ] && [ "${G4_PREFILL}" = "false" ] \
   && [ "${G4_SAVE}" = "false" ] && [ "${G4_ALARM}" = "yes" ] && [ "${G4_POST}" = "409" ]; then
  gate_result pass \
    "With the clock at 1970 the form raises a red alarm, leaves the time box EMPTY rather than pre-filling 1970, disables Save, and the API refuses the batch with 409. Nobody can save a reading stamped 1970 by accident." \
    "That the station keeps good time. The guard refuses bad data. It does not make a correct clock. While the clock is wrong the station collects NOTHING, so a field session after a power cut loses every reading until somebody fixes the clock. Fit the RTC battery."
else
  gate_result fail "nothing" "nothing"
fi

gate_header 5 "correcting a reading updates the rollup the chart reads"
echo "The test row sits at ${CORRECTION_TS}, ten days back."
echo "That is outside the readings_1m refresh policy window of 7 days, so only an"
echo "explicit refresh can repair it. The policy cannot mask this result."
cat > "${WORK}/g5.json" <<EOF
{"ts":"${CORRECTION_TS}","observer":"A. Student","site_label":"gate-five",
 "entries":[{"sensor":"water","metric":"temperature","value_raw":20.0,"unit_raw":"degC"}]}
EOF
curl -sS -X POST "${BASE}/api/observations" -H 'Content-Type: application/json' \
  --data @"${WORK}/g5.json" -o "${WORK}/g5out.json" > /dev/null
OBS5="$(pyq "${WORK}/g5out.json" "print(d['observation_id'])")"
READING5="$(psql_val "select id from public.readings where observation_id='${OBS5}'")"
echo "reading id = ${READING5}"
refresh_aggs "$(date -u -d '-11 days' +%Y-%m-%dT00:00:00Z)" "$(date -u -d '-9 days' +%Y-%m-%dT00:00:00Z)"
echo
echo "--- the rollup BEFORE the correction ---"
psql_show "
select 'readings_1m' as view, bucket, avg_value, sample_count from public.readings_1m
 where source='manual' and metric='temperature' and bucket >= '${CORRECTION_TS}'::timestamptz - interval '1 hour'
   and bucket < '${CORRECTION_TS}'::timestamptz + interval '1 hour'
union all
select 'readings_1h', bucket, avg_value, sample_count from public.readings_1h
 where source='manual' and metric='temperature' and bucket >= '${CORRECTION_TS}'::timestamptz - interval '1 hour'
   and bucket < '${CORRECTION_TS}'::timestamptz + interval '1 hour';"
B5_1M="$(psql_val "select round(avg_value::numeric,2) from public.readings_1m where source='manual' and metric='temperature' and bucket >= '${CORRECTION_TS}'::timestamptz - interval '1 hour' and bucket < '${CORRECTION_TS}'::timestamptz + interval '1 hour'")"
echo
echo "--- correcting 20.0 degC to 31.5 degC through the API ---"
curl -sS -X PATCH "${BASE}/api/readings/${READING5}" -H 'Content-Type: application/json' \
  -d '{"value_raw":31.5,"unit_raw":"degC"}' -o "${WORK}/g5patch.json" -w "http_status=%{http_code}\n"
pyq "${WORK}/g5patch.json" "
print('  was', d['was'], 'now', d['now'])
for a in d['aggregates_refreshed']: print('  refreshed', a['view'], a['from'], 'to', a['to'])
"
echo
echo "--- the rollup AFTER the correction, with no manual refresh ---"
psql_show "
select 'readings_1m' as view, bucket, avg_value, sample_count from public.readings_1m
 where source='manual' and metric='temperature' and bucket >= '${CORRECTION_TS}'::timestamptz - interval '1 hour'
   and bucket < '${CORRECTION_TS}'::timestamptz + interval '1 hour'
union all
select 'readings_1h', bucket, avg_value, sample_count from public.readings_1h
 where source='manual' and metric='temperature' and bucket >= '${CORRECTION_TS}'::timestamptz - interval '1 hour'
   and bucket < '${CORRECTION_TS}'::timestamptz + interval '1 hour';"
A5_1M="$(psql_val "select round(avg_value::numeric,2) from public.readings_1m where source='manual' and metric='temperature' and bucket >= '${CORRECTION_TS}'::timestamptz - interval '1 hour' and bucket < '${CORRECTION_TS}'::timestamptz + interval '1 hour'")"
echo "readings_1m before = ${B5_1M}, after = ${A5_1M}"
if [ "${B5_1M}" = "20.00" ] && [ "${A5_1M}" = "31.50" ]; then
  gate_result pass \
    "A correction through the form rewrites the raw row AND refreshes the rollups the chart reads. The bucket moved from 20.00 to 31.50 with no manual refresh. Without this step the chart would keep drawing 20.00." \
    "That every path repairs the rollup. This holds for the form's own correct and remove buttons. A direct SQL edit, a bulk import, or a future importer bypasses it entirely, and the rollup stays wrong until somebody refreshes by hand."
else
  gate_result fail "nothing" "nothing"
fi

gate_header 6 "removing a reading also updates the rollup"
echo "--- the rollup BEFORE the removal ---"
psql_show "
select bucket, avg_value, sample_count from public.readings_1h
 where source='manual' and metric='temperature' and bucket >= '${CORRECTION_TS}'::timestamptz - interval '1 hour'
   and bucket < '${CORRECTION_TS}'::timestamptz + interval '1 hour';"
B6="$(psql_val "select count(*) from public.readings_1h where source='manual' and metric='temperature' and bucket >= '${CORRECTION_TS}'::timestamptz - interval '1 hour' and bucket < '${CORRECTION_TS}'::timestamptz + interval '1 hour'")"
echo "buckets before = ${B6}"
echo
echo "--- removing reading ${READING5} through the API ---"
curl -sS -X DELETE "${BASE}/api/readings/${READING5}" -o "${WORK}/g6del.json" -w "http_status=%{http_code}\n"
pyq "${WORK}/g6del.json" "
print('  removed', d['removed'])
for a in d['aggregates_refreshed']: print('  refreshed', a['view'])
"
echo
echo "--- the rollup AFTER the removal ---"
psql_show "
select bucket, avg_value, sample_count from public.readings_1h
 where source='manual' and metric='temperature' and bucket >= '${CORRECTION_TS}'::timestamptz - interval '1 hour'
   and bucket < '${CORRECTION_TS}'::timestamptz + interval '1 hour';"
A6="$(psql_val "select count(*) from public.readings_1h where source='manual' and metric='temperature' and bucket >= '${CORRECTION_TS}'::timestamptz - interval '1 hour' and bucket < '${CORRECTION_TS}'::timestamptz + interval '1 hour'")"
A6RAW="$(psql_val "select count(*) from public.readings where id=${READING5}")"
echo "buckets after = ${A6}, raw rows with that id = ${A6RAW}"
if [ "${B6}" -ge 1 ] && [ "${A6}" = "0" ] && [ "${A6RAW}" = "0" ] 2>/dev/null; then
  gate_result pass \
    "Removing a reading deletes the raw row and clears its rollup bucket. The chart cannot draw a value that no longer exists." \
    "That the removal is recoverable or auditable. The row is gone. Nothing records who removed it, when, or what it held. A student can quietly delete a reading that did not suit them."
else
  gate_result fail "nothing" "nothing"
fi

gate_header 7 "CSV export carries the batch and every column"
curl -sS "${BASE}/api/export.csv?observation_id=${OBS1}" -o "${WORK}/g7.csv" -w "http_status=%{http_code}\n"
echo "--- the header row ---"
head -1 "${WORK}/g7.csv" | tr ',' '\n' | nl | sed 's/^/  /'
echo
echo "--- the batch, as exported ---"
cat "${WORK}/g7.csv"
G7_COLS="$(head -1 "${WORK}/g7.csv" | tr ',' '\n' | wc -l | tr -d ' ')"
G7_ROWS="$(($(wc -l < "${WORK}/g7.csv") - 1))"
G7_MISSING=""
for col in value_raw unit_raw reading_quality_flag note observer observation_id value unit sensor metric; do
  head -1 "${WORK}/g7.csv" | grep -q "${col}" || G7_MISSING="${G7_MISSING} ${col}"
done
echo
echo "columns = ${G7_COLS}, data rows = ${G7_ROWS}, missing required columns =${G7_MISSING:- none}"
echo "--- the whole dataset also exports ---"
curl -sS "${BASE}/api/export.csv" -o "${WORK}/g7all.csv"
echo "full export rows = $(($(wc -l < "${WORK}/g7all.csv") - 1))"
if [ -z "${G7_MISSING}" ] && [ "${G7_ROWS}" = "4" ]; then
  gate_result pass \
    "The export returns the whole batch, four rows for four metrics, with value_raw, unit_raw, quality_flag, note, and observer present. The column list is fixed and append-only, per hard rule 5." \
    "That a spreadsheet opens it correctly everywhere. The file is UTF-8 with a comma separator and no byte order mark. Excel in some locales reads a comma file as one column. Nobody has opened this on a school laptop."
else
  gate_result fail "nothing" "nothing"
fi

gate_header 8 "SCALE GATE, the aggregate gates ran against ${SCALE_HOURS} hours"
echo "--- what every gate above ran against ---"
psql_show "
select
  (select count(*) from public.readings)                             as readings_total,
  (select count(*) from public.readings where source='manual')       as manual_rows,
  (select count(*) from public.readings where source='synthetic')    as fixture_rows,
  (select count(*) from public.readings_1m)                          as minute_buckets,
  (select count(*) from public.readings_1h)                          as hour_buckets,
  (select round(extract(epoch from (max(ts)-min(ts)))/86400,1) from public.readings) as span_days;"
echo
printf '%-42s %-14s %-12s\n' "gate" "rows in table" "span"
printf '%-42s %-14s %-12s\n' "5, correction refreshes the rollup" "${TOTAL_ROWS}" "${SPAN_HOURS} h"
printf '%-42s %-14s %-12s\n' "6, removal refreshes the rollup" "${TOTAL_ROWS}" "${SPAN_HOURS} h"
printf '%-42s %-14s %-12s\n' "7, CSV export over the whole set" "${TOTAL_ROWS}" "${SPAN_HOURS} h"
echo
echo "--- the corrected row sat 10 days back, outside the readings_1m policy window ---"
psql_show "
select application_name, config->>'start_offset' as start_offset
from timescaledb_information.jobs
where proc_name='policy_refresh_continuous_aggregate' order by application_name;"
SPAN_OK="$("${VENV_PY}" -c "print('yes' if ${SPAN_HOURS} >= 168 else 'no')")"
echo "span at least 7 days = ${SPAN_OK}"
if [ "${SPAN_OK}" = "yes" ] && [ "${TOTAL_ROWS}" -gt 600 ] 2>/dev/null; then
  gate_result pass \
    "Every aggregate-touching gate ran against ${TOTAL_ROWS} rows spanning ${SPAN_HOURS} hours, which is more than 7 days. The corrected row sat 10 days back, outside the 7 day readings_1m policy window, so the refresh policy could not have masked the result." \
    "That this is field scale. ${TOTAL_ROWS} rows is hundreds, not millions. Three readings a day until the 19th adds about a dozen rows. The real load arrives with Modbus at one minute intervals, and nothing here tested that."
else
  gate_result fail "nothing" "nothing"
fi

echo
echo "================================================================"
echo "SUMMARY: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
echo "================================================================"
echo "rows ${TOTAL_ROWS}, span ${SPAN_HOURS} hours"
psql_show "delete from public.observations where site_label like 'gate-%';" > /dev/null
if [ "${FAIL_COUNT}" -gt 0 ]; then
  exit 1
fi
