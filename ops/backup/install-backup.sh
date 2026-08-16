#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: run this script with sudo." >&2
  exit 1
fi

echo "==> installing the systemd units, repo root ${REPO_ROOT}"

sed "s|__REPO_ROOT__|${REPO_ROOT}|g" \
  "${SCRIPT_DIR}/mobilelab-backup.service" \
  > /etc/systemd/system/mobilelab-backup.service

install -m 0644 \
  "${SCRIPT_DIR}/mobilelab-backup.timer" \
  /etc/systemd/system/mobilelab-backup.timer

chmod 0644 /etc/systemd/system/mobilelab-backup.service
chmod 0755 "${SCRIPT_DIR}/mobilelab-pg-backup.sh"

systemctl daemon-reload
systemctl enable --now mobilelab-backup.timer

echo "==> timer status"
systemctl list-timers mobilelab-backup.timer --no-pager

echo "==> done"
