#!/usr/bin/env bash
set -uo pipefail

: <<'ABOUT'
Copies the station dumps off the Raspberry Pi.

THIS SCRIPT RUNS ON THE OPERATOR LAPTOP. It does not run on the Pi.

It pulls. The Pi does not push. A push needs a key on the Pi that opens the
laptop, and the Pi goes into the field. A stolen Pi would then carry a way into
the laptop. A pull needs no key on the Pi and no open port on the laptop.

The job fails loudly. If the Pi does not answer, or a checksum does not match,
the script exits non zero and writes an error. It never exits quietly.
ABOUT

RSYNC_BIN="${MOBILELAB_RSYNC:-rsync}"

PI_USER="${MOBILELAB_PI_USER:-scott}"
PI_HOST="${MOBILELAB_PI_HOST:-192.168.1.123}"
REMOTE_DIR="${MOBILELAB_BACKUP_DIR:-/var/backups/mobilelab}"
LOCAL_DIR="${MOBILELAB_OFFBOX_DIR:-${HOME}/mobile-lab-backups}"
STALE_DAYS="${MOBILELAB_OFFBOX_STALE_DAYS:-3}"

STAMP_FILE="${LOCAL_DIR}/.last-success"
LOG_FILE="${LOCAL_DIR}/pull.log"
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new"

mkdir -p "${LOCAL_DIR}"

now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

say() {
  echo "$(now) $1" | tee -a "${LOG_FILE}"
}

die() {
  echo "$(now) ERROR $1" | tee -a "${LOG_FILE}" >&2
  osascript -e "display notification \"$1\" with title \"Mobile Lab backup FAILED\"" > /dev/null 2>&1 || true
  exit 1
}

say "starting a pull from ${PI_USER}@${PI_HOST}:${REMOTE_DIR}"

if ! ssh ${SSH_OPTS} "${PI_USER}@${PI_HOST}" true > /dev/null 2>&1; then
  die "the station did not answer at ${PI_HOST}. No copy was made."
fi

REMOTE_LIST="$(ssh ${SSH_OPTS} "${PI_USER}@${PI_HOST}" "ls -1 ${REMOTE_DIR}/*.dump 2> /dev/null" || true)"
if [ -z "${REMOTE_LIST}" ]; then
  die "the station holds no dump files in ${REMOTE_DIR}."
fi

REMOTE_COUNT="$(echo "${REMOTE_LIST}" | wc -l | tr -d ' ')"
say "the station holds ${REMOTE_COUNT} dump files"

if ! "${RSYNC_BIN}" -a --stats \
     -e "ssh ${SSH_OPTS}" \
     "${PI_USER}@${PI_HOST}:${REMOTE_DIR}/*.dump" \
     "${LOCAL_DIR}/" >> "${LOG_FILE}" 2>&1; then
  die "rsync did not finish. See ${LOG_FILE}."
fi

NEWEST="$(echo "${REMOTE_LIST}" | tail -1)"
NEWEST_BASE="$(basename "${NEWEST}")"

REMOTE_SUM="$(ssh ${SSH_OPTS} "${PI_USER}@${PI_HOST}" "sha256sum ${NEWEST}" 2> /dev/null | awk '{print $1}')"
LOCAL_SUM="$(shasum -a 256 "${LOCAL_DIR}/${NEWEST_BASE}" 2> /dev/null | awk '{print $1}')"

if [ -z "${REMOTE_SUM}" ] || [ -z "${LOCAL_SUM}" ]; then
  die "a checksum could not be read for ${NEWEST_BASE}."
fi

if [ "${REMOTE_SUM}" != "${LOCAL_SUM}" ]; then
  die "the checksum does not match for ${NEWEST_BASE}. station ${REMOTE_SUM}, here ${LOCAL_SUM}."
fi

LOCAL_COUNT="$(find "${LOCAL_DIR}" -name '*.dump' -type f | wc -l | tr -d ' ')"
NEWEST_SIZE="$(wc -c < "${LOCAL_DIR}/${NEWEST_BASE}" | tr -d ' ')"

say "newest ${NEWEST_BASE}, ${NEWEST_SIZE} bytes, checksum matches"
say "the laptop now holds ${LOCAL_COUNT} dump files in ${LOCAL_DIR}"
now > "${STAMP_FILE}"

if [ -f "${STAMP_FILE}" ]; then
  AGE_DAYS="$(find "${STAMP_FILE}" -mtime "+${STALE_DAYS}" | wc -l | tr -d ' ')"
  if [ "${AGE_DAYS}" != "0" ]; then
    say "WARNING the last good pull is more than ${STALE_DAYS} days old"
  fi
fi

say "done"
