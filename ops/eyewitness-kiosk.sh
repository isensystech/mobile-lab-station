#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
KIOSK_USER="${MOBILELAB_KIOSK_USER:-planetwerx}"
KIOSK_UID="$(id -u "${KIOSK_USER}" 2>/dev/null || echo 1000)"
LAN_IP="$(hostname -I | awk '{print $1}')"
RULE="----------------------------------------------------------------------"

say() { echo; echo "${RULE}"; echo "$1"; echo "${RULE}"; }
tell() { echo "  $1"; }

clear
cat <<'BANNER'
======================================================================
        MOBILE LAB STATION - EYEWITNESS TEST, KIOSK MODE
======================================================================

The station now starts the chart by itself and shows nothing else.

Four of the checks need your hands. A script cannot pull a plug, press
a key, or press a button on the screen. Do these four in order.

BANNER

say "BEFORE YOU START. Know the way out."
cat <<'OUT'
  Learn these now, before you need them.

    Ctrl+Alt+K          stop the kiosk. The desktop comes back.
    Ctrl+Alt+Shift+K    start the kiosk again.
    Ctrl+Alt+F2         a text login on a plain screen.
    Ctrl+Alt+F7         back to the graphical screen.

  If every one of those fails, SSH still works from another computer.
OUT
echo
tell "Address of this station: ${LAN_IP}"
tell "The chart the kiosk shows: http://localhost:8000/"

say "TASK 1. Restart, and watch it come up."
cat <<'T1'
  1. Type this, then watch the screen:

       sudo systemctl reboot

  2. Watch the whole start. Do not look away.

  WHAT IS CORRECT.
    The screen shows boot text, then goes to the chart.
    The chart fills the screen. No desktop. No wallpaper. No taskbar.
    No window bar at the top. No address bar.
    NO BOX OF ANY KIND appears. No "restore pages", no "set as default
    browser", no "translate this page".
    The word Chart in the top bar is highlighted.
T1

say "TASK 2. Try the way out."
cat <<'T2'
  1. Press Ctrl+Alt+K.

  WHAT IS CORRECT. The chart closes. The desktop appears.

  2. Press Ctrl+Alt+Shift+K.

  WHAT IS CORRECT. The chart returns, fullscreen.

  3. Press Ctrl+Alt+F2.

  WHAT IS CORRECT. A plain text screen with a login prompt.

  4. Press Ctrl+Alt+F7.

  WHAT IS CORRECT. The chart comes back.

  If Ctrl+Alt+K does nothing, check the keyboard is awake. It is
  wireless. Press a letter key first and watch for it on screen.
T2

say "TASK 3. Pull the power. This is the student test."
cat <<'T3'
  A student will do this. Do it on purpose, now, while you are watching.

  1. Leave the chart running for two minutes first.
  2. Pull the power lead out of the Pi. Do not use the button.
  3. Wait ten seconds.
  4. Plug it back in.
  5. Watch the whole start again, and do not touch anything.

  WHAT IS CORRECT.
    The station starts on its own.
    The chart returns fullscreen, with no key press and no click.
    NO "Chromium did not shut down correctly" box. None.
    The chart draws the same data as before.

  6. Then open a terminal, or use another computer, and check the data:

       sudo -u postgres psql -d mobilelab -c "select count(*) from public.readings;"

  WHAT IS CORRECT. A number, and no error.
T3

say "TASK 4. The buttons on the screen."
cat <<'T4'
  The Pi may not see these buttons at all. Settle it with evidence.

  1. Type this:
T4
echo
tell "     sudo ${SCRIPT_DIR}/button-probe.sh 30"
echo
cat <<'T4B'
  2. While it counts down, press EVERY physical button on the screen.
     Press each one, wait a second, then press the next.
     Press the lower one twice, because that is the one in question.

  WHAT THE RESULT MEANS.

  If you see EVENT lines when you press a screen button, the Pi sees it.
  Tell me which button and which line, and it can then be ignored,
  remapped, or kept as the escape.

  If NOTHING arrives when you press the screen buttons, the buttons are
  wired to the monitor's own board. They never reach the Pi. No setting
  on the Pi can change what they do, and anybody who says otherwise is
  guessing. That needs a physical fix: tape, a cover, or a different
  bezel.

  The device called pwr_button is the Pi's own button, not the screen's.
  Pressing that one starts a clean shutdown on purpose.
T4B

say "The graceful stop."
cat <<'STOP1'
  Two ways to stop the station properly.

  1. On the screen: press Power in the top bar, then "Yes, shut down".
     It asks first, so one stray touch cannot stop a demo.

  2. In hardware: press the Pi 5 onboard button once. The station stops
     the same clean way.

  Wait for the screen to go dark before you unplug it.
STOP1

say "Six things that mean STOP."
cat <<'SIX'
  1. Any box on the screen after a start. A restore bar, a default
     browser question, a translate bar. The demo must never show one.

  2. The desktop, the wallpaper, or the taskbar visible behind or above
     the chart.

  3. The chart does not come back after the power test, or it needs a
     key press to come back.

  4. Ctrl+Alt+K and Ctrl+Alt+F2 both do nothing. That leaves no way out
     at the screen, and that is a defect even if everything else works.

  5. The count of readings falls after the power test, or the query
     gives an error.

  6. SSH stops working from another computer. That is the last way in.
     Fix it before the demo, not after.
SIX

say "If it all goes wrong."
tell "Turn the kiosk off completely with one command, over SSH:"
echo
tell "  sudo runuser -u ${KIOSK_USER} -- env XDG_RUNTIME_DIR=/run/user/${KIOSK_UID} \\"
tell "       systemctl --user disable --now mobilelab-kiosk.service"
echo
tell "The desktop comes back at the next start. Nothing was removed."
echo
tell "To run the checks a script CAN do:"
tell "  sudo ${SCRIPT_DIR}/verify-kiosk.sh"
echo
