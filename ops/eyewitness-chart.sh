#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VENV_PY="${REPO_ROOT}/.venv/bin/python"

if [ ! -f "${REPO_ROOT}/.env" ]; then
  echo "STOP. ${REPO_ROOT}/.env does not exist. Run the install steps first." >&2
  exit 1
fi

set -a
. "${REPO_ROOT}/.env"
set +a

API_PORT="${MOBILELAB_API_PORT:-8000}"
LAN_IP="$(hostname -I | awk '{print $1}')"
BASE="http://${LAN_IP}:${API_PORT}"
RULE="----------------------------------------------------------------------"

say() {
  echo
  echo "${RULE}"
  echo "$1"
  echo "${RULE}"
}

tell() {
  echo "  $1"
}

clear
cat <<'BANNER'
======================================================================
        MOBILE LAB STATION - EYEWITNESS TEST, THE OVERLAY CHART
======================================================================

This is the demo screen. Open it in a browser on the Pi.

This test does not draw the chart for you. It tells you what a correct
chart looks like, so you can judge the real one with your own eyes.

BANNER

say "STEP 1. Open the chart."
tell "Open a browser on the Pi. Type this address:"
echo
tell "    ${BASE}/"
echo
tell "From another computer on the same network, use the same address."
echo
tell "The chart is a normal web page. It is not a kiosk. You can still"
tell "reach the desktop, and you can close the browser at any time."
echo
tell "Checking that the page and the data are ready..."
echo
STATUS="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "${BASE}/" || echo 000)"
tell "the chart page answers HTTP ${STATUS}"
HEALTH="$(curl -sS --max-time 10 "${BASE}/health" 2>/dev/null || echo '{}')"
echo "${HEALTH}" | "${VENV_PY}" -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: print('  the API did not answer'); raise SystemExit
print('  the API says      ', d.get('status','unknown'))
w=d.get('writer') or {}
print('  writer stored     ', w.get('accepted_total','unknown'), 'readings this run')
print('  writer refused    ', w.get('rejected_total','unknown'), 'readings this run')
" 2>/dev/null

say "STEP 2. What a correct chart looks like."
cat <<'LOOK'
  There are two panels of numbers on one screen.

  THE CHART.
    Two lines share one time axis. Time runs left to right.
    The left edge shows the scale for rainfall, in millimetres.
    The right edge shows the scale for salinity, in PSU.
    Rainfall sits near zero most of the time, with a few tall spikes.
    Salinity sits near 25 PSU, and it dips after each spike.
    The dip always comes AFTER the spike, never before it.

  THE CONTROLS.
    A box changes the time range. Try 48 hours, 7 days, and 14 days.
    A tick box normalizes both lines. Both then run from 0 to 1 on one
    scale. Use it when the two units make one line look flat.
    A slider moves the second line in time. A button jumps the slider
    to the delay the station measured.

  THE TABLE.
    A row for each line. It names the measurement, the source, whether
    the numbers are real, and how the line is drawn.
LOOK

say "STEP 3. What the SIMULATED banner must look like."
cat <<'BANNER2'
  The banner is a WIDE RED BAR across the top of the page, under the
  title. It is on the page itself. It is not a tooltip. It is not a
  small note in the legend. You do not have to hover over anything.

  It reads:

      SIMULATED DATA. NOT A MEASUREMENT.
      A generator made these numbers. Do not use them as evidence
      about any real place.

  Both lines are DASHED while that banner is up. A dashed line means
  the station cannot vouch for the numbers.

  The banner appears whenever ANY line is not real. It also appears
  when the station cannot tell whether a line is real. Unknown counts
  as not real. That is on purpose.

  When real sensor data arrives one day, that line draws SOLID, and
  the banner goes away only if every line on the screen is real.
BANNER2

say "STEP 4. What the caption should say."
cat <<'CAPTION'
  Under the chart, in large text, you should read something close to:

      When rainfall rises, salinity falls about 6 hours later.
      The relationship is strong. r = -0.86.

  Read the number of hours. It should say about 6 hours.

  Why this matters. The station does NOT find that answer by comparing
  the tallest spike with the deepest dip. That method answers 7 hours,
  and it is wrong. Rain keeps falling after its own peak, so the water
  keeps getting fresher for a while.

  Instead the station slides one line against the other, hour by hour,
  and keeps the shift where the two match best. That method answers
  6 hours, which is the delay built into the test data.

  The word "about" is honest. It is an estimate, not a measurement.

  Under that, a second line changes as you drag the slider:

      You are looking at a shift of 6 hours. At this shift the
      relationship is strong. r = -0.86.

  Drag the slider to 0. The relationship becomes weak, near r = 0.01.
  Drag it back to 6. It becomes strong again. That is the lesson.

  At the bottom, always on screen:

      CORRELATION IS NOT CAUSATION.

  That text is permanent. It never hides.
CAPTION

say "STEP 5. Six things that mean STOP."
cat <<'STOP'
  1. A line is drawn SOLID while the red banner is up.
     Fake data is pretending to be real. This is the worst fault on
     this list. Stop the demo and report it.

  2. The red banner is missing while the table says NOT REAL.
     Same fault, seen from the other side.

  3. The caption says about 7 hours, or about 0 hours.
     The delay finder is broken, or the data did not load. The whole
     teaching point rests on that number.

  4. The salinity dip comes BEFORE the rain spike, or there is no dip.
     The time axis is wrong, or the two lines are misaligned.

  5. The words CORRELATION IS NOT CAUSATION are missing.
     A data literacy tool must carry its own caveat.

  6. The page says it could not get the data, or the chart is empty.
     The API or the writer has stopped. Check with:
       systemctl status mobilelab-api
       systemctl status mobilelab-writer
       journalctl -u mobilelab-writer -n 50
STOP

say "STEP 6. Two extra pages, if you want them."
tell "The chart self test. It feeds the chart broken data on purpose and"
tell "shows that the chart refuses to draw it as real:"
echo
tell "    ${BASE}/selftest"
echo
tell "The API documentation. Every question the chart asks is listed here,"
tell "and you can run each one from the page:"
echo
tell "    ${BASE}/docs"
echo

say "Notes."
tell "The numbers on the screen are test data. No real sensor exists yet."
tell "The station makes them from a seed, so the chart shows the same"
tell "shape every time. That is why the banner must stay up."
echo
tell "To run the automatic checks instead of your eyes, type:"
tell "  sudo ${SCRIPT_DIR}/verify-chart.sh"
echo
