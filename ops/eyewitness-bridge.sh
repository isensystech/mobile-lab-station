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

DB_HOST="${MOBILELAB_DB_HOST:-127.0.0.1}"
DB_PORT="${MOBILELAB_DB_PORT:-5432}"
DB_USER="${MOBILELAB_DB_USER:-mobilelab}"
DB_NAME="${MOBILELAB_DB:-mobilelab}"
API_PORT="${MOBILELAB_API_PORT:-8000}"
BRIDGE_PORT="${MOBILELAB_BRIDGE_PORT:-8081}"
LAN_IP="$(hostname -I | awk '{print $1}')"
BRIDGE="http://${LAN_IP}:${BRIDGE_PORT}"
API="http://${LAN_IP}:${API_PORT}"
RULE="----------------------------------------------------------------------"
WORK="$(mktemp -d)"
DEVICE="AA:BB:CC:DD:EE:0E"
FILENAME="dive$(date +%H%M%S).csv"

db() {
  PGPASSWORD="${MOBILELAB_DB_PASSWORD}" psql -h "${DB_HOST}" -p "${DB_PORT}" \
    -U "${DB_USER}" -d "${DB_NAME}" "$@"
}
say() { echo; echo "${RULE}"; echo "$1"; echo "${RULE}"; }
tell() { echo "  $1"; }

clear
cat <<'BANNER'
======================================================================
      MOBILE LAB STATION - EYEWITNESS TEST, THE WQL LOGGER BRIDGE
======================================================================

A WQL logger records a dive to its SD card as a CSV file. When it comes
back to the surface it POSTs that file to this station over WiFi.

This test does that POST for you and shows the dive arrive.

IMPORTANT. No real logger has ever posted to this station. The dive in
this test is made by the station, in the same format the logger writes.
It proves the pipe works. It does not prove a real logger file parses.

BANNER
sleep 3

say "STEP 1 of 5. Look at the parts."
for unit in mosquitto postgresql mobilelab-writer mobilelab-api mobilelab-bridge; do
  printf '  %-22s %s\n' "${unit}" "$(systemctl is-active "${unit}" 2>/dev/null)"
done
echo
tell "You want the word active five times."
echo
tell "The bridge answers at ${BRIDGE}"
curl -sS --max-time 10 "${BRIDGE}/health" 2>/dev/null | "${VENV_PY}" -c "
import json,sys
d=json.load(sys.stdin)
print('  bridge status  ', d['status'])
print('  database       ', 'connected' if d['database']['connected'] else 'NOT CONNECTED')
print('  broker         ', 'connected' if d['broker']['connected'] else 'NOT CONNECTED')
print('  it expects     ', d['columns_expected'], 'columns in a dive file')
" 2>/dev/null
sleep 3

say "STEP 2 of 5. Make a dive file."
tell "A real logger writes this file to its SD card during the dive."
tell "The station is writing one now, in the same format."
echo
PYTHONPATH="${REPO_ROOT}/services" "${VENV_PY}" -m mobilelab.divefixture \
  --rows 600 --cast 14 --site "Creek bridge" > "${WORK}/${FILENAME}"
tell "file      ${FILENAME}"
tell "size      $(wc -c < "${WORK}/${FILENAME}") bytes"
tell "lines     $(wc -l < "${WORK}/${FILENAME}")"
tell "columns   $(grep '^ms,' "${WORK}/${FILENAME}" | head -1 | awk -F, '{print NF}')"
echo
tell "The first lines describe the dive. They start with a hash mark:"
grep '^#' "${WORK}/${FILENAME}" | head -6 | sed 's/^/    /'
echo
tell "Then one line names the columns, and every line after it is a sample:"
grep '^ms,' "${WORK}/${FILENAME}" | head -1 | cut -c1-92 | sed 's/^/    /'
sed -n "$(($(grep -c '^#' "${WORK}/${FILENAME}") + 2))p" "${WORK}/${FILENAME}" | cut -c1-92 | sed 's/^/    /'
sleep 3

say "STEP 3 of 5. Post the dive, the way the logger will."
BEFORE="$(db -t -A -c "select count(*) from public.readings where source='wql'" | tr -d '[:space:]')"
tell "dive readings in the database before = ${BEFORE}"
echo
tell "POST ${BRIDGE}/storage/v1/object/dives/${DEVICE}/${FILENAME}"
tell "That address copies the cloud address on purpose. The logger needs a"
tell "new host name and nothing else."
echo
curl -sS -X POST "${BRIDGE}/storage/v1/object/dives/${DEVICE}/${FILENAME}" \
  -H 'Content-Type: text/csv' --data-binary @"${WORK}/${FILENAME}" \
  -o "${WORK}/reply.json" -w "  the bridge answered HTTP %{http_code}\n"
echo
"${VENV_PY}" -c "
import json
d=json.load(open('${WORK}/reply.json'))
print('  samples in the file      ', d['rows_total'])
print('  samples the station kept ', d['rows_accepted'])
print('  samples it refused       ', d['rows_rejected'], d['reject_reasons'] or '')
print('  readings written         ', d['readings_stored'])
print('  all of them landed       ', d['readings_complete'])
print('  site                     ', d['site'])
"
DIVE_ID="$("${VENV_PY}" -c "import json;print(json.load(open('${WORK}/reply.json'))['dive_id'])")"
sleep 2

say "STEP 4 of 5. Watch the rows land."
tell "The bridge did NOT write these rows. It published every sample to the"
tell "message broker, and the writer stored them, exactly like every other"
tell "driver. One way in, one set of rules."
echo
db -c "
select metric, unit, count(*) as readings,
       round(min(value)::numeric,2) as lowest,
       round(max(value)::numeric,2) as highest
from public.readings where dive_id='${DIVE_ID}'
group by metric, unit order by metric;"
tell "Each row knows it is real measured data:"
echo
db -c "
select r.source, s.is_real, s.render_hint, count(*) as readings
from public.readings r join public.sources s on s.source=r.source
where r.dive_id='${DIVE_ID}' group by r.source, s.is_real, s.render_hint;"
sleep 3

say "STEP 5 of 5. See it on the chart, beside the rain."
FROM="$(date -u -d '-4 hours' +%Y-%m-%dT%H:%M:%SZ)"
TO="$(date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)"
tell "The chart already knew how to do this. Nothing new was needed."
echo
PYTHONPATH="${REPO_ROOT}/services" "${VENV_PY}" -c "
import json, urllib.request, urllib.parse
q = urllib.parse.urlencode({
 'a_sensor':'rain','a_metric':'rainfall','a_source':'synthetic',
 'b_sensor':'water','b_metric':'temperature','b_source':'wql',
 'from':'${FROM}','to':'${TO}'})
with urllib.request.urlopen('${API}/api/series/pair?' + q, timeout=20) as r:
    d = json.load(r)
print('  answered from   ', d['served_from'])
print('  shared time axis', len(d['axis']), 'slots')
for s in d['series']:
    real = 'REAL, draws solid' if s['is_real'] else 'NOT REAL, draws dashed'
    print(f\"  {s['sensor']}/{s['metric']:12s} from {s['source']:10s} {real}\")
"
echo
tell "Open this address in a browser on the Pi to see it drawn:"
echo
tell "  ${API}/?hours=4&a_sensor=rain&a_metric=rainfall&a_source=synthetic&b_sensor=water&b_metric=temperature&b_source=wql"
echo

say "What a correct result looks like."
cat <<'GOOD'
  1. Step 1 shows active five times.

  2. Step 3 answers HTTP 201, and "samples the station kept" equals
     "samples in the file". Refused is 0.

  3. "all of them landed" says True. The bridge counted the rows back
     out of the database, so it is not guessing.

  4. Step 4 lists seven measurements: cyclops, depth, ec, orp, ph,
     salinity, temperature. Each has the same number of readings.

  5. Step 4 shows is_real true and render_hint solid. A dive is a
     measurement, so it must draw solid, never dashed.

  6. On the chart, the dive line is SOLID and the rain line is
     DASHED, and the SIMULATED banner is up because the rain is test
     data.
GOOD

say "Six things that mean STOP."
cat <<'STOP'
  1. The bridge answers 400 with a message about columns. The logger
     firmware changed its file format. Do NOT edit the station to
     make it fit. Read the message, check the firmware, and decide.
     This refusal is the guard working.

  2. "samples it refused" is not 0. Look at the reason. A count under
     implausible_clock means the logger's clock was wrong during the
     dive, and those samples are gone on purpose.

  3. "all of them landed" says False. The writer is not keeping up or
     has stopped. Check:
       journalctl -u mobilelab-writer -n 50

  4. Step 4 shows fewer than seven measurements. A sensor was off
     during the dive, or a column is empty in the file.

  5. Step 4 shows is_real false, or the chart draws the dive DASHED.
     Real dive data is pretending to be simulated. Report it.

  6. Posting the same dive twice adds rows a second time. It must
     answer 409 and add nothing. A logger that retries after a
     dropped connection would otherwise double every dive.
STOP

say "Notes."
tell "This test used a made-up dive file. No real logger has posted here."
tell "The first real upload is still an untested step."
echo
tell "To run the automatic checks, type:"
tell "  sudo ${SCRIPT_DIR}/verify-bridge.sh"
echo
rm -rf "${WORK}"
