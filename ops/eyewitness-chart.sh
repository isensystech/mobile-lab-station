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
      MOBILE LAB STATION - EYEWITNESS TEST, THE REHEARSAL RIG
======================================================================

This is the rehearsal rig for the lesson.

The chart holds three measurements on one clock:

  Salinity     how salty the water is
  NOAA         the public rainfall record for this area
  Rain Gauge   the rainfall at this one spot

You reveal them one at a time. This test tells you what a correct
screen looks like at each step. Judge the real screen with your eyes.

This test does not press the buttons for you.

BANNER

say "STEP 1. Open the chart."
tell "The kiosk already shows it. From another computer, open:"
echo
tell "    ${BASE}/"
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
" 2>/dev/null

say "STEP 2. What you see when it opens."
cat <<'LOOK'
  All three lines are on screen. That is on purpose. The rig starts
  with everything shown, so nothing hides by accident before a lesson.

  Three large buttons sit under the chart:

      Salinity     NOAA     Rain Gauge

  Each button is filled in. A filled button means the line is shown.
  Each button carries a small square in the colour of its own line.

  The left edge of the chart shows salinity, in PSU.
  The right edge shows rainfall, in millimetres.
  BOTH rainfall lines share that one right edge. They must, because
  they measure the same thing in the same unit. That is what makes
  them comparable.

  A magenta badge in the top bar reads SIMULATED DATA.
LOOK

say "STEP 3. Show Salinity alone."
cat <<'LOOK'
  Press the NOAA button. Its line goes away. The button empties.
  Press the Rain Gauge button. Its line goes away too.

  Only salinity is left.

  WATCH THE SALINITY LINE WHILE YOU DO THIS.

  It must NOT move. Not up, not down, not sideways. The numbers on
  the left edge must not change. The chart must look like somebody
  rubbed out two lines, and nothing else.

  This is the reason the rig is built this way. A salinity line that
  jumps when you hide another line shows a student a change that did
  not happen in the water.
LOOK

say "STEP 4. Add NOAA."
cat <<'LOOK'
  Press the NOAA button again.

  A second line appears, in orange, against the right edge.

  It is SMOOTH and LOW. It rises and falls slowly, across a day or
  more. It has no sharp peaks.

  Look closely. It is drawn in STEPS. It holds one value flat for a
  whole hour. Then it steps to the next value. That is honest
  drawing. The public number is one figure for a whole area for a
  whole hour. It is not a reading from one place at one moment.

  A line of text appears under the chart:

      NOAA against Salinity, from public_synthetic.
      The relationship is weak. r = 0.31 at about 3 hours.

  WEAK is the correct answer. The public record does not explain the
  salinity. Say that out loud during the lesson.

  The salinity line still has not moved.
LOOK

say "STEP 5. Add Rain Gauge."
cat <<'LOOK'
  Press the Rain Gauge button.

  A third line appears, in purple, against the same right edge.

  It looks NOTHING like the NOAA line. It is spiky. It sits near zero.
  Then it jumps to a tall peak, several times taller than anything
  NOAA shows. It is drawn as a continuous line, not in steps.

  A second line of text appears:

      Rain Gauge against Salinity, from synthetic.
      The relationship is strong. r = -0.86 at about 6 hours.

  STRONG. The headline above now reads:

      When Rain Gauge rises, Salinity falls about 6 hours later.

  THIS IS THE LESSON. Two rainfall numbers cover the same place and
  the same hours. One explains the salinity. One does not.

  The public record is not wrong. It reports an average across
  kilometres, so it cannot see a storm over one street. Nobody
  measures at this resolution. That gap is the opportunity.

  At the bottom, always:

      CORRELATION IS NOT CAUSATION.
LOOK

say "STEP 6. Two controls worth showing."
cat <<'LOOK'
  Press "Measured delay". The slider jumps to the delay the station
  measured, which is about 6 hours.

  Drag the slider to 0. The relationship becomes weak. Drag it back
  to 6. It becomes strong again.

  The station does NOT find 6 hours by comparing the tallest spike
  with the deepest dip. That method answers 7 hours, and it is wrong.
  Rain keeps falling after its own peak.

  Press "Where from". It lists every line, its source, and whether
  the station calls it real.
LOOK

say "SIX THINGS THAT MEAN STOP."
cat <<'STOP'
  1. The salinity line MOVES when you hide or show another line.
     A student reads that as a change in the water. It is not one.
     Stop and report it.

  2. A line is drawn SOLID while the SIMULATED badge is up.
     Fake data pretends to be real. This is the worst fault on this
     list. Stop the rehearsal.

  3. The NOAA line has a sharp spike, or it matches the Rain Gauge
     line. The rig is broken. The lesson needs those two lines to
     DISAGREE.

  4. The NOAA relationship reads strong, or the Rain Gauge
     relationship reads weak. The two are the wrong way round. The
     lesson then teaches the opposite of the truth.

  5. Only one correlation is reported for rainfall. Each rainfall
     line must get its own r, and its own source named.

  6. The words CORRELATION IS NOT CAUSATION are missing. Or a button
     carries an act number instead of the name of a measurement.
STOP

say "What is real here, and what is not."
tell "A seeded generator made every number on this rig. Nothing on this"
tell "screen is a measurement yet."
echo
tell "The SIMULATED badge says that. It stays up on its own while any"
tell "line comes from a generator."
echo
tell "The badge reads the label, not the name of a line. A real figure"
tell "replaces a series, that series draws solid, and the badge clears"
tell "itself. No code changes."
echo

say "The test is finished."
tell "To run it again, type:"
tell "  ${SCRIPT_DIR}/eyewitness-chart.sh"
echo
tell "To run the automatic checks instead of your eyes, type:"
tell "  sudo ${SCRIPT_DIR}/verify-rehearsal.sh"
echo
tell "To rebuild the rig data, type:"
tell "  sudo ${SCRIPT_DIR}/seed-rehearsal.sh"
echo
