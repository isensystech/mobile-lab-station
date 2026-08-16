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
tell() { echo "  $1"; }

clear
cat <<'BANNER'
======================================================================
      MOBILE LAB STATION - EYEWITNESS TEST, THE ENTRY FORM
======================================================================

This is the instrument that collects the data. Every rain gauge
reading between now and the 19th goes in through this form.

This test asks YOU to type. It does not type for you. Do the four
tasks below at the screen, then read the checklist.

BANNER

say "Open the form."
tell "Open a browser on the Pi. Type this address:"
echo
tell "    ${BASE}/entry"
echo
tell "Checking the form and the clock now..."
echo
STATUS="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "${BASE}/entry" || echo 000)"
tell "the form answers HTTP ${STATUS}"
curl -sS --max-time 10 "${BASE}/api/clock" 2>/dev/null | "${VENV_PY}" -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: print('  the API did not answer'); raise SystemExit
print('  station clock  ', d['now'])
print('  clock is good  ', d['ok'])
for p in d.get('problems',[]): print('  PROBLEM        ', p)
" 2>/dev/null

say "TASK 1. Enter a rain gauge reading."
cat <<'T1'
  1. Type your name in "Your name".
  2. Type "rain gauge" in "Site".
  3. Leave the date and time alone. It shows now.
  4. In the Rainfall row, type 4.2 and leave the unit as mm.
  5. Press "Save this reading".

  You should see: "Saved 1 readings." in green.
  The entry appears in "The last few entries" at the bottom.
  Your name and the site stay in their boxes. The number is cleared.

  Now enter a second reading straight away. Type 5.1 in Rainfall and
  press Save again. You should not have to retype your name or the
  site. That is the point. Three times a day, every day.
T1

say "TASK 2. Enter a reading that is deliberately wrong."
cat <<'T2'
  1. In the pH row, type 700.
  2. Watch the row BEFORE you save.

  You should see: the row turns yellow, and a message says the value
  looks wrong and gives the usual range. The Save button STAYS ON.

  3. Press "Save this reading".

  You should see: "Saved 1 readings. 1 looks wrong and is marked for
  review." The entry appears in the list below with an orange
  FLAGGED, CHECK THIS tag.

  THE POINT. The station did not stop you. It also did not hide the
  problem. A student who really measured pH 700 has a broken meter,
  and that is worth knowing. A station that refuses the number
  teaches the student to distrust the tool.
T2

say "TASK 3. Correct it."
cat <<'T3'
  1. Find the pH 700 entry in "The last few entries".
  2. Press "Fix" on that row.
  3. Type 7.2 in "The correct number".
  4. Press "Save the fix".

  You should see: the list refreshes, the orange tag is gone, and the
  row now reads 7.2.

  5. Press "Fix" again on the 5.1 rainfall entry, then press
     "Remove this reading". It disappears from the list.

  THE POINT. A correction also repairs the charts. The chart reads a
  summary table, not the raw rows. If a correction skipped that step,
  the chart would keep drawing 700 for ever.
T3

say "TASK 4. Export."
cat <<'T4'
  1. Press "Download all data as CSV" at the bottom.
  2. Open the file.

  You should see a header row, then one line for each reading. Look
  for these columns: value_raw and unit_raw hold what you typed,
  value and unit hold the converted number, and
  reading_quality_flag says plausible or implausible.
T4

say "What a correct result looks like."
cat <<'GOOD'
  1. Every save shows a green "Saved" line within about a second.

  2. Your name and the site survive a save. The numbers clear. The
     cursor returns to the first number box.

  3. A wrong value turns the row yellow BEFORE you save, and saves
     anyway when you press Save.

  4. A flagged entry carries an orange FLAGGED, CHECK THIS tag in the
     list below.

  5. A "Fix" changes the number in the list at once.

  6. If you type a temperature in degF, the list shows BOTH: what you
     typed, and what the station stored in degC.
GOOD

say "Six things that mean STOP."
cat <<'STOP'
  1. The form refuses to save pH 700, or shows an error instead of a
     flag. Blocking the input is a defect. Report it.

  2. The form saves pH 700 with NO yellow row and NO orange tag. A
     silent accept is also a defect, and a worse one.

  3. A red bar says the station clock is wrong. Do NOT type readings.
     Write them on paper and tell Scott. The station will refuse to
     save while the clock is wrong, and that is correct behaviour.
     The Pi has no clock battery fitted.

  4. The date and time box is empty, or shows 1970. Same as above.
     Stop and report it.

  5. Your name or the site clears itself after a save. Entering three
     readings a day becomes retyping, and retyping causes mistakes.

  6. A "Fix" or a "Remove" appears to work, but the chart at
     ${BASE}/ still shows the old number. The
     correction did not reach the summary table. Report it.
STOP

say "Notes."
tell "The form writes source manual, and manual is a real source. It is"
tell "not possible to enter data here under a not-real source."
echo
tell "The station keeps both numbers. If you type degrees Fahrenheit, it"
tell "stores your number AND the degrees Celsius conversion."
echo
tell "To run the automatic checks instead of your hands, type:"
tell "  sudo ${SCRIPT_DIR}/verify-entry.sh"
echo
tell "To see the chart these readings feed, open:"
tell "  ${BASE}/"
echo
