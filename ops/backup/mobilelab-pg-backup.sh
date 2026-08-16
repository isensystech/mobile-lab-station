#!/usr/bin/env bash
set -euo pipefail

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

DB_NAME="${MOBILELAB_DB:-mobilelab}"
BACKUP_DIR="${MOBILELAB_BACKUP_DIR:-/var/backups/mobilelab}"
KEEP="${MOBILELAB_BACKUP_KEEP:-14}"

DATA_DIR="$(runuser -u postgres -- psql -t -A -c 'show data_directory')"

case "${BACKUP_DIR}/" in
  "${DATA_DIR}"/*)
    echo "ERROR: the backup directory is inside the PostgreSQL data directory." >&2
    echo "  backup ${BACKUP_DIR}" >&2
    echo "  data   ${DATA_DIR}" >&2
    echo "  A backup inside the data directory protects nothing." >&2
    exit 1
    ;;
esac

BACKUP_GROUP="${MOBILELAB_BACKUP_GROUP:-scott}"

mkdir -p "${BACKUP_DIR}"
chmod 0750 "${BACKUP_DIR}"

if getent group "${BACKUP_GROUP}" > /dev/null 2>&1; then
  chgrp "${BACKUP_GROUP}" "${BACKUP_DIR}"
  echo "==> the ${BACKUP_GROUP} group can read ${BACKUP_DIR}"
  echo "    An off box copy then needs no root on this machine."
else
  echo "WARNING: the group ${BACKUP_GROUP} does not exist." >&2
  echo "  The dumps stay root only. An off box copy will need sudo." >&2
fi

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
TARGET="${BACKUP_DIR}/${DB_NAME}-${STAMP}.dump"

echo "==> dumping ${DB_NAME} to ${TARGET}"

set -o pipefail
umask 0027
runuser -u postgres -- pg_dump \
  --format=custom \
  --compress=9 \
  "${DB_NAME}" > "${TARGET}"

chmod 0640 "${TARGET}"
if getent group "${BACKUP_GROUP}" > /dev/null 2>&1; then
  chgrp "${BACKUP_GROUP}" "${TARGET}"
fi

if [ ! -s "${TARGET}" ]; then
  echo "ERROR: the dump file is empty." >&2
  exit 1
fi

SIZE="$(stat -c %s "${TARGET}")"
echo "==> wrote ${TARGET}"
echo "==> size ${SIZE} bytes"

echo "==> removing dumps older than ${KEEP} days"
find "${BACKUP_DIR}" -name "${DB_NAME}-*.dump" -type f -mtime "+${KEEP}" -print -delete

echo "==> current dumps"
ls -lh "${BACKUP_DIR}"

echo "==> done"
