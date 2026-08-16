#!/usr/bin/env bash
set -uo pipefail

: <<'ABOUT'
Seeds the rehearsal rig.

It publishes three series that end at the present hour, so the last seven days
of the chart are full:

  water salinity   source synthetic         the response
  rain rainfall    source synthetic         the local gauge
  rain rainfall    source public_synthetic  the cell average

It then refreshes the rollups. Hard rule 14 requires that. Every record here is
backdated, the chart reads rollups, and a backdated write that skips the refresh
is invisible on screen while appearing to succeed.
ABOUT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VENV_PY="${REPO_ROOT}/.venv/bin/python"

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: run this script with sudo." >&2
  exit 1
fi

set -a
. "${REPO_ROOT}/.env"
set +a

HOURS="${MOBILELAB_REHEARSAL_HOURS:-336}"
SEED="${MOBILELAB_REHEARSAL_SEED:-1337}"
LAG="${MOBILELAB_REHEARSAL_LAG:-6}"
DB_NAME="${MOBILELAB_DB:-mobilelab}"

START="$(date -u -d "-${HOURS} hours" +%Y-%m-%dT%H:00:00Z)"

echo "======================================================================"
echo " SEEDING THE REHEARSAL RIG"
echo "======================================================================"
echo "  hours ${HOURS}, seed ${SEED}, lag ${LAG}"
echo "  start ${START}"
echo

echo "--- clearing any earlier rig data ---"
echo "    readings has no uniqueness on station, sensor, metric, source and ts."
echo "    Running this script twice would otherwise stack a second identical"
echo "    copy of every row on top of the first."
runuser -u postgres -- psql -q -d "${DB_NAME}" -c \
  "delete from public.readings where source in ('synthetic','public_synthetic');"
echo "    rows now: $(runuser -u postgres -- psql -tAc "select count(*) from public.readings where source in ('synthetic','public_synthetic')" -d "${DB_NAME}")"
echo

run_py() {
  runuser -u mobilelab -- env PYTHONPATH="${REPO_ROOT}/services" \
    MOBILELAB_STATION_ID="${MOBILELAB_STATION_ID:-lab01}" \
    "${VENV_PY}" "$@"
}

echo "--- the local gauge and the salinity it drives ---"
run_py -m mobilelab.fixture \
  --seed "${SEED}" --hours "${HOURS}" --lag-hours "${LAG}" --start "${START}" 2>&1 | tail -6

echo
echo "--- the cell average that stands in for the public record ---"
run_py -m mobilelab.cellfixture \
  --seed "${SEED}" --hours "${HOURS}" --lag-hours "${LAG}" --start "${START}" --report 2>&1 | tail -12

echo
echo "--- letting the writer drain ---"
for _attempt in 1 2 3 4 5 6 7 8 9 10; do
  PENDING="$(runuser -u postgres -- psql -d "${DB_NAME}" -tAc \
    "select count(*) from public.readings where source = 'public_synthetic'")"
  if [ "${PENDING}" -ge "${HOURS}" ]; then
    break
  fi
  runuser -u postgres -- psql -d "${DB_NAME}" -tAc "select pg_sleep(2)" > /dev/null
done

echo
echo "--- refreshing the rollups, hard rule 14 ---"
runuser -u postgres -- psql -d "${DB_NAME}" -v ON_ERROR_STOP=1 <<SQL
call refresh_continuous_aggregate('public.readings_1m', null, null);
call refresh_continuous_aggregate('public.readings_1h', null, null);
SQL

echo
echo "--- what the rig now holds ---"
runuser -u postgres -- psql -d "${DB_NAME}" -c "
select source, sensor, metric, count(*) as rows,
       min(ts) as earliest, max(ts) as latest,
       round(extract(epoch from (max(ts) - min(ts))) / 3600.0) as span_hours
from public.readings
where source in ('synthetic', 'public_synthetic')
group by source, sensor, metric
order by source, sensor, metric;"

echo "done"
