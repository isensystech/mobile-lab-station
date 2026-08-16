#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIOSK_USER="${MOBILELAB_KIOSK_USER:-planetwerx}"
KIOSK_UID="$(id -u "${KIOSK_USER}")"
RUNTIME="/run/user/${KIOSK_UID}"
PROFILE="$(getent passwd "${KIOSK_USER}" | cut -d: -f6)/.config/mobilelab-kiosk"
SHOT="/tmp/kiosk-boot-$(date +%s).ppm"

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: run this script with sudo." >&2
  exit 1
fi

as_kiosk() {
  runuser -u "${KIOSK_USER}" -- env XDG_RUNTIME_DIR="${RUNTIME}" WAYLAND_DISPLAY=wayland-0 "$@"
}

echo "uptime: $(uptime -p), booted $(uptime -s)"
echo "kiosk unit:  $(as_kiosk systemctl --user is-active mobilelab-kiosk.service 2>&1)"
echo "kiosk boot:  $(as_kiosk systemctl --user is-enabled mobilelab-kiosk.service 2>&1)"
MAIN_PID="$(as_kiosk systemctl --user show -p MainPID --value mobilelab-kiosk.service 2>/dev/null | tr -d '[:space:]')"
echo "chromium pid: ${MAIN_PID}"
echo "ssh:         $(systemctl is-active ssh), enabled $(systemctl is-enabled ssh)"
echo "api:         $(systemctl is-active mobilelab-api)"

echo
echo "--- the flags Chromium is actually running with ---"
tr '\0' ' ' < "/proc/${MAIN_PID}/cmdline" 2>/dev/null | tr ' ' '\n' \
  | grep -E "^--(kiosk|ozone-platform|no-first-run|no-default-browser-check|noerrdialogs|disable-infobars|disable-session-crashed-bubble|hide-crash-restore-bubble|disable-component-update|disable-background-networking|password-store|host-resolver-rules|disable-translate)" \
  | sed 's/^/  /' 

echo
echo "--- the restore bubble is suppressed ---"
echo "  NOTE. Chromium writes exit_type=Crashed while it RUNS, and changes it to"
echo "  Normal only on a clean exit. Reading it now therefore says Crashed and"
echo "  means nothing. What matters is that the launcher rewrites it to Normal"
echo "  BEFORE each start, and that the flags below are present."
if [ -f "${PROFILE}/Default/Preferences" ]; then
  grep -oE '"exit_type":"[^"]*"' "${PROFILE}/Default/Preferences" | head -1 | sed 's/^/  file says: /'
fi
echo "  launcher cleared the flags this boot:"
journalctl _SYSTEMD_USER_UNIT=mobilelab-kiosk.service -b --no-pager -o cat 2>/dev/null \
  | grep -c "cleared the crash flags" | sed 's/^/    times: /' 

echo
echo "--- what is on the screen ---"
if as_kiosk grim -t ppm "${SHOT}" 2> /dev/null; then
  python3 "${SCRIPT_DIR}/screen-check.py" "${SHOT}"
  rm -f "${SHOT}"
else
  echo "  could not capture the screen"
  echo "SCREEN_CHECK=FAIL"
fi

echo
echo "--- is the desktop panel or a file manager on top? ---"
PANEL="$(pgrep -c wf-panel-pi 2>/dev/null || echo 0)"
echo "  wf-panel-pi processes running: ${PANEL}"
echo "  the panel may run behind a fullscreen window. The pixel check above is"
echo "  what decides whether anything of it is visible."
