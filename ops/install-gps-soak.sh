#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

UNIT="mobilelab-gps-soak.service"
MARKER="/var/lib/mobilelab/gps-soak.done"
OUTDIR="/var/log/mobilelab/gps-soak"
MODE="${1:-arm}"

unit_enabled() {
  local state
  state="$(systemctl is-enabled "$1" 2>/dev/null | head -1)"
  if [ -z "${state}" ]; then state="not-installed"; fi
  echo "${state}"
}

unit_active() {
  local state
  state="$(systemctl is-active "$1" 2>/dev/null | head -1)"
  if [ -z "${state}" ]; then state="unknown"; fi
  echo "${state}"
}

show_state() {
  echo "    unit file    $(unit_enabled ${UNIT})"
  echo "    marker       $( [ -f "${MARKER}" ] && echo "present, the soak will NOT fire" || echo "absent, the soak WILL fire" )"
  echo "    report       $( [ -f "${OUTDIR}/report.txt" ] && echo "${OUTDIR}/report.txt" || echo "none yet" )"
}

case "${MODE}" in
  status)
    echo "==> GPS soak state"
    show_state
    exit 0
    ;;

  disarm)
    if [ "$(id -u)" -ne 0 ]; then
      echo "ERROR: run this script with sudo to disarm the soak." >&2
      exit 1
    fi
    echo "==> disarming the soak"
    systemctl disable "${UNIT}" > /dev/null 2>&1 || true
    mkdir -p "$(dirname "${MARKER}")"
    touch "${MARKER}"
    echo "    the soak will not fire on the next boot"
    show_state
    exit 0
    ;;

  arm)
    if [ "$(id -u)" -ne 0 ]; then
      echo "ERROR: run this script with sudo to arm the soak." >&2
      echo "  sudo ops/install-gps-soak.sh" >&2
      exit 1
    fi
    ;;

  *)
    echo "usage: sudo ops/install-gps-soak.sh [arm|disarm|status]" >&2
    exit 2
    ;;
esac

echo "==> what this script does NOT touch"
echo "    wlan0, hostapd, dnsmasq, NetworkManager, dhcpcd, iptables, ufw."
echo "    It changes no mobilelab service and no application code."
echo "    It installs one unit that runs once and then removes itself."
echo

echo "==> checking what the soak needs"
if [ ! -x "${SCRIPT_DIR}/gps-soak.sh" ]; then
  echo "    ERROR: ${SCRIPT_DIR}/gps-soak.sh is missing or not executable." >&2
  exit 1
fi
if ! command -v python3 > /dev/null 2>&1; then
  echo "    ERROR: python3 is missing." >&2
  exit 1
fi
echo "    python3      $(python3 --version 2>&1)"
if [ -e /dev/mobilelab-gps ]; then
  echo "    receiver     /dev/mobilelab-gps -> $(readlink -f /dev/mobilelab-gps)"
else
  echo "    receiver     MISSING. /dev/mobilelab-gps is not there right now."
  echo "                 The soak waits 60 seconds for it at boot and then"
  echo "                 records the hole. Plug the dongle in before you reboot."
fi
if systemctl cat mobilelab-gpsrelay.service > /dev/null 2>&1; then
  echo "    relay        $(systemctl is-active mobilelab-gpsrelay.service)"
else
  echo "    relay        NOT INSTALLED. Run ops/install-gps.sh first." >&2
  exit 1
fi
if ! command -v fuser > /dev/null 2>&1; then
  echo "    fuser        missing. The report cannot name other port holders."
fi

echo
echo "==> the confound this soak exists to remove"
if systemctl cat weather-collector.service > /dev/null 2>&1; then
  WC_ACTIVE="$(unit_active weather-collector.service)"
  WC_ENABLED="$(unit_enabled weather-collector.service)"
  echo "    weather-collector.service is ${WC_ACTIVE}, ${WC_ENABLED}"
  if [ "${WC_ACTIVE}" = "active" ]; then
    echo "    STOP. It is running. It writes Modbus frames into the same port"
    echo "    every two seconds. The soak would measure the confound again."
    echo "    Stop it first, then run this script again:"
    echo "      sudo systemctl stop weather-collector.service"
    exit 1
  fi
  echo
  echo "    DISABLED IS NOT ENOUGH ON THIS BOX. Measured here 2026-08-17:"
  echo "    weather-collector was disabled and it started anyway, eleven"
  echo "    seconds after the dongle enumerated. Another unit requires it."
  REQBY="$(systemctl show weather-collector.service -p RequiredBy --value 2>/dev/null)"
  WANTBY="$(systemctl show weather-collector.service -p WantedBy --value 2>/dev/null)"
  echo "      RequiredBy   ${REQBY:-nothing}"
  echo "      WantedBy     ${WANTBY:-nothing}"
  for puller in ${REQBY} ${WANTBY}; do
    echo "      ${puller} is $(unit_active "${puller}"), $(unit_enabled "${puller}")"
  done
  echo
  echo "    THE SOAK FIRES ON BOOT. weather-collector also starts on boot."
  echo "    Stopping it now does NOT keep it away from the run that matters."
  echo "    MASK IT, which blocks it whatever tries to start it:"
  echo "      sudo systemctl mask weather-collector.service"
  echo "    Undo it later with unmask. While it is masked, any unit that"
  echo "    requires it will fail to start. That is the cost, and it is yours"
  echo "    to accept. This script will not mask anything for you."
  echo
  if [ "$(systemctl is-enabled weather-collector.service 2>/dev/null | head -1)" = "masked" ]; then
    echo "    It is already masked. It cannot come back at boot."
  else
    echo "    IT IS NOT MASKED. The soak REFUSES to measure if it finds"
    echo "    weather-collector running at boot, and it keeps its one shot."
    echo "    So an unmasked box costs you a reboot, not the measurement."
  fi
else
  echo "    weather-collector.service is not on this box at all"
fi

echo
echo "==> installing the one shot unit"
mkdir -p "${OUTDIR}" "$(dirname "${MARKER}")"
chmod 0755 "${OUTDIR}"
sed "s|__REPO_ROOT__|${REPO_ROOT}|g" \
  "${SCRIPT_DIR}/systemd/${UNIT}" > "/etc/systemd/system/${UNIT}"
chmod 0644 "/etc/systemd/system/${UNIT}"
systemctl daemon-reload
echo "    /etc/systemd/system/${UNIT}"

echo
echo "==> arming it"
rm -f "${MARKER}"
systemctl enable "${UNIT}" > /dev/null 2>&1
echo "    the marker is removed and the unit is enabled"

echo
echo "==> HOW IT STOPS ITSELF"
echo "    Two guards, and either one is enough."
echo "    1. The script writes ${MARKER}"
echo "       and runs systemctl disable BEFORE it measures anything."
echo "    2. The unit carries ConditionPathExists=!${MARKER}"
echo "       so systemd skips it while that file exists."
echo "    It disarms FIRST, not last. A power cut in minute 12 must not leave"
echo "    the soak armed for the next boot. One shot means one attempt."

echo
echo "==> WHAT HAPPENS ON THE NEXT BOOT"
echo "    1. The soak waits for /dev/mobilelab-gps."
echo "    2. It stops mobilelab-gpsrelay to take the port. STOPPED, not"
echo "       disabled. The GPS badge goes red for 25 minutes. That is expected."
echo "    3. It measures for 25 minutes."
echo "    4. It starts mobilelab-gpsrelay again and proves it in the report."
echo "       The unit restarts the relay a second time from ExecStopPost, so a"
echo "       crash or a timeout still gives the port back."
echo "    5. It writes ${OUTDIR}/report.txt"

echo
echo "==> READ THE REPORT WITH"
echo "    ops/gps-soak-report.sh"
echo
echo "==> REHEARSE IT WITHOUT BURNING THE ONE SHOT"
echo "    sudo ops/gps-soak.sh --smoke"
echo "    Two buckets of 20 seconds, into a separate folder. It does not disarm."
echo
echo "==> CANCEL IT WITH"
echo "    sudo ops/install-gps-soak.sh disarm"
echo
show_state
