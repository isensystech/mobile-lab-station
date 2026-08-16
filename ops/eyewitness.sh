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
STATION_ID="${MOBILELAB_STATION_ID:-lab01}"
MQTT_HOST="${MOBILELAB_MQTT_HOST:-127.0.0.1}"
MQTT_PORT="${MOBILELAB_MQTT_PORT:-1883}"

RULE="----------------------------------------------------------------------"

db() {
  PGPASSWORD="${MOBILELAB_DB_PASSWORD}" psql \
    -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" "$@"
}

db_val() {
  db -t -A -c "$1" 2>&1 | tr -d '[:space:]'
}

say() {
  echo
  echo "${RULE}"
  echo "$1"
  echo "${RULE}"
}

tell() {
  echo "  $1"
}

pause() {
  sleep "${1:-2}"
}

publish_one() {
  local sensor="$1"
  local metric="$2"
  local value="$3"
  local unit="$4"
  local stamp
  stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local payload
  payload="{\"station_id\":\"${STATION_ID}\",\"sensor\":\"${sensor}\",\"metric\":\"${metric}\",\"value\":${value},\"unit\":\"${unit}\",\"ts\":\"${stamp}\",\"lat\":27.99,\"lon\":-80.62,\"source\":\"manual\",\"quality_flag\":\"plausible\"}"
  tell "topic   station/${STATION_ID}/${sensor}/${metric}"
  tell "payload ${payload}"
  mosquitto_pub -h "${MQTT_HOST}" -p "${MQTT_PORT}" \
    -t "station/${STATION_ID}/${sensor}/${metric}" -m "${payload}"
  echo
}

clear
cat <<'BANNER'
======================================================================
              MOBILE LAB STATION - EYEWITNESS TEST
======================================================================

This test SHOWS you the data spine working. It does not just say
"pass". Watch the screen. You will see numbers go in and come out.

There are six steps.

  1. Look at the parts of the station.
  2. Send three live readings and watch them arrive.
  3. Make a set of test data with a known answer in it.
  4. Watch that test data arrive.
  5. Draw both series on the screen.
  6. Read what to look for.

BANNER
pause 3

say "STEP 1 of 6. Look at the parts of the station."
tell "Three parts must run. The message broker, the database, and the"
tell "writer. The writer moves a message into the database."
echo
for unit in mosquitto postgresql mobilelab-writer; do
  state="$(systemctl is-active "${unit}" 2> /dev/null)"
  printf '  %-22s %s\n' "${unit}" "${state}"
done
echo
tell "You want to see the word active three times."
echo
tell "The station holds this many rows now:"
TOTAL_START="$(db_val "select count(*) from public.readings")"
if [ -z "${TOTAL_START}" ]; then
  echo
  echo "STOP. The database did not answer. Check that postgresql runs."
  exit 1
fi
tell "readings = ${TOTAL_START}"
pause 3

say "STEP 2 of 6. Send three live readings and watch them arrive."
tell "A person with a hand instrument types a number. The form sends it"
tell "to the broker. The writer puts it in the database."
tell "These three readings use source 'manual'. That means a person made"
tell "them. They are real."
echo
BEFORE_MANUAL="$(db_val "select count(*) from public.readings where source='manual'")"
tell "manual rows before = ${BEFORE_MANUAL}"
echo
publish_one soil moisture 34.2 pct
publish_one air temperature 29.4 degC
publish_one water temperature 26.8 degC

tell "Waiting for the writer..."
for _ in $(seq 1 30); do
  AFTER_MANUAL="$(db_val "select count(*) from public.readings where source='manual'")"
  if [ "${AFTER_MANUAL}" -ge "$((BEFORE_MANUAL + 3))" ] 2> /dev/null; then
    break
  fi
  sleep 0.5
done
echo
tell "manual rows after = ${AFTER_MANUAL}"
echo
tell "Here are the three newest rows in the database:"
echo
db -c "
select id, sensor, metric, value, unit, source, ts
from public.readings
where source = 'manual'
order by id desc
limit 3;"
tell "Those numbers went through the broker. Nothing wrote them by hand."
pause 3

say "STEP 3 of 6. Make a set of test data with a known answer in it."
tell "No rain gauge exists yet. So the station makes a test set."
tell "It makes rainfall and salinity for 48 hours."
tell "Rain falls first. The salinity drops SIX HOURS LATER."
tell "That six hour delay is the answer hidden in the data."
echo
tell "This data is NOT real. It carries the source 'synthetic'."
tell "The database marks that source as not real. You cannot hide it."
echo
tell "Clearing any test data from an earlier run..."
db -q -c "delete from public.readings where source = 'synthetic';" > /dev/null 2>&1
echo
tell "Running the generator now."
echo
PYTHONPATH="${REPO_ROOT}/services" "${VENV_PY}" -m mobilelab.fixture --seed 1337 2>&1 | sed 's/^/  /'
pause 2

say "STEP 4 of 6. Watch that test data arrive."
tell "The generator sent 96 messages. 48 rainfall, 48 salinity."
tell "Waiting for the writer to store them..."
echo
for _ in $(seq 1 60); do
  SYN="$(db_val "select count(*) from public.readings where source='synthetic'")"
  printf '\r  synthetic rows in the database: %s ' "${SYN}"
  if [ "${SYN}" = "96" ]; then
    break
  fi
  sleep 0.5
done
echo
echo
tell "The first six hours of the test data:"
echo
db -c "
select
  to_char(ts, 'DD Mon HH24:MI') as when_utc,
  max(value) filter (where metric = 'rainfall') as rainfall_mm,
  max(value) filter (where metric = 'salinity') as salinity_psu
from public.readings
where source = 'synthetic'
group by ts
order by ts
limit 6;"
tell "Every one of those rows knows where it came from:"
echo
db -c "
select r.source, s.is_real, s.render_hint, count(*) as rows
from public.readings r
join public.sources s on s.source = r.source
where r.source = 'synthetic'
group by r.source, s.is_real, s.render_hint;"
tell "is_real is false. A chart must draw these dashed, never solid."
pause 3

say "STEP 5 of 6. Draw both series on the screen."
tell "Now look at the shape. The top chart is rain. The bottom chart is"
tell "salt. They share the same time axis, left to right, 48 hours."
echo
pause 2
PYTHONPATH="${REPO_ROOT}/services" "${VENV_PY}" -m mobilelab.plot --source synthetic 2>&1 | sed 's/^/  /'
pause 2

say "STEP 6 of 6. What to look for."
cat <<'LOOK'
  WHAT IS GOOD. Look for these four things.

  1. The SIMULATED banner sits at the top of the chart. The test data
     says what it is, on the screen, always.

  2. The rain chart has a tall peak. The salinity chart has a dip.
     The dip comes AFTER the peak, to the right of it.

  3. The line marked R-----S shows the gap. Count the hours. It is
     six to eight. The generator put a six hour delay in, and the
     database gave the delay back. The gap looks a little wider than
     six because the rain keeps falling after its peak. The chart
     says so under the plot.

  4. The words CORRELATION IS NOT CAUSATION print under the chart.
     They are permanent text. They are not a tooltip.

  WHAT IS A PROBLEM. Stop and report any of these.

  1. A service shows a word other than active in step 1.

  2. The manual row count does not go up by three in step 2. The
     writer is not moving messages. Look at the log:
       journalctl -u mobilelab-writer -n 50

  3. The synthetic row count stops below 96 in step 4. Some messages
     were dropped. Look at the same log for the word REJECTED.

  4. The SIMULATED banner is missing. Test data is pretending to be
     real. This is the worst failure on this list. Stop the demo.

  5. The salinity dip comes BEFORE the rain peak, or there is no dip.
     The lag is broken, and the correlation lesson does not work.

  6. Any chart draws the test data solid instead of dashed.

LOOK

say "The test is finished."
tell "To run it again, type:"
tell "  ${SCRIPT_DIR}/eyewitness.sh"
echo
tell "To see what the writer is doing right now, type:"
tell "  journalctl -u mobilelab-writer -f"
echo
