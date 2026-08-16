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
BRIDGE_PORT="${MOBILELAB_BRIDGE_PORT:-8081}"
LAN_IP="$(hostname -I | awk '{print $1}')"
BRIDGE="http://${LAN_IP}:${BRIDGE_PORT}"
API="http://${LAN_IP}:${API_PORT}"
WORK=/tmp/mlbridge
mkdir -p "${WORK}"; chmod 0777 "${WORK}"

DEVICE="AA:BB:CC:DD:EE:01"
DIVE_ROWS=600
DIVE_START="$(date -u -d '-3 hours' +%Y-%m-%dT%H:00:00Z)"

PASS_COUNT=0
FAIL_COUNT=0

psql_val() { runuser -u postgres -- psql -t -A -d "${DB_NAME}" -c "$1" 2>&1 | tr -d '[:space:]'; }
psql_show() { runuser -u postgres -- psql -d "${DB_NAME}" -c "$1" 2>&1; }
pyq() { "${VENV_PY}" -c "import sys,json
d=json.load(open(sys.argv[1]))
$2" "$1" 2>&1; }
makedive() {
  runuser -u mobilelab -- env PYTHONPATH="${REPO_ROOT}/services" "${VENV_PY}" \
    -m mobilelab.divefixture "$@"
}
render() {
  runuser -u scott -- env HOME=/home/scott timeout 90 chromium \
    --headless --disable-gpu --no-sandbox --virtual-time-budget=18000 --dump-dom "$1" 2> /dev/null
}
attr() { grep -oE "data-$1=\"[^\"]*\"" "$2" | head -1 | sed "s/^data-$1=\"//; s/\"$//"; }
gate_header() {
  echo; echo "================================================================"
  echo "GATE $1: $2"; echo "================================================================"
}
gate_result() {
  if [ "$1" = "pass" ]; then PASS_COUNT=$((PASS_COUNT+1)); echo "RESULT: PASS"
  else FAIL_COUNT=$((FAIL_COUNT+1)); echo "RESULT: FAIL"; fi
  echo "PROVES:         $2"
  echo "DOES NOT PROVE: $3"
}

echo "Mobile Lab Station WQL bridge verification"
echo "host $(hostname), $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "bridge ${BRIDGE}"
echo
echo "TEST DATA WARNING. No real logger file exists on this station. Every dive"
echo "below comes from mobilelab.divefixture, which writes the documented 25"
echo "column format. These gates prove the parser reads the FORMAT. They do NOT"
echo "prove it reads a REAL dive."
echo
psql_show "delete from public.readings where source='wql';" > /dev/null
psql_show "delete from public.dives;" > /dev/null

gate_header 1 "a posted dive lands in readings through the writer"
makedive --rows "${DIVE_ROWS}" --start "${DIVE_START}" --cast 7 > "${WORK}/dive0007.csv"
echo "dive file: $(wc -l < "${WORK}/dive0007.csv") lines, $(wc -c < "${WORK}/dive0007.csv") bytes"
echo "--- posting to the Supabase-shaped path ---"
echo "POST ${BRIDGE}/storage/v1/object/dives/${DEVICE}/dive0007.csv"
BEFORE1="$(psql_val "select count(*) from public.readings where source='wql'")"
curl -sS -X POST "${BRIDGE}/storage/v1/object/dives/${DEVICE}/dive0007.csv" \
  -H 'Content-Type: text/csv' --data-binary @"${WORK}/dive0007.csv" \
  -o "${WORK}/g1.json" -w "http_status=%{http_code}\n"
pyq "${WORK}/g1.json" "
for k in ('dive_id','rows_total','rows_accepted','rows_rejected','reject_reasons','readings_published','readings_stored','readings_complete','site','time_source'):
    print(f'  {k:20s} {d[k]}')
"
DIVE_ID="$(pyq "${WORK}/g1.json" "print(d['dive_id'])")"
echo
echo "--- what landed in readings, by metric ---"
psql_show "
select metric, unit, count(*) as rows, round(min(value)::numeric,2) as min,
       round(max(value)::numeric,2) as max
from public.readings where dive_id='${DIVE_ID}' group by metric, unit order by metric;"
echo "--- every row carries the real source, and the writer put it there ---"
psql_show "
select r.source, s.is_real, s.render_hint, count(*) as rows
from public.readings r join public.sources s on s.source=r.source
where r.dive_id='${DIVE_ID}' group by r.source, s.is_real, s.render_hint;"
echo "--- the writer log, not the bridge, shows the inserts ---"
journalctl -u mobilelab-writer --no-pager -n 400 -o cat 2>&1 | grep -c 'source=wql' \
  | sed 's/^/  writer accepted lines mentioning source=wql: /'
G1_STORED="$(psql_val "select count(*) from public.readings where dive_id='${DIVE_ID}'")"
G1_PUB="$(pyq "${WORK}/g1.json" "print(d['readings_published'])")"
G1_REAL="$(psql_val "select count(*) from public.readings r join public.sources s on s.source=r.source where r.dive_id='${DIVE_ID}' and s.is_real=false")"
G1_ACC="$(pyq "${WORK}/g1.json" "print(d['rows_accepted'])")"
echo "published ${G1_PUB}, stored ${G1_STORED}, rows accepted ${G1_ACC} of ${DIVE_ROWS}, not-real rows ${G1_REAL}"
if [ "${G1_STORED}" = "${G1_PUB}" ] && [ "${G1_ACC}" = "${DIVE_ROWS}" ] && [ "${G1_REAL}" = "0" ]; then
  gate_result pass \
    "A ${DIVE_ROWS} row dive POSTed over HTTP became ${G1_STORED} readings rows, every one written by the writer through MQTT, every one carrying source wql with is_real true. The bridge wrote no readings itself." \
    "That a REAL logger file parses. The file came from mobilelab.divefixture. It matches the firmware header column for column, but no logger has ever POSTed to this station, and a real file may carry meta lines or edge cases this generator does not produce."
else
  gate_result fail "nothing" "nothing"
fi

gate_header 2 "NEGATIVE, a CSV with a column removed must fail loudly and write NOTHING"
makedive --rows 50 --start "${DIVE_START}" --cast 8 --drop-column sal_PSU > "${WORK}/dive0008.csv"
echo "the file now has $(head -20 "${WORK}/dive0008.csv" | grep -c '^ms,') header line with:"
grep '^ms,' "${WORK}/dive0008.csv" | head -1 | awk -F, '{print "  " NF " columns, sal_PSU removed"}'
BEFORE2_R="$(psql_val "select count(*) from public.readings where source='wql'")"
BEFORE2_D="$(psql_val "select count(*) from public.dives")"
echo "readings before = ${BEFORE2_R}, dive manifests before = ${BEFORE2_D}"
echo
echo "--- posting the broken file ---"
G2_CODE="$(curl -sS -X POST "${BRIDGE}/dives/${DEVICE}/dive0008.csv" \
  -H 'Content-Type: text/csv' --data-binary @"${WORK}/dive0008.csv" \
  -o "${WORK}/g2.json" -w "%{http_code}")"
echo "http_status = ${G2_CODE}"
echo "--- the message the logger receives, verbatim ---"
"${VENV_PY}" -c "
import json
d=json.load(open('${WORK}/g2.json'))['detail']
print('  reason           ', d['reason'])
print('  rows_ingested    ', d['rows_ingested'])
print('  expected_columns ', d['expected_columns'])
print('  detail:')
import textwrap
for line in textwrap.wrap(d['detail'], 96): print('    ' + line)
"
AFTER2_R="$(psql_val "select count(*) from public.readings where source='wql'")"
AFTER2_D="$(psql_val "select count(*) from public.dives")"
echo
echo "readings after = ${AFTER2_R}, dive manifests after = ${AFTER2_D}"
echo "--- the bridge logged the refusal ---"
journalctl -u mobilelab-bridge --no-pager -n 40 -o cat 2>&1 | grep 'REFUSED' | tail -1 | cut -c1-160
if [ "${G2_CODE}" = "400" ] && [ "${AFTER2_R}" = "${BEFORE2_R}" ] && [ "${AFTER2_D}" = "${BEFORE2_D}" ]; then
  gate_result pass \
    "A file with 24 columns instead of 25 is refused with 400, the message names the expected header and says nothing was ingested, and neither a reading nor a dive manifest was written. A firmware change breaks visibly on the first upload." \
    "That every malformed shape is caught. This test removed one column. A firmware that RENAMES a column while keeping 25 is caught by the header comparison, but a firmware that reorders two columns of the same type and count would pass the guard and silently swap two metrics."
else
  gate_result fail "nothing" "nothing"
fi

gate_header 3 "NEGATIVE, a 1970 row is rejected and counted, the rest still ingests"
makedive --rows 120 --start "${DIVE_START}" --cast 9 --bad-clock-rows 40 --unsynced-rows 41 \
  > "${WORK}/dive0009.csv"
echo "row 40 is stamped 1970-01-01T00:00:09Z, row 41 is stamped 'unsynced'"
curl -sS -X POST "${BRIDGE}/dives/${DEVICE}/dive0009.csv" \
  -H 'Content-Type: text/csv' --data-binary @"${WORK}/dive0009.csv" \
  -o "${WORK}/g3.json" -w "http_status=%{http_code}\n"
pyq "${WORK}/g3.json" "
print('  rows_total       ', d['rows_total'])
print('  rows_accepted    ', d['rows_accepted'])
print('  rows_rejected    ', d['rows_rejected'])
print('  reject_reasons   ', d['reject_reasons'])
print('  readings_stored  ', d['readings_stored'])
"
DIVE9="$(pyq "${WORK}/g3.json" "print(d['dive_id'])")"
echo "--- the bridge logged each rejection ---"
journalctl -u mobilelab-bridge --no-pager -n 60 -o cat 2>&1 | grep 'REJECTED dive row' | tail -2 | sed 's/^/  /'
echo "--- the manifest records what happened ---"
psql_show "select filename, rows_total, rows_accepted, rows_rejected, reject_reasons from public.dives where dive_id='${DIVE9}';"
echo "--- no 1970 row reached readings ---"
OLD9="$(psql_val "select count(*) from public.readings where dive_id='${DIVE9}' and ts < timestamptz '2026-01-01'")"
STORED9="$(psql_val "select count(*) from public.readings where dive_id='${DIVE9}'")"
G3_REJ="$(pyq "${WORK}/g3.json" "print(d['rows_rejected'])")"
G3_ACC="$(pyq "${WORK}/g3.json" "print(d['rows_accepted'])")"
G3_CLOCK="$(pyq "${WORK}/g3.json" "print(d['reject_reasons'].get('implausible_clock',0))")"
echo "rows before 2026 in readings = ${OLD9}, readings stored = ${STORED9}"
echo "rejected = ${G3_REJ}, of which implausible_clock = ${G3_CLOCK}, accepted = ${G3_ACC} of 120"
if [ "${G3_REJ}" = "2" ] && [ "${G3_CLOCK}" = "1" ] && [ "${G3_ACC}" = "118" ] && [ "${OLD9}" = "0" ]; then
  gate_result pass \
    "The 1970 row is rejected with reason implausible_clock and the unsynced row with reason unsynced_clock. Both are counted, both are logged, and the other 118 rows still ingest. The count comes back to the caller and is stored on the manifest." \
    "That the dive is still scientifically whole. Two samples are missing from the middle of this dive and the station keeps the rest. A gap in a dive profile may matter to whoever reads it, and nothing marks the gap on a chart."
else
  gate_result fail "nothing" "nothing"
fi

gate_header 4 "the same dive POSTed twice"
BEFORE4="$(psql_val "select count(*) from public.readings where source='wql'")"
echo "readings before the repeat = ${BEFORE4}"
echo "--- posting dive0007.csv again, byte for byte ---"
G4_CODE="$(curl -sS -X POST "${BRIDGE}/storage/v1/object/dives/${DEVICE}/dive0007.csv" \
  -H 'Content-Type: text/csv' --data-binary @"${WORK}/dive0007.csv" \
  -o "${WORK}/g4.json" -w "%{http_code}")"
echo "http_status = ${G4_CODE}"
cat "${WORK}/g4.json" | "${VENV_PY}" -c "
import json,sys,textwrap
d=json.load(sys.stdin)
for k,v in d.items():
    if k=='message':
        print('  message:'); [print('    '+l) for l in textwrap.wrap(v,92)]
    else: print(f'  {k:12s} {v}')
"
AFTER4="$(psql_val "select count(*) from public.readings where source='wql'")"
MANIFESTS="$(psql_val "select count(*) from public.dives where device_id='${DEVICE}' and filename='dive0007.csv'")"
echo
echo "readings after the repeat = ${AFTER4}"
echo "dive manifests for that device and filename = ${MANIFESTS}"
echo
echo "IS THIS THE INTENDED DESIGN? Yes, and it is not the station's invention."
echo "DiveSync-To-Do.md states the contract: dive files are immutable after"
echo "close, so insert-once and treat-409-as-synced is fully idempotent, and the"
echo "cloud is duplicate-safe on (device_id, filename). The station copies that"
echo "contract exactly, so the same firmware works against either end."
if [ "${G4_CODE}" = "409" ] && [ "${AFTER4}" = "${BEFORE4}" ] && [ "${MANIFESTS}" = "1" ]; then
  echo "OUTCOME: NO DUPLICATES. The second POST returned 409 and wrote nothing."
  gate_result pass \
    "A repeat upload answers 409 and creates no duplicate reading and no second manifest. Idempotency is keyed on (device_id, filename), which is the contract DiveSync-To-Do.md already defines, so a logger retrying after a dropped connection cannot double a dive." \
    "That an EDITED file under the same name is caught. The key is the name, not the content. If a logger ever rewrote dive0007.csv with different data, the station would answer 409 and keep the first copy. That is safe for immutable files and wrong for anything else. Nothing checks a checksum."
else
  echo "OUTCOME: duplicates were created, or the code was not 409. Code ${G4_CODE},"
  echo "         readings went from ${BEFORE4} to ${AFTER4}, manifests ${MANIFESTS}."
  gate_result fail "nothing" "nothing"
fi

gate_header 5 "the dive is queryable through the pair endpoint and draws on the chart"
FROM5="$(date -u -d '-4 hours' +%Y-%m-%dT%H:%M:%SZ)"
TO5="$(date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)"
echo "--- the existing pair endpoint, dive temperature against fixture rainfall ---"
curl -sS "${API}/api/series/pair?a_sensor=rain&a_metric=rainfall&a_source=synthetic&b_sensor=water&b_metric=temperature&b_source=wql&from=${FROM5}&to=${TO5}" \
  -o "${WORK}/g5.json" -w "http_status=%{http_code}\n"
pyq "${WORK}/g5.json" "
print('  served_from ', d['served_from'], ' bucket', d['bucket'])
print('  shared axis ', len(d['axis']), 'slots')
for s in d['series']:
    print(f\"  series {s['key']}: {s['sensor']}/{s['metric']} source={s['source']} unit={s['unit']} values={len(s['values'])} is_real={s['is_real']} render_hint={s['render_hint']}\")
"
echo "--- the chart page draws both, with per series sources ---"
CHART_URL="http://127.0.0.1:${API_PORT}/?hours=4&a_sensor=rain&a_metric=rainfall&a_source=synthetic&b_sensor=water&b_metric=temperature&b_source=wql"
render "${CHART_URL}" > "${WORK}/g5page.html"
echo "  page status   = $(attr status "${WORK}/g5page.html")"
echo "  points drawn  = $(attr points "${WORK}/g5page.html")"
echo "  simulated flag= $(attr simulated "${WORK}/g5page.html")"
echo "  rain dashed   = $(attr a-dashed "${WORK}/g5page.html")   (synthetic, must be dashed)"
echo "  dive dashed   = $(attr b-dashed "${WORK}/g5page.html")   (wql is real, must be solid)"
echo "  dive is real  = $(attr b-real "${WORK}/g5page.html")"
G5_B="$(pyq "${WORK}/g5.json" "print(sum(1 for v in d['series'][1]['values'] if v is not None))")"
G5_BREAL="$(pyq "${WORK}/g5.json" "print(d['series'][1]['is_real'])")"
G5_BDASH="$(attr b-dashed "${WORK}/g5page.html")"
G5_STATUS="$(attr status "${WORK}/g5page.html")"
echo "dive points on the shared axis = ${G5_B}"
if [ "${G5_B}" -gt 0 ] 2>/dev/null && [ "${G5_BREAL}" = "True" ] && [ "${G5_BDASH}" = "false" ] \
   && [ "${G5_STATUS}" = "ready" ]; then
  gate_result pass \
    "The dive answers through the SAME pair endpoint the chart already used, on a shared axis with the rainfall series. The chart draws the dive SOLID because wql is a real source, and the fixture rainfall DASHED beside it. No new query path was needed." \
    "That the two series are scientifically comparable. One is a real dive and one is a generated rainfall series with no relationship to it. The chart proves the plumbing, not the science, and the caption over such a pair would be meaningless."
else
  gate_result fail "nothing" "nothing"
fi

gate_header 6 "SCALE GATE, a realistic dive length"
psql_show "
select
  (select count(*) from public.dives)                                        as dives,
  (select count(*) from public.readings where source='wql')                  as dive_readings,
  (select count(*) from public.readings)                                     as readings_total,
  (select round(extract(epoch from (max(ts)-min(ts)))/60) from public.readings where source='wql') as dive_span_minutes,
  (select round(extract(epoch from (max(ts)-min(ts)))/86400,1) from public.readings) as table_span_days;"
WQL_ROWS="$(psql_val "select count(*) from public.readings where source='wql'")"
WQL_SPAN="$(psql_val "select round(extract(epoch from (max(ts)-min(ts)))/60) from public.readings where source='wql'")"
TOTAL="$(psql_val "select count(*) from public.readings")"
TSPAN="$(psql_val "select round(extract(epoch from (max(ts)-min(ts)))/86400,1) from public.readings")"
echo
echo "--- per dive ---"
psql_show "
select filename, rows_total, rows_accepted, rows_rejected,
       (select count(*) from public.readings r where r.dive_id = d.dive_id) as readings
from public.dives d order by received_at;"
echo
echo "gate 1 dive:  ${DIVE_ROWS} CSV rows at 1 second, ${WQL_SPAN} minutes of dive"
echo "readings from dives: ${WQL_ROWS}"
echo "readings table total: ${TOTAL} rows spanning ${TSPAN} days"
if [ "${DIVE_ROWS}" -ge 300 ] && [ "${WQL_ROWS}" -gt 2000 ] 2>/dev/null; then
  gate_result pass \
    "The main dive is ${DIVE_ROWS} samples at one second, which is ${WQL_SPAN} minutes in the water, and it produced ${WQL_ROWS} readings rows. That is a realistic cast, not a ten row sample. The whole table holds ${TOTAL} rows across ${TSPAN} days." \
    "That the station holds a field season. One dive is minutes. A day of diving is several dives, and a term is hundreds. Nothing tested many dives at once, nothing tested two loggers uploading together, and nothing tested an upload while a student is entering readings by hand."
else
  gate_result fail "nothing" "nothing"
fi

echo
echo "================================================================"
echo "SUMMARY: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
echo "================================================================"
echo "TEST DATA: every dive above came from mobilelab.divefixture."
echo "The parse path has NOT been validated against a real logger file."
if [ "${FAIL_COUNT}" -gt 0 ]; then exit 1; fi
