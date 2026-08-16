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
MQTT_PORT="${MOBILELAB_MQTT_PORT:-1883}"
UNIT="mobilelab-writer.service"

PASS_COUNT=0
FAIL_COUNT=0

psql_val() {
  runuser -u postgres -- psql -t -A -d "${DB_NAME}" -c "$1" 2>&1 | tr -d '\r' | tr -d '[:space:]'
}

psql_show() {
  runuser -u postgres -- psql -d "${DB_NAME}" -c "$1" 2>&1
}

fixture_run() {
  runuser -u "${SERVICE_USER:-mobilelab}" -- \
    env PYTHONPATH="${REPO_ROOT}/services" "${VENV_PY}" -m mobilelab.fixture "$@"
}

gate_header() {
  echo
  echo "================================================================"
  echo "GATE $1: $2"
  echo "================================================================"
}

gate_result() {
  if [ "$1" = "pass" ]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "RESULT: PASS"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "RESULT: FAIL"
  fi
  echo "PROVES:         $2"
  echo "DOES NOT PROVE: $3"
}

wait_for_count() {
  local sql="$1"
  local want="$2"
  local tries="${3:-40}"
  local seen=0
  for _ in $(seq 1 "${tries}"); do
    seen="$(psql_val "${sql}")"
    if [ "${seen}" = "${want}" ]; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

echo "Mobile Lab Station writer and fixture verification"
echo "host $(hostname), $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "unit ${UNIT}"

echo
echo "==> clearing rows from an earlier run"
psql_show "delete from public.readings where sensor in ('gatew','rain','water');" > /dev/null

gate_header 1 "a published reading lands in readings"
MARK1="$(date '+%Y-%m-%d %H:%M:%S')"
BEFORE1="$(psql_val "select count(*) from public.readings where sensor='gatew'")"
echo "rows before = ${BEFORE1}"
PAYLOAD1="{\"station_id\":\"${STATION_ID}\",\"sensor\":\"gatew\",\"metric\":\"moisture\",\"value\":41.7,\"unit\":\"pct\",\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"lat\":27.99,\"lon\":-80.62,\"source\":\"manual\"}"
echo "--- publishing to station/${STATION_ID}/gatew/moisture ---"
echo "${PAYLOAD1}"
mosquitto_pub -h "${MQTT_HOST}" -p "${MQTT_PORT}" -t "station/${STATION_ID}/gatew/moisture" -m "${PAYLOAD1}"
wait_for_count "select count(*) from public.readings where sensor='gatew'" "1" 40
echo "--- the row in the database ---"
psql_show "select id, station_id, sensor, metric, value, unit, source, ts from public.readings where sensor='gatew';"
echo "--- what the writer logged ---"
journalctl -u "${UNIT}" --since "${MARK1}" --no-pager 2>&1 | grep -E 'accepted' | tail -3
AFTER1="$(psql_val "select count(*) from public.readings where sensor='gatew'")"
echo "rows after = ${AFTER1}"

if [ "${AFTER1}" = "1" ]; then
  gate_result pass \
    "The writer subscribes, validates, and inserts. The broker to database path works end to end." \
    "That the writer keeps up under load. One message is not a rate test. Nothing measured throughput or queue depth."
else
  gate_result fail "nothing" "nothing"
fi

gate_header 2 "NEGATIVE TEST, malformed JSON is logged and the writer survives"
MARK2="$(date '+%Y-%m-%d %H:%M:%S')"
PID_BEFORE2="$(systemctl show -p MainPID --value "${UNIT}")"
echo "writer MainPID before = ${PID_BEFORE2}"
echo "--- publishing broken JSON ---"
echo '{"station_id":"lab01","sensor":"gatew",,,BROKEN'
mosquitto_pub -h "${MQTT_HOST}" -p "${MQTT_PORT}" -t "station/${STATION_ID}/gatew/moisture" \
  -m '{"station_id":"lab01","sensor":"gatew",,,BROKEN'
sleep 2
echo "--- what the writer logged ---"
journalctl -u "${UNIT}" --since "${MARK2}" --no-pager 2>&1 | grep -E 'REJECTED' | tail -3
PID_AFTER2="$(systemctl show -p MainPID --value "${UNIT}")"
STATE2="$(systemctl is-active "${UNIT}")"
echo "writer MainPID after = ${PID_AFTER2}"
echo "writer state = ${STATE2}"
LOGGED2="$(journalctl -u "${UNIT}" --since "${MARK2}" --no-pager 2>&1 | grep -c 'reason=malformed_json')"
echo "malformed_json log lines = ${LOGGED2}"

if [ "${LOGGED2}" -ge 1 ] && [ "${PID_BEFORE2}" = "${PID_AFTER2}" ] && [ "${STATE2}" = "active" ]; then
  gate_result pass \
    "A broken payload is logged at error with the payload and the reason. The process does not restart and does not exit." \
    "That every malformed shape is caught. This test sent one broken form. A payload that is valid JSON but wrong in a new way is a different case."
else
  gate_result fail "nothing" "nothing"
fi

gate_header 3 "NEGATIVE TEST, an unknown source is rejected loudly and counted"
MARK3="$(date '+%Y-%m-%d %H:%M:%S')"
PID_BEFORE3="$(systemctl show -p MainPID --value "${UNIT}")"
echo "--- the allowed set ---"
psql_show "select source, is_real, render_hint from public.sources order by source;"
PAYLOAD3="{\"station_id\":\"${STATION_ID}\",\"sensor\":\"gatew\",\"metric\":\"moisture\",\"value\":9.9,\"unit\":\"pct\",\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"source\":\"totally-made-up\"}"
echo "--- publishing with source = totally-made-up ---"
echo "${PAYLOAD3}"
mosquitto_pub -h "${MQTT_HOST}" -p "${MQTT_PORT}" -t "station/${STATION_ID}/gatew/moisture" -m "${PAYLOAD3}"
sleep 2
echo "--- what the writer logged, verbatim ---"
journalctl -u "${UNIT}" --since "${MARK3}" --no-pager -o cat 2>&1 | grep -E 'REJECTED' | tail -3
ROWS3="$(psql_val "select count(*) from public.readings where source='totally-made-up'")"
COUNTED3="$(journalctl -u "${UNIT}" --since "${MARK3}" --no-pager 2>&1 | grep -oE 'rejected_total=[0-9]+' | tail -1)"
PID_AFTER3="$(systemctl show -p MainPID --value "${UNIT}")"
echo "rows written with that source = ${ROWS3}"
echo "running rejection counter = ${COUNTED3}"
echo "writer MainPID unchanged = $([ "${PID_BEFORE3}" = "${PID_AFTER3}" ] && echo yes || echo no)"
LOGGED3="$(journalctl -u "${UNIT}" --since "${MARK3}" --no-pager 2>&1 | grep -c 'reason=foreign_key')"

if [ "${LOGGED3}" -ge 1 ] && [ "${ROWS3}" = "0" ] && [ -n "${COUNTED3}" ]; then
  gate_result pass \
    "The database refuses the row, the writer logs it at error with the payload and the reason, and it keeps a running count. Nothing is swallowed." \
    "That an operator ever reads the log. A counter in the journal is not an alarm. No metric is exported and no alert exists."
else
  gate_result fail "nothing" "nothing"
fi

gate_header 4 "NEGATIVE TEST, the writer reconnects after the broker restarts"
MARK4="$(date '+%Y-%m-%d %H:%M:%S')"
PID_BEFORE4="$(systemctl show -p MainPID --value "${UNIT}")"
echo "writer MainPID before = ${PID_BEFORE4}"
echo "--- stopping mosquitto ---"
systemctl stop mosquitto
sleep 3
systemctl is-active mosquitto
echo "--- starting mosquitto again ---"
systemctl start mosquitto
sleep 8
systemctl is-active mosquitto
echo "--- what the writer logged during the outage ---"
journalctl -u "${UNIT}" --since "${MARK4}" --no-pager -o cat 2>&1 | tail -6
echo "--- publishing after the restart, with no manual writer restart ---"
PAYLOAD4="{\"station_id\":\"${STATION_ID}\",\"sensor\":\"gatew\",\"metric\":\"reconnect\",\"value\":1.0,\"unit\":\"ok\",\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"source\":\"manual\"}"
mosquitto_pub -h "${MQTT_HOST}" -p "${MQTT_PORT}" -t "station/${STATION_ID}/gatew/reconnect" -m "${PAYLOAD4}"
wait_for_count "select count(*) from public.readings where sensor='gatew' and metric='reconnect'" "1" 40
ROWS4="$(psql_val "select count(*) from public.readings where sensor='gatew' and metric='reconnect'")"
PID_AFTER4="$(systemctl show -p MainPID --value "${UNIT}")"
echo "rows landed after the broker restart = ${ROWS4}"
echo "writer MainPID after = ${PID_AFTER4}"
psql_show "select id, sensor, metric, value, source, ts from public.readings where sensor='gatew' and metric='reconnect';"

if [ "${ROWS4}" = "1" ] && [ "${PID_BEFORE4}" = "${PID_AFTER4}" ]; then
  gate_result pass \
    "The writer resubscribed on its own after the broker went away and came back. The process ID did not change, so systemd did not restart it." \
    "That it survives a long outage. The broker was down for about three seconds. The backoff tops out at thirty seconds, and a multi hour outage was not tested. Messages published while the broker was down are lost, because nothing buffers them."
else
  gate_result fail "nothing" "nothing"
fi

gate_header 5 "the fixture is deterministic, same seed gives the same series"
echo "--- run one, seed 1337, dry run ---"
fixture_run --seed 1337 --dry-run --json 2> /dev/null > /tmp/fixture-a.json
echo "--- run two, seed 1337, dry run ---"
fixture_run --seed 1337 --dry-run --json 2> /dev/null > /tmp/fixture-b.json
echo "--- run three, seed 9999, dry run ---"
fixture_run --seed 9999 --dry-run --json 2> /dev/null > /tmp/fixture-c.json
echo "--- sha256 of each run ---"
sha256sum /tmp/fixture-a.json /tmp/fixture-b.json /tmp/fixture-c.json
echo "--- diff of the two runs with seed 1337 ---"
if diff -q /tmp/fixture-a.json /tmp/fixture-b.json > /dev/null; then
  echo "identical"
  SAME5=1
else
  echo "DIFFERENT, this is a defect"
  diff /tmp/fixture-a.json /tmp/fixture-b.json | head -20
  SAME5=0
fi
echo "--- diff of seed 1337 against seed 9999 ---"
if diff -q /tmp/fixture-a.json /tmp/fixture-c.json > /dev/null; then
  echo "identical, this is a defect, the seed does nothing"
  DIFFER5=0
else
  echo "different, the seed changes the series"
  DIFFER5=1
fi
echo "--- the first eight hours of seed 1337 ---"
"${VENV_PY}" -c "
import json
d = json.load(open('/tmp/fixture-a.json'))
print('rainfall_mm ', d['rainfall_mm'][:8])
print('salinity_psu', d['salinity_psu'][:8])
print('provenance  ', json.dumps(d['provenance']))
"

if [ "${SAME5}" = "1" ] && [ "${DIFFER5}" = "1" ]; then
  gate_result pass \
    "The generator is deterministic. The same seed makes a byte identical series, and a different seed makes a different one, so the seed is really an input." \
    "That the series is realistic. It is a plausible shape, not measured weather. Determinism is not accuracy, and no meteorologist checked these numbers."
else
  gate_result fail "nothing" "nothing"
fi

gate_header 6 "every fixture row joins to a source with is_real false"
MARK6="$(date '+%Y-%m-%d %H:%M:%S')"
echo "--- refusing to publish under a real source name ---"
echo "attempting: --source manual"
REFUSE_OUT="$(fixture_run --seed 1337 --hours 4 --source manual 2>&1)"
REFUSE_RC=$?
echo "${REFUSE_OUT}" | tail -5
echo "exit code ${REFUSE_RC}"
REFUSED6=0
if [ "${REFUSE_RC}" -ne 0 ]; then
  REFUSED6=1
fi
echo
echo "--- publishing the fixture properly ---"
fixture_run --seed 1337 --hours 48 2>&1 | tail -8
EXPECTED=96
wait_for_count "select count(*) from public.readings where provenance->>'generator'='mobilelab.fixture'" "${EXPECTED}" 60
echo "--- fixture rows joined to sources ---"
psql_show "
select r.source, s.is_real, s.render_hint, count(*) as rows
from public.readings r
join public.sources s on s.source = r.source
where r.provenance->>'generator' = 'mobilelab.fixture'
group by r.source, s.is_real, s.render_hint;"
echo "--- any fixture row claiming a real source? ---"
BADREAL="$(psql_val "
select count(*) from public.readings r
join public.sources s on s.source = r.source
where r.provenance->>'generator' = 'mobilelab.fixture' and s.is_real = true")"
echo "fixture rows with is_real true = ${BADREAL}"
TOTAL6="$(psql_val "select count(*) from public.readings where provenance->>'generator'='mobilelab.fixture'")"
NOPROV="$(psql_val "select count(*) from public.readings where source='synthetic' and provenance is null")"
echo "fixture rows total = ${TOTAL6}"
echo "synthetic rows with no provenance = ${NOPROV}"
echo "--- provenance stored on a sample row ---"
psql_show "select jsonb_pretty(provenance) from public.readings where provenance->>'generator'='mobilelab.fixture' limit 1;"

if [ "${BADREAL}" = "0" ] && [ "${TOTAL6}" = "${EXPECTED}" ] && [ "${NOPROV}" = "0" ] && [ "${REFUSED6}" = "1" ]; then
  gate_result pass \
    "Every fixture row carries a source whose is_real is false, and every one stores its seed in provenance. The fixture refuses to start when told to use a real source name." \
    "That a chart draws them differently. render_hint says dashed, but no chart reads it yet. Architecture section 16 keeps that blind spot OPEN until the kiosk honours it."
else
  gate_result fail "nothing" "nothing"
fi

echo
echo "================================================================"
echo "SUMMARY: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
echo "================================================================"
echo "final writer counters from the journal:"
journalctl -u "${UNIT}" --no-pager 2>&1 | grep -oE 'accepted_total=[0-9]+' | tail -1
journalctl -u "${UNIT}" --no-pager 2>&1 | grep -oE 'rejected_total=[0-9]+' | tail -1

if [ "${FAIL_COUNT}" -gt 0 ]; then
  exit 1
fi
