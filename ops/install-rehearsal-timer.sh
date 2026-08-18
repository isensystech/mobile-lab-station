#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MODE="${1:-install}"

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: run this script with sudo." >&2
  exit 1
fi

if [ "${MODE}" = "remove" ]; then
  systemctl disable --now mobilelab-rehearsal-seed.timer > /dev/null 2>&1 || true
  rm -f /etc/systemd/system/mobilelab-rehearsal-seed.timer
  rm -f /etc/systemd/system/mobilelab-rehearsal-seed.service
  systemctl daemon-reload
  echo "==> removed. The chart keeps whatever data it holds and then goes stale."
  exit 0
fi

echo "==> what this installs"
echo "    A timer that reseeds the rehearsal fixture every hour."
echo "    It touches wlan0 and the network stack in no way at all."
echo
echo "==> WHY A TIMER AND NOT A SERVICE"
echo "    mobilelab-fixture.service has no [Install] section on purpose. A"
echo "    fixture must never start at boot and never run continuously. A"
echo "    long running generator that keeps writing rows looks exactly like a"
echo "    live sensor, and hard rule 3 exists to stop that."
echo "    A timer is different. It runs, it finishes, and it is visible in"
echo "    systemctl list-timers. Anybody can see it and stop it."
echo
echo "    ops/seed-rehearsal.sh DELETES the synthetic rows and writes them"
echo "    again, so repeating it is safe. It refreshes the rollups every"
echo "    time, which hard rule 14 requires for backdated writes."
echo
echo "==> WHAT IT DOES NOT CHANGE"
echo "    Manual readings. It only removes source synthetic and"
echo "    public_synthetic. A student entry is never touched."
echo "    The SIMULATED badge. Every row it writes stays is_real false and"
echo "    draws dashed or stepped."

install -m 0644 "${SCRIPT_DIR}/systemd/mobilelab-rehearsal-seed.service" /tmp/rs.service
sed -i "s|__REPO_ROOT__|${REPO_ROOT}|g" /tmp/rs.service
install -m 0644 /tmp/rs.service /etc/systemd/system/mobilelab-rehearsal-seed.service
rm -f /tmp/rs.service

install -m 0644 "${SCRIPT_DIR}/systemd/mobilelab-rehearsal-seed.timer" /tmp/rs.timer
sed -i "s|__REPO_ROOT__|${REPO_ROOT}|g" /tmp/rs.timer
install -m 0644 /tmp/rs.timer /etc/systemd/system/mobilelab-rehearsal-seed.timer
rm -f /tmp/rs.timer

systemctl daemon-reload
systemctl enable --now mobilelab-rehearsal-seed.timer > /dev/null
echo
echo "==> installed and started"
systemctl list-timers mobilelab-rehearsal-seed.timer --no-pager | head -3
echo
echo "==> remove it with"
echo "    sudo ops/install-rehearsal-timer.sh remove"
