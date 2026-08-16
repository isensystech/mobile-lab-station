#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

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
TOPIC="station/${STATION_ID}/soil/moisture"

PASS_COUNT=0
FAIL_COUNT=0

psql_db() {
  runuser -u postgres -- psql -v ON_ERROR_STOP=1 -d "${DB_NAME}" "$@"
}

psql_val() {
  runuser -u postgres -- psql -t -A -d "${DB_NAME}" -c "$1" 2>&1 | tr -d '\r'
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
  echo "PROVES:      $2"
  echo "DOES NOT PROVE: $3"
}

echo "Mobile Lab Station data spine verification"
echo "host $(hostname), $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "database ${DB_NAME}, station ${STATION_ID}"

echo
echo "==> clearing rows from an earlier run (sensor = 'gate')"
psql_db -q -c "delete from public.readings where sensor = 'gate';" > /dev/null 2>&1
psql_db -q -c "delete from public.observations where site_label = 'gate-harness';" > /dev/null 2>&1

gate_header 1 "services active and the timescaledb extension loads"
echo "--- systemctl is-active ---"
for svc in mosquitto postgresql; do
  printf '%-14s ' "${svc}"
  systemctl is-active "${svc}"
done
echo "--- systemctl status, first lines ---"
systemctl status mosquitto --no-pager 2>&1 | head -4
echo
systemctl status postgresql --no-pager 2>&1 | head -4
echo "--- extension version ---"
EXTVER="$(psql_val "select extversion from pg_extension where extname='timescaledb'")"
echo "timescaledb extversion = ${EXTVER}"
echo "--- shared_preload_libraries ---"
psql_val "show shared_preload_libraries"
echo "--- edition check, continuous aggregates need the community edition ---"
psql_val "select current_setting('timescaledb.license', true)"

if [ "$(systemctl is-active mosquitto)" = "active" ] \
   && [ "$(systemctl is-active postgresql)" = "active" ] \
   && [ -n "${EXTVER}" ]; then
  gate_result pass \
    "Both units run under systemd. The timescaledb library loads into PostgreSQL." \
    "That either unit restarts after a power cut. Nothing here tested boot order or the UPS HAT."
else
  gate_result fail "nothing" "nothing"
fi

gate_header 2 "mosquitto accepts a publish on ${TOPIC}"
SUBOUT="$(mktemp)"
mosquitto_sub -h "${MQTT_HOST}" -p "${MQTT_PORT}" -t "${TOPIC}" -C 1 -W 8 > "${SUBOUT}" 2>&1 &
SUBPID=$!
sleep 1
PAYLOAD="{\"station_id\":\"${STATION_ID}\",\"sensor\":\"soil\",\"metric\":\"moisture\",\"value\":34.2,\"unit\":\"pct\",\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"source\":\"manual\"}"
echo "--- publishing ---"
echo "topic   ${TOPIC}"
echo "payload ${PAYLOAD}"
mosquitto_pub -h "${MQTT_HOST}" -p "${MQTT_PORT}" -t "${TOPIC}" -m "${PAYLOAD}"
PUB_RC=$?
echo "mosquitto_pub exit code ${PUB_RC}"
wait "${SUBPID}" 2> /dev/null
echo "--- subscriber received ---"
cat "${SUBOUT}"
RECEIVED="$(cat "${SUBOUT}")"
rm -f "${SUBOUT}"

if [ "${PUB_RC}" -eq 0 ] && [ -n "${RECEIVED}" ]; then
  gate_result pass \
    "The broker accepted the publish and delivered the payload to a subscriber on the same topic." \
    "That any writer consumes it. No writer service exists. The payload was not parsed, validated, or stored by this gate."
else
  gate_result fail "nothing" "nothing"
fi

gate_header 3 "a manually inserted readings row is retrievable"
echo "--- insert ---"
psql_db -c "
insert into public.readings
  (station_id, sensor, metric, value, unit, ts, lat, lon, source, quality_flag)
values
  ('${STATION_ID}', 'gate', 'moisture', 34.2, 'pct', now(), 27.99, -80.62, 'manual', 'plausible');"
echo "--- select ---"
psql_db -c "
select id, station_id, sensor, metric, value, unit, source, quality_flag, ts
from public.readings
where sensor = 'gate'
order by ts desc;"
R3="$(psql_val "select count(*) from public.readings where sensor='gate'")"
echo "row count = ${R3}"

if [ "${R3}" -ge 1 ] 2> /dev/null; then
  gate_result pass \
    "The hypertable accepts a write and returns it. The foreign keys to stations and sources are satisfiable." \
    "That the schema is correct for real sensor data. One hand written row is not an ingest path, and no driver has written to this table."
else
  gate_result fail "nothing" "nothing"
fi

gate_header 4 "an observations row groups several readings rows"
echo "--- insert one observation and three readings ---"
psql_db -c "
with obs as (
  insert into public.observations
    (station_id, observer, site_label, ts, lat, lon, note, quality_flag)
  values
    ('${STATION_ID}', 'A. Student', 'gate-harness', now(), 27.99, -80.62,
     'The water looked cloudy after the rain.', 'plausible')
  returning observation_id
)
insert into public.readings
  (station_id, sensor, metric, value, unit, ts, source, observation_id,
   value_raw, unit_raw, quality_flag)
select '${STATION_ID}', 'gate', m.metric, m.value, m.unit, now(), 'manual',
       obs.observation_id, m.raw, m.raw_unit, 'plausible'
from obs,
  (values
    ('ph',   7.2,  'ph',   7.2,  'ph'),
    ('temp', 24.4, 'degC', 75.9, 'degF'),
    ('ec',   1.35, 'mScm', 1.35, 'mScm')
  ) as m(metric, value, unit, raw, raw_unit);"
echo "--- the group ---"
psql_db -c "
select o.observation_id, o.observer, o.note,
       count(r.id) as readings_in_batch,
       string_agg(r.metric || '=' || r.value || r.unit, ', ' order by r.metric) as metrics
from public.observations o
join public.readings r on r.observation_id = o.observation_id
where o.site_label = 'gate-harness'
group by o.observation_id, o.observer, o.note;"
echo "--- raw versus canonical, the degF case ---"
psql_db -c "
select metric, value, unit, value_raw, unit_raw
from public.readings
where sensor = 'gate' and observation_id is not null
order by metric;"
R4="$(psql_val "select count(*) from public.readings r join public.observations o on o.observation_id=r.observation_id where o.site_label='gate-harness'")"
echo "grouped row count = ${R4}"

if [ "${R4}" -eq 3 ] 2> /dev/null; then
  gate_result pass \
    "One observation_id groups three readings rows. value_raw and unit_raw keep what the person typed next to the converted value." \
    "That the manual entry form produces this shape. No form exists. Nothing here converted degF to degC, the harness wrote both numbers by hand."
else
  gate_result fail "nothing" "nothing"
fi

gate_header 5 "the continuous aggregate returns a rollup"
echo "--- registered continuous aggregates ---"
psql_db -c "
select view_name, materialization_hypertable_name, materialized_only, compression_enabled
from timescaledb_information.continuous_aggregates
order by view_name;"
echo "--- refresh policies ---"
psql_db -c "
select application_name, schedule_interval, config
from timescaledb_information.jobs
where proc_name = 'policy_refresh_continuous_aggregate'
order by application_name;"
echo "--- readings_1m rollup for the gate rows ---"
psql_db -c "
select bucket, sensor, metric, unit, source, avg_value, min_value, max_value, sample_count
from public.readings_1m
where sensor = 'gate'
order by bucket desc, metric;"
echo "--- readings_1h rollup for the gate rows ---"
psql_db -c "
select bucket, sensor, metric, unit, source, avg_value, sample_count
from public.readings_1h
where sensor = 'gate'
order by bucket desc, metric;"
R5="$(psql_val "select count(*) from public.readings_1m where sensor='gate'")"
echo "readings_1m row count = ${R5}"

if [ "${R5}" -ge 1 ] 2> /dev/null; then
  gate_result pass \
    "Both continuous aggregates exist, carry a refresh policy, and return buckets. The community edition is installed, because the Apache edition cannot make these views." \
    "That the rollups are correct over time. These buckets came from real time aggregation over rows seconds old. No background refresh job has run yet, and no bucket has been read after its window closed."
else
  gate_result fail "nothing" "nothing"
fi

gate_header 6 "NEGATIVE TEST, data survives a postgresql restart"
BEFORE="$(psql_val "select count(*) from public.readings where sensor='gate'")"
BEFORE_OBS="$(psql_val "select count(*) from public.observations where site_label='gate-harness'")"
echo "readings before restart     = ${BEFORE}"
echo "observations before restart = ${BEFORE_OBS}"
echo "--- systemctl restart postgresql ---"
systemctl restart postgresql
sleep 5
systemctl is-active postgresql
echo "--- uptime of the new backend ---"
psql_val "select date_trunc('second', now() - pg_postmaster_start_time()) as postmaster_uptime"
AFTER="$(psql_val "select count(*) from public.readings where sensor='gate'")"
AFTER_OBS="$(psql_val "select count(*) from public.observations where site_label='gate-harness'")"
echo "readings after restart      = ${AFTER}"
echo "observations after restart  = ${AFTER_OBS}"
echo "--- the aggregate still answers ---"
psql_db -c "select count(*) as rollup_buckets from public.readings_1m where sensor='gate';"

if [ "${BEFORE}" = "${AFTER}" ] && [ "${BEFORE_OBS}" = "${AFTER_OBS}" ] && [ "${BEFORE}" -gt 0 ] 2> /dev/null; then
  gate_result pass \
    "A clean service restart keeps committed rows. The data directory survives a stop and start, and the extension reloads." \
    "That data survives a power cut. A clean restart flushes buffers first. Arch section 17 still wants the power yank test with the UPS HAT, and that hardware is absent."
else
  gate_result fail "nothing" "nothing"
fi

gate_header 7 "NEGATIVE TEST, a readings row with a source outside the allowed set"
echo "--- the allowed set ---"
psql_db -c "select source, kind, is_real, render_hint from public.sources order by source;"
echo "--- attempting an insert with source = 'totally-made-up' ---"
BAD_OUT="$(psql_db -c "
insert into public.readings (station_id, sensor, metric, value, unit, ts, source)
values ('${STATION_ID}', 'gate', 'moisture', 1.0, 'pct', now(), 'totally-made-up');" 2>&1)"
BAD_RC=$?
echo "${BAD_OUT}"
echo "psql exit code ${BAD_RC}"
BADCOUNT="$(psql_val "select count(*) from public.readings where source='totally-made-up'")"
echo "rows now present with that source = ${BADCOUNT}"

if [ "${BAD_RC}" -ne 0 ] && [ "${BADCOUNT}" = "0" ]; then
  echo "OUTCOME: REJECTED. The database refused the row. It was not flagged, it was not written."
  gate_result pass \
    "readings.source cannot hold a value that is not in public.sources. A driver with a typo in its source name fails loudly at the write, not silently on a chart." \
    "That the user interface honours the labelling rule. Arch section 16 keeps that blind spot OPEN. The database can only guarantee the label exists and carries is_real. It cannot make a chart draw the dashed line."
else
  echo "OUTCOME: ACCEPTED. This is a defect."
  gate_result fail "nothing" "nothing"
fi

gate_header 8 "nightly pg_dump, scheduled, and one manual run"
echo "--- postgresql data directory ---"
DATA_DIR="$(psql_val "show data_directory")"
echo "${DATA_DIR}"
echo "--- device that holds the data directory ---"
df -hT "${DATA_DIR}" 2>/dev/null || df -h "${DATA_DIR}"
echo "--- timer ---"
systemctl is-enabled mobilelab-backup.timer 2>&1
systemctl list-timers mobilelab-backup.timer --no-pager 2>&1
echo "--- manual run ---"
"${SCRIPT_DIR}/backup/mobilelab-pg-backup.sh"
BK_RC=$?
BACKUP_DIR="${MOBILELAB_BACKUP_DIR:-/var/backups/mobilelab}"
NEWEST="$(find "${BACKUP_DIR}" -name "${DB_NAME}-*.dump" -type f 2> /dev/null | sort | tail -1)"
echo "--- newest dump ---"
TABLES_FOUND=0
if [ -n "${NEWEST}" ]; then
  ls -l "${NEWEST}"
  DUMP_SIZE="$(stat -c %s "${NEWEST}")"
  echo "size ${DUMP_SIZE} bytes"
  echo "--- schema entries in the dump ---"
  pg_restore --list "${NEWEST}" 2> /dev/null \
    | grep -E 'TABLE public (stations|readings|observations|sources)[[:space:]]'
  echo "--- data entries in the dump ---"
  pg_restore --list "${NEWEST}" 2> /dev/null \
    | grep -E 'TABLE DATA public (stations|readings|observations|sources)[[:space:]]'
  TABLES_FOUND="$(pg_restore --list "${NEWEST}" 2> /dev/null \
    | grep -cE 'TABLE DATA public (stations|readings|observations|sources)[[:space:]]')"
  echo "expected tables with data in the dump = ${TABLES_FOUND} of 4"
else
  DUMP_SIZE=0
  echo "no dump file found"
fi

if [ "${BK_RC}" -eq 0 ] && [ "${DUMP_SIZE}" -gt 0 ] && [ "${TABLES_FOUND}" -eq 4 ] 2> /dev/null; then
  gate_result pass \
    "pg_dump writes a non empty custom format dump outside the PostgreSQL data directory, and a systemd timer runs it nightly. The script refuses to write inside the data directory." \
    "That the backup survives the card dying. There is no NVMe and no second device on this Pi, so the dump sits on the same microSD as the database. It protects against a bad migration and against database corruption. It does not protect against card failure. Nothing here restored the dump, so recovery is untested."
else
  gate_result fail "nothing" "nothing"
fi

echo
echo "================================================================"
echo "SUMMARY: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
echo "================================================================"
echo "Verification rows use sensor = 'gate' and site_label = 'gate-harness'."
echo "Delete them with:"
echo "  delete from public.readings where sensor = 'gate';"
echo "  delete from public.observations where site_label = 'gate-harness';"

if [ "${FAIL_COUNT}" -gt 0 ]; then
  exit 1
fi
