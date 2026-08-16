#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: run this script with sudo." >&2
  exit 1
fi

if [ -f "${REPO_ROOT}/.env" ]; then
  set -a
  . "${REPO_ROOT}/.env"
  set +a
fi

LIVE_DB="${MOBILELAB_DB:-mobilelab}"
SCRATCH_DB="${MOBILELAB_RESTORE_DB:-mobilelab_restore_check}"
DUMP="${1:-}"

if [ -z "${DUMP}" ]; then
  echo "usage: restore-check.sh /path/to/file.dump" >&2
  exit 1
fi

if [ ! -s "${DUMP}" ]; then
  echo "ERROR: ${DUMP} is missing or empty." >&2
  exit 1
fi

if [ "${SCRATCH_DB}" = "${LIVE_DB}" ]; then
  echo "ERROR: the scratch database has the same name as the live database." >&2
  echo "  live    ${LIVE_DB}" >&2
  echo "  scratch ${SCRATCH_DB}" >&2
  echo "  This script must never restore over the live database." >&2
  exit 1
fi

case "${SCRATCH_DB}" in
  *restore_check*|*scratch*) : ;;
  *)
    echo "ERROR: the scratch database name must contain restore_check or scratch." >&2
    echo "  It guards against a typo that points this script at real data." >&2
    exit 1
    ;;
esac

RULE="======================================================================"
LOG="$(mktemp /tmp/restore-check-XXXXXX.log)"

pg() {
  runuser -u postgres -- psql -v ON_ERROR_STOP=1 -tAc "$1" "${@:2}"
}

pgd() {
  runuser -u postgres -- psql -d "${SCRATCH_DB}" -v ON_ERROR_STOP=1 -tAc "$1"
}

echo "${RULE}"
echo " RESTORE CHECK"
echo "${RULE}"
echo "  dump        ${DUMP}"
echo "  size        $(stat -c %s "${DUMP}") bytes"
echo "  sha256      $(sha256sum "${DUMP}" | awk '{print $1}')"
echo "  live db     ${LIVE_DB}   NEVER written by this script"
echo "  scratch db  ${SCRATCH_DB}"
echo

echo "--- live database, for comparison ---"
for t in readings observations dives; do
  echo "  ${t}=$(runuser -u postgres -- psql -d "${LIVE_DB}" -tAc "select count(*) from public.${t}")"
done
echo

echo "--- making the scratch database ---"
runuser -u postgres -- dropdb --if-exists "${SCRATCH_DB}"
runuser -u postgres -- createdb "${SCRATCH_DB}"
pgd "create extension if not exists timescaledb" > /dev/null
echo "  timescaledb $(pgd "select extversion from pg_extension where extname = 'timescaledb'") in ${SCRATCH_DB}"
echo

echo "--- timescaledb_pre_restore ---"
pgd "select timescaledb_pre_restore()" > /dev/null
echo "  done"
echo

STAGED="$(mktemp /tmp/restore-stage-XXXXXX.dump)"
cp "${DUMP}" "${STAGED}"
chown postgres:postgres "${STAGED}"
chmod 0400 "${STAGED}"
echo "--- staged a readable copy for the postgres user ---"
echo "  the backup file itself stays 0640 root, so this does not weaken it"
echo "  staged ${STAGED}"
echo "  sha256 $(sha256sum "${STAGED}" | awk '{print $1}')"
echo

echo "${RULE}"
echo " pg_restore OUTPUT, VERBATIM"
echo "${RULE}"
set +e
runuser -u postgres -- pg_restore \
  --dbname="${SCRATCH_DB}" \
  --verbose \
  "${STAGED}" > "${LOG}" 2>&1
RESTORE_RC=$?
rm -f "${STAGED}"
grep -E "^pg_restore: (error|warning)" "${LOG}" | sed 's/^/  /' || echo "  none"
ERR_COUNT="$(grep -c "^pg_restore: error" "${LOG}" || true)"
WARN_COUNT="$(grep -c "^pg_restore: warning" "${LOG}" || true)"
echo
echo "  pg_restore exit code ${RESTORE_RC}"
echo "  errors ${ERR_COUNT}, warnings ${WARN_COUNT}"
echo "  full log kept at ${LOG}"
echo

echo "--- timescaledb_post_restore ---"
pgd "select timescaledb_post_restore()" > /dev/null
echo "  done"
echo

echo "${RULE}"
echo " CLASSIFY EVERY ERROR"
echo "${RULE}"
echo "  An error naming _timescaledb_catalog or the extension itself is the"
echo "  known benign case. An error naming readings, observations, dives, or"
echo "  stations is NOT benign."
echo
NOT_BENIGN="$(grep "^pg_restore: error" "${LOG}" 2> /dev/null | grep -cE "readings|observations|dives|stations" || true)"
echo "  errors touching real tables: ${NOT_BENIGN}"
if [ "${NOT_BENIGN}" -gt 0 ]; then
  echo "  THESE ARE NOT BENIGN:"
  grep "^pg_restore: error" "${LOG}" | grep -E "readings|observations|dives|stations" | sed 's/^/    /' || true
fi
echo

echo "${RULE}"
echo " ROW COUNTS IN THE RESTORED DATABASE"
echo "${RULE}"
for t in readings observations dives stations; do
  LIVE="$(runuser -u postgres -- psql -d "${LIVE_DB}" -tAc "select count(*) from public.${t}" 2> /dev/null)"
  REST="$(pgd "select count(*) from public.${t}" 2> /dev/null)"
  if [ "${LIVE}" = "${REST}" ]; then MATCH="match"; else MATCH="DIFFERENT"; fi
  printf "  %-14s live %-8s restored %-8s %s\n" "${t}" "${LIVE}" "${REST}" "${MATCH}"
done
echo

echo "${RULE}"
echo " CONTINUOUS AGGREGATES AFTER RESTORE"
echo "${RULE}"
echo "  Two numbers per rollup, and they are not the same question."
echo
echo "  VIEW returns    what the chart would see. These rollups are real time,"
echo "                  so this number can include buckets computed on the fly"
echo "                  from the raw table. It can look healthy while nothing"
echo "                  was actually restored."
echo "  MATERIALIZED    rows that truly came back in the dump. This is the"
echo "                  number that says whether the backup carried the rollup."
echo
for v in readings_1m readings_1h; do
  MAT_SCHEMA="$(pgd "select materialization_hypertable_schema from timescaledb_information.continuous_aggregates where view_name = '${v}'")"
  MAT_TABLE="$(pgd "select materialization_hypertable_name from timescaledb_information.continuous_aggregates where view_name = '${v}'")"
  VIEW_ROWS="$(pgd "select count(*) from public.${v}" 2> /dev/null)"
  if [ -n "${MAT_TABLE}" ]; then
    MAT_ROWS="$(pgd "select count(*) from ${MAT_SCHEMA}.${MAT_TABLE}" 2> /dev/null)"
  else
    MAT_ROWS="no such view"
  fi
  LIVE_MS="$(runuser -u postgres -- psql -d "${LIVE_DB}" -tAc "select materialization_hypertable_schema from timescaledb_information.continuous_aggregates where view_name = '${v}'" 2> /dev/null)"
  LIVE_MT="$(runuser -u postgres -- psql -d "${LIVE_DB}" -tAc "select materialization_hypertable_name from timescaledb_information.continuous_aggregates where view_name = '${v}'" 2> /dev/null)"
  LIVE_MAT="$(runuser -u postgres -- psql -d "${LIVE_DB}" -tAc "select count(*) from ${LIVE_MS}.${LIVE_MT}" 2> /dev/null)"
  echo "  ${v}"
  echo "    view returns          ${VIEW_ROWS}"
  echo "    materialized restored ${MAT_ROWS}"
  echo "    materialized live     ${LIVE_MAT}"
done
echo

echo "${RULE}"
echo " DECISIVE ROLLUP PROOF"
echo "${RULE}"
echo "  A row count alone cannot answer the question. These rollups are real"
echo "  time, so the view adds buckets computed from the raw table while you"
echo "  look at it. A rollup that restored EMPTY would still show numbers."
echo
echo "  So this does two things to the SCRATCH copy only."
echo "    1. It sets materialized_only, so the view stops computing on the fly."
echo "    2. It deletes every raw reading."
echo "  Whatever the view still returns can only have come from the dump."
echo
for v in readings_1m readings_1h; do
  pgd "alter materialized view public.${v} set (timescaledb.materialized_only = true)" > /dev/null 2>&1
done
BEFORE_1M="$(pgd "select count(*) from public.readings_1m" 2> /dev/null)"
BEFORE_1H="$(pgd "select count(*) from public.readings_1h" 2> /dev/null)"
pgd "truncate public.readings cascade" > /dev/null 2>&1
RAW_LEFT="$(pgd "select count(*) from public.readings" 2> /dev/null)"
AFTER_1M="$(pgd "select count(*) from public.readings_1m" 2> /dev/null)"
AFTER_1H="$(pgd "select count(*) from public.readings_1h" 2> /dev/null)"
SAMPLE="$(pgd "select bucket || ' ' || sensor || ' ' || metric || ' avg ' || round(avg_value::numeric, 3) from public.readings_1h order by bucket limit 1" 2> /dev/null)"
echo "  raw readings left in the scratch copy: ${RAW_LEFT}"
echo "  readings_1m  materialized only, before wipe ${BEFORE_1M}, after wipe ${AFTER_1M}"
echo "  readings_1h  materialized only, before wipe ${BEFORE_1H}, after wipe ${AFTER_1H}"
echo "  oldest surviving bucket: ${SAMPLE}"
echo
if [ "${RAW_LEFT}" = "0" ] && [ "${AFTER_1H}" -gt 0 ] 2> /dev/null; then
  echo "  VERDICT: the rollups SURVIVE the restore with real materialized data."
  echo "  They answered with every raw reading deleted, so the numbers came"
  echo "  from the dump and not from live computation."
else
  echo "  VERDICT: the rollups came back EMPTY. A restored station shows"
  echo "  nothing on the chart until the rollups are rebuilt."
fi
echo

echo "--- refresh policies after restore ---"
pgd "select count(*) from timescaledb_information.jobs where application_name like 'Refresh Continuous Aggregate%'" | sed 's/^/  policies restored: /'
echo

echo "${RULE}"
echo " DROPPING THE SCRATCH DATABASE"
echo "${RULE}"
runuser -u postgres -- dropdb --if-exists "${SCRATCH_DB}"
STILL="$(pg "select count(*) from pg_database where datname = '${SCRATCH_DB}'")"
echo "  ${SCRATCH_DB} still present: ${STILL}"
echo "  live database untouched: $(runuser -u postgres -- psql -d "${LIVE_DB}" -tAc "select count(*) from public.readings") readings"
echo
echo "done"
