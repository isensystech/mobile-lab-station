#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VENV="${REPO_ROOT}/.venv"
SERVICE_USER="mobilelab"

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: run this script with sudo." >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

echo "==> installing the Python build prerequisites"
apt-get update -qq
apt-get install -y -qq python3-venv python3-pip

if id -u "${SERVICE_USER}" > /dev/null 2>&1; then
  echo "==> the system user ${SERVICE_USER} exists"
else
  echo "==> creating the system user ${SERVICE_USER}"
  adduser --system --group --no-create-home \
    --shell /usr/sbin/nologin "${SERVICE_USER}"
fi

echo "==> building the virtual environment at ${VENV}"
if [ ! -x "${VENV}/bin/python" ]; then
  python3 -m venv "${VENV}"
fi
"${VENV}/bin/python" -m pip install --quiet --upgrade pip
"${VENV}/bin/python" -m pip install --quiet -r "${REPO_ROOT}/services/requirements.txt"

echo "==> installed Python packages"
"${VENV}/bin/python" -m pip list --format=columns \
  | grep -Ei 'paho|psycopg|pydantic|^Package|^-' || true

echo "==> letting the service user read .env"
if [ -f "${REPO_ROOT}/.env" ]; then
  chown scott:"${SERVICE_USER}" "${REPO_ROOT}/.env"
  chmod 0640 "${REPO_ROOT}/.env"
  ls -l "${REPO_ROOT}/.env"
else
  echo "ERROR: ${REPO_ROOT}/.env does not exist." >&2
  exit 1
fi

echo "==> letting the service user read the code"
chmod -R a+rX "${REPO_ROOT}/services" "${VENV}"

echo "==> installing the systemd units"
for unit in mobilelab-writer.service mobilelab-fixture.service mobilelab-api.service \
            mobilelab-bridge.service; do
  sed "s|__REPO_ROOT__|${REPO_ROOT}|g" \
    "${SCRIPT_DIR}/systemd/${unit}" > "/etc/systemd/system/${unit}"
  chmod 0644 "/etc/systemd/system/${unit}"
  echo "  ${unit}"
done

systemctl daemon-reload

echo "==> enabling and restarting the writer"
systemctl enable mobilelab-writer.service
systemctl restart mobilelab-writer.service

echo "==> enabling and restarting the API"
systemctl enable mobilelab-api.service
systemctl restart mobilelab-api.service

echo "==> enabling and restarting the WQL bridge"
systemctl enable mobilelab-bridge.service
systemctl restart mobilelab-bridge.service
sleep 5

for unit in mobilelab-writer mobilelab-api mobilelab-bridge; do
  echo "==> ${unit} status"
  systemctl status "${unit}.service" --no-pager 2>&1 | head -8
  echo
done

echo "==> the API is listening here"
ss -lntp 2> /dev/null | grep -E ":${MOBILELAB_API_PORT:-8000}" || echo "  no listener found"

echo "==> the fixture unit is installed but never enabled"
systemctl is-enabled mobilelab-fixture.service 2>&1 || true

echo "==> done"
