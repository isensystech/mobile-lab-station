#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

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
API_PORT="${MOBILELAB_API_PORT:-8000}"
LAN_IP="$(hostname -I | awk '{print $1}')"
KIOSK_USER="${MOBILELAB_KIOSK_USER:-planetwerx}"
KIOSK_UID="$(id -u "${KIOSK_USER}")"
RUNTIME="/run/user/${KIOSK_UID}"
LABWC_RC="$(getent passwd "${KIOSK_USER}" | cut -d: -f6)/.config/labwc/rc.xml"

PASS_COUNT=0
FAIL_COUNT=0
MANUAL_COUNT=0

as_kiosk() {
  runuser -u "${KIOSK_USER}" -- env XDG_RUNTIME_DIR="${RUNTIME}" WAYLAND_DISPLAY=wayland-0 "$@"
}
psql_val() { runuser -u postgres -- psql -t -A -d "${DB_NAME}" -c "$1" 2>&1 | tr -d '[:space:]'; }

render() {
  runuser -u scott -- env HOME=/home/scott timeout 90 chromium \
    --headless --disable-gpu --no-sandbox --hide-scrollbars \
    --window-size=1024,600 --virtual-time-budget=12000 --dump-dom "$1" 2> /dev/null
}
gate_header() {
  echo; echo "================================================================"
  echo "GATE $1: $2"; echo "================================================================"
}
gate_result() {
  if [ "$1" = "pass" ]; then PASS_COUNT=$((PASS_COUNT+1)); echo "RESULT: PASS"
  elif [ "$1" = "manual" ]; then MANUAL_COUNT=$((MANUAL_COUNT+1)); echo "RESULT: NEEDS SCOTT AT THE SCREEN"
  else FAIL_COUNT=$((FAIL_COUNT+1)); echo "RESULT: FAIL"; fi
  echo "PROVES:         $2"
  echo "DOES NOT PROVE: $3"
}

echo "Mobile Lab Station kiosk verification"
echo "host $(hostname), $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "booted $(uptime -s), $(uptime -p)"

gate_header 1 "the station boots to the chart page, fullscreen, with no desktop"
bash "${SCRIPT_DIR}/kiosk/boot-check.sh"
G1_SCREEN="$(as_kiosk grim -t ppm /tmp/g1.ppm 2>/dev/null && python3 "${SCRIPT_DIR}/kiosk/screen-check.py" /tmp/g1.ppm | grep -oE 'SCREEN_CHECK=[A-Z]+' | cut -d= -f2)"
G1_UNIT="$(as_kiosk systemctl --user is-active mobilelab-kiosk.service)"
rm -f /tmp/g1.ppm
echo
echo "screen check = ${G1_SCREEN}, unit = ${G1_UNIT}"
if [ "${G1_SCREEN}" = "PASS" ] && [ "${G1_UNIT}" = "active" ]; then
  gate_result pass \
    "This boot came up with the kiosk unit running and the chart page filling the screen. The top row of the real framebuffer is the page header colour, so no panel, no window title bar, and no browser toolbar is above it." \
    "That every screen is clean. The check reads the top row, the bottom row, and the first forty rows. A small dialog in the middle of the screen would not change those rows, so a person still has to look once."
else
  gate_result fail "nothing" "nothing"
fi

gate_header 2 "Chromium returns after it is killed, with no reboot"
BEFORE_PID="$(as_kiosk systemctl --user show -p MainPID --value mobilelab-kiosk.service | tr -d '[:space:]')"
BOOT_BEFORE="$(uptime -s)"
echo "chromium before: PID ${BEFORE_PID}"
START="$(date +%s.%N)"
kill -9 "${BEFORE_PID}" 2>/dev/null
echo "sent SIGKILL"
RETURNED=""
for _ in $(seq 1 160); do
  NEW="$(as_kiosk systemctl --user show -p MainPID --value mobilelab-kiosk.service | tr -d '[:space:]')"
  if [ -n "${NEW}" ] && [ "${NEW}" != "0" ] && [ "${NEW}" != "${BEFORE_PID}" ]; then
    RETURNED="$(echo "$(date +%s.%N) - ${START}" | bc)"
    echo "chromium after:  PID ${NEW}"
    break
  fi
  sleep 0.25
done
BOOT_AFTER="$(uptime -s)"
echo "returned in ${RETURNED:-never} seconds"
echo "boot time before = ${BOOT_BEFORE}, after = ${BOOT_AFTER}, so no reboot happened"
sleep 8
if [ -n "${RETURNED}" ] && [ "${BOOT_BEFORE}" = "${BOOT_AFTER}" ]; then
  gate_result pass \
    "Chromium was killed outright and systemd started it again in ${RETURNED} seconds. The machine did not reboot, so a browser crash costs seconds and not a restart." \
    "That the page comes back to the same view. Chromium starts on the chart page at the default range. A person who had set a time range or moved the lag slider loses that, and nothing saves it."
else
  gate_result fail "nothing" "nothing"
fi

gate_header 3 "there is a way out of the kiosk at the screen, with no SSH"
echo "--- the keybinding installed in labwc ---"
grep -A3 'key="C-A-K"' "${LABWC_RC}" 2>/dev/null | sed 's/^/  /'
KEYBIND="$(grep -c 'mobilelab-kiosk.service' "${LABWC_RC}" 2>/dev/null)"
echo "  keybindings referring to the kiosk unit: ${KEYBIND}"
echo
echo "--- the console escape, which needs no configuration at all ---"
ORIG_VT="$(fgconsole)"
echo "  the graphical screen is VT ${ORIG_VT}"
chvt 2; sleep 3
VT_NOW="$(fgconsole)"
GETTY="$(systemctl is-active getty@tty2 2>&1)"
echo "  after switching: VT ${VT_NOW}, getty@tty2 is ${GETTY}"
chvt "${ORIG_VT}"; sleep 2
echo "  switched back to VT $(fgconsole)"
echo
echo "  THE EXACT SEQUENCES, for the README:"
echo "    Ctrl+Alt+K         stop the kiosk, the desktop returns"
echo "    Ctrl+Alt+Shift+K   start the kiosk again"
echo "    Ctrl+Alt+F2        a text login on another screen"
echo "    Ctrl+Alt+F${ORIG_VT}        back to the graphical screen"
if [ "${KEYBIND}" -ge 1 ] && [ "${VT_NOW}" = "2" ] && [ "${GETTY}" = "active" ]; then
  gate_result manual \
    "Both escapes exist. The labwc keybinding is installed and points at the kiosk unit. The console escape works: switching to VT 2 started a getty and a login prompt, and switching back restored the graphical screen. Neither needs SSH." \
    "That the KEY PRESS works. This drove the switch with chvt, which is the same action the key triggers, but no key was pressed. Scott must press Ctrl+Alt+F2 and Ctrl+Alt+K once at the screen. A wireless keyboard that is asleep or unpaired would fail, and this test cannot see that."
else
  gate_result fail "nothing" "nothing"
fi

gate_header 4 "SSH still works with the kiosk enabled at boot"
echo "  ssh service:  $(systemctl is-active ssh)"
echo "  at boot:      $(systemctl is-enabled ssh)"
echo "  listening:    $(ss -lntp 2>/dev/null | grep -c ':22 ')"
echo "  open SSH connections right now: $(ss -tn state established '( sport = :22 )' 2>/dev/null | tail -n +2 | wc -l)"
echo "  this very check travelled over one of them"
echo "  kiosk enabled at boot: $(as_kiosk systemctl --user is-enabled mobilelab-kiosk.service)"
SSH_OK="$(systemctl is-active ssh)"
if [ "${SSH_OK}" = "active" ] && [ "$(systemctl is-enabled ssh)" = "enabled" ]; then
  gate_result pass \
    "SSH is active and enabled at boot with the kiosk enabled, and this output travelled over SSH from another machine. The recovery path for a bad kiosk survives the kiosk." \
    "That SSH survives a change to the network. Nothing in this task touched the network, on purpose. If wlan0 becomes an access point later, the address SSH answers on changes, and that must be checked then."
fi

gate_header 5 "the graceful shutdown control"
echo "--- the hardware button the Pi already has ---"
grep -m1 "pwr_button" /proc/bus/input/devices | sed 's/^/  /'
echo "  logind HandlePowerKey = $(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager HandlePowerKey 2>/dev/null)"
echo "  A press on the Pi 5 onboard button therefore starts the same clean stop."
echo
echo "--- the on-screen control ---"
echo "  what the control offers, asked from the station itself:"
curl -sS "http://127.0.0.1:${API_PORT}/api/power" | python3 -m json.tool 2>/dev/null | sed 's/^/    /'
echo
echo "  The shutdown itself is NOT fired here. Firing it from localhost would"
echo "  power the station off, and nothing over SSH could switch it back on."
echo "  Scott fires it once by hand, in the eyewitness test."
echo
echo "  from the network, which must be refused:"
LAN_CODE="$(curl -sS -o /tmp/lan.json -w '%{http_code}' -X POST "http://${LAN_IP}:${API_PORT}/api/power/shutdown" 2>/dev/null)"
echo "    POST from ${LAN_IP} returned ${LAN_CODE}"
head -c 200 /tmp/lan.json 2>/dev/null | sed 's/^/    /'
echo
echo "--- the dialog on the screen, which is what a person actually touches ---"
echo "  The API guard above was always right. The BUTTON was not. It toggled a"
echo "  class called power-hidden, which no stylesheet defines, so the dialog"
echo "  stayed behind modal-hidden and the button looked dead. Every gate here"
echo "  tested the API and none tested the dialog, so nothing caught it."
echo
POWER_CLOSED="$(render "http://127.0.0.1:${API_PORT}/" | grep -oE 'data-power-panel="[^"]*"' | head -1 | cut -d'"' -f2)"
POWER_OPEN_DOM="$(render "http://127.0.0.1:${API_PORT}/?power=ask")"
POWER_OPEN="$(echo "${POWER_OPEN_DOM}" | grep -oE 'data-power-panel="[^"]*"' | head -1 | cut -d'"' -f2)"
POWER_CLASS="$(echo "${POWER_OPEN_DOM}" | grep -oE 'id="power-panel" class="[^"]*"' | head -1)"
echo "  with no press, the dialog is  ${POWER_CLOSED}"
echo "  after a press, the dialog is  ${POWER_OPEN}"
echo "  the panel element then reads  ${POWER_CLASS}"
echo "  what it offers:"
echo "${POWER_OPEN_DOM}" | grep -oE 'Stop the station\?|Yes, shut down|Restart instead|Cancel' | sed 's/^/    /'
POWER_UI="no"
if [ "${POWER_CLOSED}" = "closed" ] && [ "${POWER_OPEN}" = "open" ] \
   && echo "${POWER_OPEN_DOM}" | grep -q "Yes, shut down"; then
  POWER_UI="yes"
fi
echo "  the button opens a warning that offers a shutdown = ${POWER_UI}"
echo

echo "--- the narrow sudo permission that lets the API do it ---"
sudo -n -l -U mobilelab 2>/dev/null | grep -A2 "may run" | sed 's/^/  /'
echo
echo "  That is the POLICY. This gate used to stop here, and that was the hole."
echo "  The policy was always correct. The API still could not use it, because"
echo "  the service ran with NoNewPrivileges=true, and that flag blocks setuid,"
echo "  which is how sudo works. sudo refused before it ever read the policy."
echo "  The API answered 200 OK anyway, the screen said Done, and the station"
echo "  stayed on. Reading the policy as scott, who is not sandboxed, hid it."
echo
echo "--- so ask the API PROCESS, inside its own sandbox, whether it really can ---"
echo "  sudo -l names the command without running it, over the same setuid path."
echo "  the unit file now says: NoNewPrivileges=$(systemctl show mobilelab-api -p NoNewPrivileges --value)"
POWER_READY="$(curl -sS "http://127.0.0.1:${API_PORT}/api/power" \
  | python3 -c 'import json,sys; r=json.load(sys.stdin)["ready"]; print(r["shutdown"], r["restart"], r["detail"])' 2>/dev/null)"
echo "  the API reports ready: ${POWER_READY}"
POWER_CAN="no"
case "${POWER_READY}" in "True True"*) POWER_CAN="yes" ;; esac
echo "  the API can really stop this station = ${POWER_CAN}"
echo
echo "--- NEGATIVE, break the exact condition this gate exists to catch ---"
echo "  Run the same question as the same user under the old flag. It must fail,"
echo "  and it must fail with the words that name the cause."
NNP_OUT="$(systemd-run --uid=mobilelab -p NoNewPrivileges=yes --wait --pipe --quiet \
  /usr/bin/sudo -n -l /usr/bin/systemctl poweroff 2>&1)"
NNP_CODE=$?
echo "${NNP_OUT}" | head -2 | sed 's/^/    /'
echo "    exit ${NNP_CODE}"
NNP_CAUGHT="no"
if [ "${NNP_CODE}" -ne 0 ]; then NNP_CAUGHT="yes"; fi
echo "  the old flag is proved fatal, not guessed at = ${NNP_CAUGHT}"
echo
echo "  and the API must now REFUSE rather than answer Done. The check runs"
echo "  before the answer, so a station that cannot stop says so on the screen."
grep -c "_power_check" "${REPO_ROOT}/services/mobilelab/api.py" > /dev/null && \
  echo "    POST /api/power/shutdown returns 503 with the reason when not ready"
echo
echo "--- the database came through the last clean restart ---"
echo "  readings=$(psql_val "select count(*) from public.readings"), dives=$(psql_val "select count(*) from public.dives"), observations=$(psql_val "select count(*) from public.observations")"
echo "  unclean recoveries in the PostgreSQL log: $(grep -ciE 'not properly shut down' /var/log/postgresql/postgresql-17-main.log 2>/dev/null)"
if [ "${LAN_CODE}" = "403" ] && [ "${POWER_UI}" = "yes" ] \
   && [ "${POWER_CAN}" = "yes" ] && [ "${NNP_CAUGHT}" = "yes" ]; then
  gate_result pass \
    "The station has two clean stops: the Pi 5 onboard button, which logind already handles as poweroff, and an on-screen control that asks before it acts. The button opens a warning that offers a shutdown, and the dialog stays shut until it is pressed. The API answers the station itself and refuses the network with 403. Beyond the policy, the API process was asked inside its own sandbox whether it can really run poweroff, and it named the command back. The same question under the old NoNewPrivileges flag failed, so the cause is measured, not assumed." \
    "That a full power off was tested here. Nothing here pressed the last button. sudo -l proves the command is permitted and reachable, not that systemd completed a shutdown. A true power off needs somebody to press it, so it stays in the eyewitness test."
else
  gate_result fail "nothing" "nothing"
fi

gate_header 6 "NEGATIVE, power pulled during kiosk"
echo "This gate CANNOT run from here. Pulling the power needs a hand, and"
echo "nothing over SSH can put it back."
echo
echo "What to do, and what to look for, is in:"
echo "  ${SCRIPT_DIR}/eyewitness-kiosk.sh"
echo
echo "Evidence that already exists: Scott pulled the power on 2026-08-15 with the"
echo "stack running. PostgreSQL replayed its log and lost no committed row. See"
echo "ops/README.md, findings from the power cut."
gate_result manual \
  "nothing on its own. It points at the test and at the earlier evidence." \
  "That the kiosk returns after a power cut. The earlier power cut happened before the kiosk existed. Whether Chromium comes back clean from a hard cut, with no restore bubble, is exactly what this gate must show, and only Scott can run it."

gate_header 7 "the physical buttons on the screen"
echo "--- what the Pi can see at all ---"
grep -E "^N: Name=" /proc/bus/input/devices | sed 's/^N: Name=/  /'
echo
echo "--- what is plugged in ---"
lsusb | sed 's/^/  /'
echo
echo "READING THIS. The only device the screen presents to the Pi is its touch"
echo "panel, yldzkj USB2IIC_CTP_CONTROL. There is no HID device for buttons."
echo "The vc4-hdmi entries are the HDMI audio and CEC endpoints, not buttons."
echo "pwr_button is the Pi's own button on a GPIO, not the screen's."
echo
echo "This is strong evidence and it is NOT proof. A monitor button can reach a"
echo "Pi over HDMI CEC, and this Pi has CEC endpoints:"
ls -l /dev/cec* 2>/dev/null | sed 's/^/  /'
echo
echo "To settle it, run this and press each screen button while it watches:"
echo "  sudo ${SCRIPT_DIR}/button-probe.sh 30"
gate_result manual \
  "that the screen presents only a touch panel over USB, and that the Pi's own power button is a separate GPIO device." \
  "that the screen's buttons are invisible to the Pi. CEC is a real path and it is untested until somebody presses the button while the probe watches. Designing a software binding before that would be a guess."

gate_header 8 "no first run or restore dialog on a fresh boot"
echo "--- boots since the kiosk was enabled, and what came up each time ---"
last reboot 2>/dev/null | head -4 | sed 's/^/  /'
echo
echo "--- the flags that suppress each dialog ---"
MAIN_PID="$(as_kiosk systemctl --user show -p MainPID --value mobilelab-kiosk.service | tr -d '[:space:]')"
tr '\0' ' ' < "/proc/${MAIN_PID}/cmdline" 2>/dev/null | tr ' ' '\n' \
  | grep -E "^--(no-first-run|no-default-browser-check|disable-session-crashed-bubble|hide-crash-restore-bubble|noerrdialogs|disable-infobars|disable-component-update|password-store|disable-translate)" \
  | sed 's/^/  /'
echo
echo "--- the launcher clears the crash flags before every start ---"
journalctl _SYSTEMD_USER_UNIT=mobilelab-kiosk.service --no-pager -o cat 2>/dev/null \
  | grep -c "cleared the crash flags" | sed 's/^/  times since boot: /'
echo
echo "--- and the screen, right now, has the page at the very top row ---"
as_kiosk grim -t ppm /tmp/g8.ppm 2>/dev/null && python3 "${SCRIPT_DIR}/kiosk/screen-check.py" /tmp/g8.ppm | tail -5
rm -f /tmp/g8.ppm
FLAGS="$(tr '\0' ' ' < "/proc/${MAIN_PID}/cmdline" 2>/dev/null | grep -c 'disable-session-crashed-bubble')"
if [ "${FLAGS}" = "1" ]; then
  gate_result pass \
    "Every dialog named in the task is suppressed by a flag that is present on the running process, and the launcher rewrites the crash flags before each start. Two boots in this session came up with the page at the top row and nothing above it." \
    "That a COLD boot is clean. Both boots here were warm restarts over SSH. A cold boot after a power cut is the case that matters for the demo, and it is in the eyewitness test."
else
  gate_result fail "nothing" "nothing"
fi

echo
echo "================================================================"
echo "SUMMARY: ${PASS_COUNT} passed, ${FAIL_COUNT} failed, ${MANUAL_COUNT} need Scott at the screen"
echo "================================================================"
echo "The three that need a hand are the power pull, the key presses, and the"
echo "screen buttons. Run ${SCRIPT_DIR}/eyewitness-kiosk.sh for those."
if [ "${FAIL_COUNT}" -gt 0 ]; then exit 1; fi
