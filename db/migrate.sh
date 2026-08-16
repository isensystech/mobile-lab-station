#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MIGRATION_DIR="${SCRIPT_DIR}/migrations"

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: run this script with sudo." >&2
  echo "  sudo ${BASH_SOURCE[0]}" >&2
  exit 1
fi

if [ -f "${REPO_ROOT}/.env" ]; then
  set -a
  . "${REPO_ROOT}/.env"
  set +a
fi

DB_NAME="${MOBILELAB_DB:-mobilelab}"

psql_db() {
  runuser -u postgres -- psql -v ON_ERROR_STOP=1 -d "${DB_NAME}" "$@"
}

psql_quiet() {
  psql_db -q -t -A "$@"
}

checksum_of() {
  sha256sum "$1" | cut -d' ' -f1
}

psql_quiet -c "
create table if not exists public.schema_migrations (
  version    text primary key,
  checksum   text not null,
  applied_at timestamptz not null default now()
);" > /dev/null

applied_count=0
skipped_count=0

shopt -s nullglob
for path in "${MIGRATION_DIR}"/[0-9]*.sql; do
  version="$(basename "${path}" .sql)"
  checksum="$(checksum_of "${path}")"

  recorded="$(psql_quiet -c "select checksum from public.schema_migrations where version = '${version}'" | tr -d '[:space:]')"

  if [ -n "${recorded}" ]; then
    if [ "${recorded}" != "${checksum}" ]; then
      echo "ERROR: ${version} changed after it was applied." >&2
      echo "  recorded ${recorded}" >&2
      echo "  on disk  ${checksum}" >&2
      echo "  An applied migration is immutable. Write a new numbered file." >&2
      exit 1
    fi
    echo "skip   ${version}"
    skipped_count=$((skipped_count + 1))
    continue
  fi

  if head -3 "${path}" | grep -q 'migrate:no-transaction'; then
    echo "apply  ${version}  (outside a transaction)"
    psql_db -q < "${path}"
  else
    echo "apply  ${version}"
    psql_db -q --single-transaction < "${path}"
  fi

  psql_quiet -c "insert into public.schema_migrations (version, checksum)
                 values ('${version}', '${checksum}')" > /dev/null
  applied_count=$((applied_count + 1))
done
shopt -u nullglob

echo
echo "applied ${applied_count}, skipped ${skipped_count}"
echo "database ${DB_NAME}"
