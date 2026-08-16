#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: run this script with sudo." >&2
  exit 1
fi

if [ ! -f "${REPO_ROOT}/.env" ]; then
  echo "ERROR: ${REPO_ROOT}/.env does not exist." >&2
  echo "  Copy .env.example to .env. Then set MOBILELAB_DB_PASSWORD." >&2
  exit 1
fi

set -a
. "${REPO_ROOT}/.env"
set +a

DB_NAME="${MOBILELAB_DB:-mobilelab}"
DB_USER="${MOBILELAB_DB_USER:-mobilelab}"
STATION_ID="${MOBILELAB_STATION_ID:-lab01}"
STATION_LABEL="${MOBILELAB_STATION_LABEL:-Mobile Lab Station}"

if [ -z "${MOBILELAB_DB_PASSWORD:-}" ]; then
  echo "ERROR: MOBILELAB_DB_PASSWORD is empty in .env." >&2
  exit 1
fi

if [ "${DB_USER}" != "mobilelab" ]; then
  echo "ERROR: migration 0009 grants to the role named mobilelab." >&2
  echo "  MOBILELAB_DB_USER is ${DB_USER}. Set it back to mobilelab." >&2
  exit 1
fi

psql_super() {
  runuser -u postgres -- psql -v ON_ERROR_STOP=1 "$@"
}

role_exists="$(psql_super -q -t -A -d postgres \
  -c "select 1 from pg_roles where rolname = '${DB_USER}'" | tr -d '[:space:]')"

if [ "${role_exists}" = "1" ]; then
  echo "role ${DB_USER} exists, updating the password"
  psql_super -q -d postgres \
    -c "alter role ${DB_USER} with login password '${MOBILELAB_DB_PASSWORD}'"
else
  echo "creating role ${DB_USER}"
  psql_super -q -d postgres \
    -c "create role ${DB_USER} with login password '${MOBILELAB_DB_PASSWORD}'"
fi

db_exists="$(psql_super -q -t -A -d postgres \
  -c "select 1 from pg_database where datname = '${DB_NAME}'" | tr -d '[:space:]')"

if [ "${db_exists}" = "1" ]; then
  echo "database ${DB_NAME} exists"
else
  echo "creating database ${DB_NAME}"
  psql_super -q -d postgres -c "create database ${DB_NAME}"
fi

echo "seeding station ${STATION_ID}"
psql_super -q -d "${DB_NAME}" -c "
  insert into public.stations (station_id, label)
  values ('${STATION_ID}', '${STATION_LABEL}')
  on conflict (station_id) do nothing;" 2> /dev/null \
  || echo "  station table not made yet, run db/migrate.sh then run this script again"

echo "bootstrap done"
