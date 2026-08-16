#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: run this script with sudo." >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

echo "==> installing Mosquitto from the Debian repository"
apt-get update -qq
apt-get install -y -qq mosquitto mosquitto-clients

echo "==> installed versions"
dpkg-query -W -f='${Package} ${Version}\n' mosquitto mosquitto-clients

echo "==> installing the station configuration"
install -m 0644 \
  "${REPO_ROOT}/mosquitto/conf.d/mobilelab.conf" \
  /etc/mosquitto/conf.d/mobilelab.conf

echo "==> enabling and restarting Mosquitto"
systemctl enable mosquitto
systemctl restart mosquitto

echo "==> listeners"
ss -lntp 2> /dev/null | grep -E '1883' || echo "  no listener on 1883 yet"

echo "==> done"
