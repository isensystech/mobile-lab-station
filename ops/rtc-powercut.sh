#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="/var/lib/mobilelab/rtc-powercut.json"
MODE="${1:-}"

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: run this script with sudo." >&2
  exit 1
fi

usage() {
  cat <<'EOF'
The RTC power cut test. Architecture section 9, hard rule 13.

WHAT IT PROVES

  Before the battery was fitted, a power cut set the clock to 1970-01-01. The
  kernel logged it on 2026-08-15. NTP repaired the clock, but only because a
  network was there. A field session has no network. Every reading taken after
  that power cut would carry a 1970 timestamp, and hard rule 13 would throw all
  of them away. The station would record nothing.

  The battery is fitted now. This script measures whether that is true, instead
  of assuming it.

HOW TO RUN IT

  sudo ops/rtc-powercut.sh before
      Records the clock and the RTC now. Tells you what to unplug.

  Then cut the power at the wall. Wait ten seconds. Power it back up with NO
  network reachable. Unplug the ethernet cable, or switch the router off.

  sudo ops/rtc-powercut.sh after
      Reads the clock on the way back up and compares it with the before run.
      Prints PASS or FAIL.

WHY THE NETWORK MUST BE ABSENT

  With a network, systemd-timesyncd repairs the clock within seconds of boot.
  The test would then pass with a dead battery and prove nothing at all. The
  absent network is the entire point of the test.
EOF
}

read_clock() {
  SYSTEM_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  SYSTEM_EPOCH="$(date +%s)"
  if HW_RAW="$(hwclock -r --utc 2>&1)"; then
    HW_EPOCH="$(date -u -d "$(hwclock -r --utc)" +%s 2>/dev/null || echo 0)"
  else
    HW_RAW="hwclock failed: ${HW_RAW}"
    HW_EPOCH=0
  fi
  RTC_NAME="$(cat /sys/class/rtc/rtc0/name 2>/dev/null || echo none)"
  NTP_SYNC="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo unknown)"
}

case "${MODE}" in
  before)
    mkdir -p "$(dirname "${STATE_FILE}")"
    read_clock
    cat > "${STATE_FILE}" <<EOF
{"system_utc":"${SYSTEM_UTC}","system_epoch":${SYSTEM_EPOCH},"rtc_name":"${RTC_NAME}"}
EOF
    echo "==> BEFORE THE POWER CUT"
    echo "    RTC device      ${RTC_NAME}"
    echo "    hwclock         ${HW_RAW}"
    echo "    system clock    ${SYSTEM_UTC}"
    echo "    NTP synced      ${NTP_SYNC}"
    echo "    saved to        ${STATE_FILE}"
    echo
    echo "==> NOW DO THIS, IN THIS ORDER"
    echo "    1. Unplug the ethernet cable, or switch the router off."
    echo "       The test is worthless with a network. timesyncd would repair"
    echo "       the clock and hide a dead battery."
    echo "    2. Cut the power at the wall. Do NOT shut down cleanly. A clean"
    echo "       shutdown writes the clock to the RTC, which is the thing under"
    echo "       test. Pull the plug."
    echo "    3. Wait sixty seconds. A capacitor holds a short cut."
    echo "    4. Power it back up. Leave the network off."
    echo "    5. Run: sudo ops/rtc-powercut.sh after"
    ;;

  after)
    if [ ! -f "${STATE_FILE}" ]; then
      echo "ERROR: no before run found at ${STATE_FILE}." >&2
      echo "Run 'sudo ops/rtc-powercut.sh before' first." >&2
      exit 1
    fi
    read_clock
    BEFORE_EPOCH="$(python3 -c "import json;print(json.load(open('${STATE_FILE}'))['system_epoch'])")"
    BEFORE_UTC="$(python3 -c "import json;print(json.load(open('${STATE_FILE}'))['system_utc'])")"

    echo "==> AFTER THE POWER CUT"
    echo "    RTC device      ${RTC_NAME}"
    echo "    hwclock         ${HW_RAW}"
    echo "    system clock    ${SYSTEM_UTC}"
    echo "    NTP synced      ${NTP_SYNC}"
    echo "    before the cut  ${BEFORE_UTC}"
    echo
    echo "==> BOOT EVIDENCE"
    journalctl -b 0 --no-pager 2>/dev/null \
      | grep -iE "setting system clock|rtc_cmos|rpi-rtc|hctosys|RTC time" \
      | head -8 | sed 's/^/    /' || echo "    no clock lines in this boot"
    echo
    echo "==> ROUTE CHECK"
    if ip route show default 2>/dev/null | grep -q .; then
      echo "    WARNING: a default route exists. The network was NOT absent."
      ip route show default | sed 's/^/      /'
      echo "    This run does not prove the RTC held. Repeat with no network."
    else
      echo "    no default route. The network was absent, as the test requires."
    fi
    echo

    if [ "${NTP_SYNC}" = "yes" ]; then
      echo "==> WARNING: the clock is NTP synchronized already."
      echo "    A time server may have repaired it before this ran. Read the"
      echo "    boot evidence above before you believe the verdict."
    fi

    YEAR="$(date -u +%Y)"
    DRIFT=$(( SYSTEM_EPOCH - BEFORE_EPOCH ))

    echo "==> VERDICT"
    echo "    the clock reads year ${YEAR}"
    echo "    it moved ${DRIFT} seconds since the before run"
    if [ "${YEAR}" -lt 2026 ]; then
      echo "    FAIL. The clock went backwards past 2026. This is the 1970 case."
      echo "    Hard rule 13 will reject every reading. Check the RTC battery."
      exit 1
    fi
    if [ "${DRIFT}" -lt 0 ]; then
      echo "    FAIL. The clock went backwards. The RTC did not hold."
      exit 1
    fi
    echo "    PASS. The RTC held the time across the power cut."
    ;;

  *)
    usage
    exit 1
    ;;
esac
