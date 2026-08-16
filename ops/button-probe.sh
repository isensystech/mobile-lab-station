#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECONDS_TO_WATCH="${1:-30}"

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: run this script with sudo. It reads the raw input devices." >&2
  exit 1
fi

echo "======================================================================"
echo "  DOES THE PI SEE THE SCREEN BUTTONS?"
echo "======================================================================"
echo
echo "This watches every input the Pi has, for ${SECONDS_TO_WATCH} seconds."
echo "Press each physical button on the screen while it runs."
echo
echo "--- what is plugged in ---"
lsusb | sed 's/^/  /'
echo
echo "--- HDMI CEC devices, a monitor button can arrive this way ---"
ls -l /dev/cec* 2>/dev/null | sed 's/^/  /' || echo "  no /dev/cec device"
echo
echo "--- starting the watch ---"
python3 "${SCRIPT_DIR}/kiosk/button-probe.py" "${SECONDS_TO_WATCH}"
echo
echo "HOW TO READ THIS."
echo
echo "If a screen button produced an EVENT line, the Pi sees it. It can then be"
echo "ignored, remapped, or kept as the escape."
echo
echo "If nothing arrived when you pressed a screen button, the button is wired"
echo "to the monitor's own board. It never reaches the Pi, and no software on"
echo "the Pi can change what it does. That needs a physical fix, not a setting."
echo
echo "The device named pwr_button is the Pi's own button, not the screen's."
