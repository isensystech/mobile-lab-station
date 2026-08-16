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
WORK=/tmp/mlgate
mkdir -p "${WORK}"

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

echo "Mobile Lab Station local API verification"
echo "host $(hostname), $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "api ${BASE}"

echo
echo "==> the API listens on every interface, not loopback only"
ss -lntp 2> /dev/null | grep -E ":${API_PORT}"

WINDOW_START="$(date -u -d '-47 hours' +%Y-%m-%dT%H:00:00Z)"
WINDOW_END="$(date -u -d '+1 hour' +%Y-%m-%dT%H:00:00Z)"
IN_WINDOW="select count(*) from public.readings where source='synthetic' and ts >= '${WINDOW_START}' and ts < '${WINDOW_END}'"

wait_stable() {
  local sql="$1"
  local same=0
  local last="x"
  local now
  for _ in $(seq 1 80); do
    now="$(psql_val "${sql}")"
    if [ "${now}" = "${last}" ]; then
      same=$((same + 1))
      [ "${same}" -ge 3 ] && return 0
    else
      same=0
    fi
    last="${now}"
    sleep 0.5
  done
  return 1
}

echo
echo "==> waiting for the writer to finish any earlier work"
echo "    A previous suite can still be inserting. Deleting under it would"
echo "    leave stragglers behind and make this run flaky."
wait_stable "select count(*) from public.readings"
echo "    settled at $(psql_val "select count(*) from public.readings") rows"

echo
echo "==> loading fixture data across the last 48 hours"
echo "    from ${WINDOW_START} to ${WINDOW_END}"
psql_show "delete from public.readings where source = 'synthetic';" > /dev/null
runuser -u mobilelab -- env PYTHONPATH="${REPO_ROOT}/services" "${VENV_PY}" \
  -m mobilelab.fixture --seed 1337 --hours 48 --start "${WINDOW_START}" 2>&1 | tail -3

for _ in $(seq 1 80); do
  LOADED="$(psql_val "${IN_WINDOW}")"
  [ "${LOADED}" = "96" ] && break
  sleep 0.5
done
echo "    synthetic rows inside the window = ${LOADED}"
if [ "${LOADED}" != "96" ]; then
  echo "    WARNING: expected 96. The gates below will show what landed."
fi

echo
echo "==> materializing the aggregate over that window"
echo "    A backfill lands behind the refresh policy watermark. Without this"
echo "    call the aggregate stays empty for the backfilled range."
runuser -u postgres -- psql -d "${DB_NAME}" \
  -c "call refresh_continuous_aggregate('public.readings_1m', '${WINDOW_START}', '${WINDOW_END}');" 2>&1 | tail -2

gate_header 1 "a history query returns rows for a known range"
curl -sS "${BASE}/api/readings?sensor=rain&metric=rainfall&source=synthetic&from=${WINDOW_START}&to=${WINDOW_END}" \
  -o "${WORK}/g1.json" -w "http_status=%{http_code}\n"
echo "--- response head ---"
pyq "${WORK}/g1.json" "
print('station_id  ', d['station_id'])
print('from        ', d['from'])
print('to          ', d['to'])
print('served_from ', d['served_from'])
print('bucket      ', d['bucket'])
print('caption     ', d['caption'])
for s in d['series']:
    print(f\"series      {s['sensor']}/{s['metric']} source={s['source']} unit={s['unit']} points={s['point_count']} is_real={s['is_real']} render_hint={s['render_hint']}\")
    print('first three ', [(p['ts'], p['value']) for p in s['points'][:3]])
"
G1="$(pyq "${WORK}/g1.json" "print(sum(s['point_count'] for s in d['series']))")"
echo "total points = ${G1}"
if [ "${G1}" -gt 0 ] 2> /dev/null; then
  gate_result pass \
    "The REST history endpoint reads the database and returns points for a station, sensor, metric, and time range." \
    "That the numbers are right for a real sensor. The rows came from the fixture. No driver has written through this path."
else
  gate_result fail "nothing" "nothing"
fi

gate_header 2 "a two series query returns both series on one shared axis"
curl -sS "${BASE}/api/series/pair?a_sensor=rain&a_metric=rainfall&a_source=synthetic&b_sensor=water&b_metric=salinity&b_source=synthetic&from=${WINDOW_START}&to=${WINDOW_END}" \
  -o "${WORK}/g2.json" -w "http_status=%{http_code}\n"
echo "--- response shape ---"
pyq "${WORK}/g2.json" "
print('served_from ', d['served_from'], ' bucket', d['bucket'])
print('axis length ', len(d['axis']))
for s in d['series']:
    print(f\"series {s['key']}: {s['sensor']}/{s['metric']} unit={s['unit']} values={len(s['values'])} is_real={s['is_real']} render_hint={s['render_hint']}\")
print()
print('first five rows of the shared axis:')
print(f\"{'bucket':26s} {'rainfall':>10s} {'salinity':>10s}\")
a=d['series'][0]['values']; b=d['series'][1]['values']
for i in range(min(5,len(d['axis']))):
    print(f\"{d['axis'][i]:26s} {str(a[i]):>10s} {str(b[i]):>10s}\")
"
G2="$(pyq "${WORK}/g2.json" "
ax=len(d['axis']); va=len(d['series'][0]['values']); vb=len(d['series'][1]['values'])
print('ALIGNED' if (ax==va==vb and ax>0 and len(d['series'])==2) else 'MISALIGNED')
")"
echo "alignment = ${G2}"
if [ "${G2}" = "ALIGNED" ]; then
  gate_result pass \
    "Both metrics come back on one time axis of equal length, so the overlay chart can plot them without stitching anything together." \
    "That the axis is gap free. A full outer join keeps a row when either series has a point, and writes null for the other. The chart still has to decide how to draw a null."
else
  gate_result fail "nothing" "nothing"
fi

gate_header 3 "every response carrying readings also carries is_real and render_hint"
echo "--- checking all three readings paths ---"
curl -sS "${BASE}/api/sources" -o "${WORK}/g3sources.json"
timeout 12 runuser -u mobilelab -- env PYTHONPATH="${REPO_ROOT}/services" "${VENV_PY}" \
  -m mobilelab.wslisten --host "${LAN_IP}" --port "${API_PORT}" --count 1 --timeout 10 \
  > "${WORK}/g3ws.txt" 2>&1 &
WSPID=$!
sleep 2
mosquitto_pub -h "${MQTT_HOST}" -q 1 -t "station/${STATION_ID}/soil/moisture" \
  -m "{\"station_id\":\"${STATION_ID}\",\"sensor\":\"soil\",\"metric\":\"moisture\",\"value\":33.3,\"unit\":\"pct\",\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"source\":\"manual\"}"
wait "${WSPID}" 2> /dev/null
MISSING="$("${VENV_PY}" -c "
import json
bad=[]
h=json.load(open('${WORK}/g1.json'))
for s in h['series']:
    if 'is_real' not in s or 'render_hint' not in s: bad.append('readings:'+s['source'])
p=json.load(open('${WORK}/g2.json'))
for s in p['series']:
    if 'is_real' not in s or 'render_hint' not in s: bad.append('pair:'+s['key'])
src=json.load(open('${WORK}/g3sources.json'))
for s in src:
    if 'is_real' not in s or 'render_hint' not in s: bad.append('sources:'+s['source'])
print(','.join(bad) if bad else 'NONE')
")"
echo "--- /api/sources ---"
pyq "${WORK}/g3sources.json" "
print(f\"{'source':16s} {'is_real':8s} {'render_hint':12s}\")
for s in d: print(f\"{s['source']:16s} {str(s['is_real']):8s} {s['render_hint']:12s}\")" 2>/dev/null || \
  "${VENV_PY}" -c "
import json
for s in json.load(open('${WORK}/g3sources.json')):
    print(f\"{s['source']:16s} {str(s['is_real']):8s} {s['render_hint']:12s}\")"
echo "--- websocket message ---"
grep -E 'REAL|SIMULATED' "${WORK}/g3ws.txt" || cat "${WORK}/g3ws.txt"
WSHAS="$(grep -cE 'render_hint=' "${WORK}/g3ws.txt")"
echo "fields missing anywhere = ${MISSING}"
echo "websocket lines carrying render_hint = ${WSHAS}"
if [ "${MISSING}" = "NONE" ] && [ "${WSHAS}" -ge 1 ]; then
  gate_result pass \
    "The history response, the pair response, the sources list, and the live websocket all carry is_real and render_hint. The response model makes those fields required, so the API cannot omit them." \
    "That the kiosk uses them. The data layer offers the labelling. Whether a chart draws the dashed line is a UI question, and architecture section 16 keeps that blind spot OPEN."
else
  gate_result fail "nothing" "nothing"
fi

gate_header 4 "health reports the writer counters, and rejected_total rises after a bad publish"
curl -sS "${BASE}/health" -o "${WORK}/g4a.json"
echo "--- health before ---"
pyq "${WORK}/g4a.json" "
print('status   ', d['status'])
print('database ', d['database'])
print('broker   ', d['broker'])
w=d['writer']
print('writer   ', {k:w[k] for k in ('accepted_total','rejected_total','queue_depth','stale')})
print('reasons  ', w['rejected_by_reason'])
"
BEFORE="$(pyq "${WORK}/g4a.json" "print(d['writer']['rejected_total'])")"
echo
echo "--- publishing a deliberate bad payload, source is not in the sources table ---"
mosquitto_pub -h "${MQTT_HOST}" -q 1 -t "station/${STATION_ID}/soil/moisture" \
  -m "{\"station_id\":\"${STATION_ID}\",\"sensor\":\"soil\",\"metric\":\"moisture\",\"value\":1.0,\"unit\":\"pct\",\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"source\":\"not-a-real-source\"}"
sleep 3
curl -sS "${BASE}/health" -o "${WORK}/g4b.json"
AFTER="$(pyq "${WORK}/g4b.json" "print(d['writer']['rejected_total'])")"
echo "--- health after ---"
pyq "${WORK}/g4b.json" "
w=d['writer']
print('writer   ', {k:w[k] for k in ('accepted_total','rejected_total','queue_depth','stale')})
print('reasons  ', w['rejected_by_reason'])
print('age_secs ', round(w['age_seconds'],2) if w['age_seconds'] is not None else None)
"
echo "rejected_total before = ${BEFORE}, after = ${AFTER}"
if [ "${AFTER}" -gt "${BEFORE}" ] 2> /dev/null; then
  gate_result pass \
    "The API reports the writer counters, and a bad publish moves rejected_total up. The writer publishes its counters as a retained MQTT message and the API reads it." \
    "That health catches a dead writer quickly. The status is a retained message with a timestamp, so the API reports the last known counters and marks them stale after 60 seconds. It is not a heartbeat probe of the process."
else
  gate_result fail "nothing" "nothing"
fi

gate_header 5 "the websocket delivers a live reading within 2 seconds of the publish"
timeout 15 runuser -u mobilelab -- env PYTHONPATH="${REPO_ROOT}/services" "${VENV_PY}" \
  -m mobilelab.wslisten --host "${LAN_IP}" --port "${API_PORT}" --count 1 --timeout 12 \
  > "${WORK}/g5.txt" 2>&1 &
WSPID=$!
sleep 3
echo "--- publishing now ---"
PUBLISHED_AT="$(date +%s.%N)"
mosquitto_pub -h "${MQTT_HOST}" -q 1 -t "station/${STATION_ID}/air/temperature" \
  -m "{\"station_id\":\"${STATION_ID}\",\"sensor\":\"air\",\"metric\":\"temperature\",\"value\":28.1,\"unit\":\"degC\",\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"source\":\"manual\"}"
wait "${WSPID}" 2> /dev/null
RECEIVED_AT="$(date +%s.%N)"
echo "--- what the websocket client saw ---"
cat "${WORK}/g5.txt"
LATENCY="$("${VENV_PY}" -c "print(f'{${RECEIVED_AT} - ${PUBLISHED_AT}:.3f}')")"
echo "publish to websocket delivery = ${LATENCY} s"
GOT5="$(grep -cE 'air/temperature' "${WORK}/g5.txt")"
FAST5="$("${VENV_PY}" -c "print('yes' if ${LATENCY} < 2.0 else 'no')")"
echo "delivered = ${GOT5}, under two seconds = ${FAST5}"
if [ "${GOT5}" -ge 1 ] && [ "${FAST5}" = "yes" ]; then
  gate_result pass \
    "A reading published to the broker reaches an open websocket client in well under two seconds, already labelled with is_real and render_hint." \
    "That it holds up with many clients or a slow one. One client was connected. A slow client loses messages by design, because the fan out drops rather than blocking the broker thread."
else
  gate_result fail "nothing" "nothing"
fi

gate_header 6 "a 48 hour query is served from a continuous aggregate"
curl -sS "${BASE}/api/readings?sensor=water&metric=salinity&source=synthetic&from=${WINDOW_START}&to=${WINDOW_END}&explain=1" \
  -o "${WORK}/g6.json"
SERVED="$(pyq "${WORK}/g6.json" "print(d['served_from'])")"
BUCKET="$(pyq "${WORK}/g6.json" "print(d['bucket'])")"
echo "served_from = ${SERVED}"
echo "bucket      = ${BUCKET}"
echo
echo "--- the query plan ---"
pyq "${WORK}/g6.json" "
for line in d['explain']: print(' ', line)
"
echo
echo "--- does the aggregate actually cover the window? ---"
echo "    An empty aggregate would still name the aggregate in the plan."
echo "    So compare the sample counts against the raw rows."
psql_show "
select
  (select count(*) from public.readings
     where source='synthetic' and metric='salinity'
       and ts >= '${WINDOW_START}' and ts < '${WINDOW_END}')       as raw_rows,
  (select coalesce(sum(sample_count),0) from public.readings_1m
     where source='synthetic' and metric='salinity'
       and bucket >= '${WINDOW_START}' and bucket < '${WINDOW_END}') as aggregate_samples;"
RAWROWS="$(psql_val "select count(*) from public.readings where source='synthetic' and metric='salinity' and ts >= '${WINDOW_START}' and ts < '${WINDOW_END}'")"
AGGSAMP="$(psql_val "select coalesce(sum(sample_count),0) from public.readings_1m where source='synthetic' and metric='salinity' and bucket >= '${WINDOW_START}' and bucket < '${WINDOW_END}'")"
RAWCHUNKS="$(pyq "${WORK}/g6.json" "print(sum(1 for l in d['explain'] if '_hyper_1_' in l))")"
MATCHUNKS="$(pyq "${WORK}/g6.json" "print(sum(1 for l in d['explain'] if '_hyper_2_' in l or '_materialized_hypertable_2' in l))")"
echo "raw rows = ${RAWROWS}, aggregate samples = ${AGGSAMP}"
echo "plan nodes touching raw readings chunks   = ${RAWCHUNKS}"
echo "plan nodes touching the materialized data = ${MATCHUNKS}"
if [ "${SERVED}" = "public.readings_1m" ] && [ "${AGGSAMP}" = "${RAWROWS}" ] && [ "${MATCHUNKS}" -ge 1 ]; then
  gate_result pass \
    "A 48 hour query resolves to readings_1m, not the raw hypertable, and the aggregate holds a sample for every raw row in the window, so the rollup is complete rather than empty." \
    "That raw is never touched. materialized_only is false, so the plan also unions a real time tail for rows newer than the last refresh. That tail is bounded by the refresh interval. It is not a scan of the whole 48 hours."
else
  gate_result fail "nothing" "nothing"
fi

gate_header 7 "DURABILITY, five messages published while the writer is stopped all arrive"
echo "--- broker persistence settings ---"
grep -hE '^(persistence|autosave_interval|max_queued_messages)' \
  /etc/mosquitto/mosquitto.conf /etc/mosquitto/conf.d/mobilelab.conf
echo "--- the writer holds a persistent session ---"
grep -n 'clean_session' "${REPO_ROOT}/services/mobilelab/writer.py" | head -2
journalctl -u mobilelab-writer --no-pager 2>&1 | grep -oE 'session_present=[A-Za-z]+' | tail -1
echo
psql_show "delete from public.readings where sensor = 'durable';" > /dev/null
echo "--- stopping the writer ---"
systemctl stop mobilelab-writer
sleep 2
systemctl is-active mobilelab-writer
echo "--- publishing five messages at QoS 1 with the writer DOWN ---"
for n in 1 2 3 4 5; do
  mosquitto_pub -h "${MQTT_HOST}" -q 1 -t "station/${STATION_ID}/durable/probe" \
    -m "{\"station_id\":\"${STATION_ID}\",\"sensor\":\"durable\",\"metric\":\"probe\",\"value\":${n}.0,\"unit\":\"n\",\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"source\":\"manual\"}"
  echo "  published ${n}"
done
DURING="$(psql_val "select count(*) from public.readings where sensor='durable'")"
echo "rows in the database while the writer is down = ${DURING}"
echo "--- starting the writer ---"
systemctl start mobilelab-writer
for _ in $(seq 1 60); do
  LANDED="$(psql_val "select count(*) from public.readings where sensor='durable'")"
  [ "${LANDED}" = "5" ] && break
  sleep 0.5
done
echo "rows after the writer came back = ${LANDED}"
psql_show "select id, value, source, ts from public.readings where sensor='durable' order by value;"
if [ "${DURING}" = "0" ] && [ "${LANDED}" = "5" ]; then
  gate_result pass \
    "The broker held five QoS 1 messages while the writer was stopped and delivered every one at reconnect. A writer restart no longer loses data." \
    "That the broker survives its own restart with the queue intact. Mosquitto writes the queue to disk every 60 seconds, so a power cut can still lose up to a minute of queued messages. This test stopped the writer, not the broker."
else
  gate_result fail "nothing" "nothing"
fi

gate_header 8 "NEGATIVE TEST, the API survives a postgresql restart"
echo "This gate exists because the API failed here once. The connection pool"
echo "handed out a connection that PostgreSQL had already killed, and the API"
echo "answered 500 while the database was healthy."
echo
API_PID_BEFORE="$(systemctl show -p MainPID --value mobilelab-api)"
echo "api MainPID before = ${API_PID_BEFORE}"
echo "--- a request before the restart ---"
curl -sS -o /dev/null -w "  http_status=%{http_code}\n" \
  "${BASE}/api/readings?sensor=rain&metric=rainfall&source=synthetic&from=${WINDOW_START}&to=${WINDOW_END}"
echo "--- restarting postgresql under the running API ---"
systemctl restart postgresql
sleep 5
echo "--- the first request after the restart, on a pooled dead connection ---"
CODE_A="$(curl -sS -o "${WORK}/g8.json" -w "%{http_code}" \
  "${BASE}/api/readings?sensor=rain&metric=rainfall&source=synthetic&from=${WINDOW_START}&to=${WINDOW_END}")"
echo "  http_status=${CODE_A}"
echo "--- a second request ---"
CODE_B="$(curl -sS -o /dev/null -w "%{http_code}" "${BASE}/health")"
echo "  http_status=${CODE_B}"
API_PID_AFTER="$(systemctl show -p MainPID --value mobilelab-api)"
echo "api MainPID after = ${API_PID_AFTER}"
POINTS8="$(pyq "${WORK}/g8.json" "print(sum(s['point_count'] for s in d['series']))" 2>/dev/null || echo 0)"
echo "points returned on the first request after the restart = ${POINTS8}"
if [ "${CODE_A}" = "200" ] && [ "${CODE_B}" = "200" ] \
   && [ "${API_PID_BEFORE}" = "${API_PID_AFTER}" ] && [ "${POINTS8}" -gt 0 ] 2> /dev/null; then
  gate_result pass \
    "The very first request after a database restart answers 200 with real rows. The pool probes a connection before it hands it out, so a dead one is replaced instead of returned." \
    "That the API survives the database being gone for a long time. PostgreSQL was back within five seconds. A request made while it is still down will fail, because nothing queues or retries a read."
else
  gate_result fail "nothing" "nothing"
fi

echo
echo "================================================================"
echo "SUMMARY: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
echo "================================================================"
psql_show "delete from public.readings where sensor = 'durable';" > /dev/null
if [ "${FAIL_COUNT}" -gt 0 ]; then
  exit 1
fi
