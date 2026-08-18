#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ -f "${REPO_ROOT}/.env" ]; then
  set -a
  . "${REPO_ROOT}/.env"
  set +a
fi

API_PORT="${MOBILELAB_API_PORT:-8000}"
LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"

jget() { python3 -c "import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    print('?'); raise SystemExit(0)
for key in '$1'.split('.'):
    if isinstance(d, dict): d = d.get(key)
    else: d = None
print('?' if d is None else d)"; }

echo "================================================================"
echo "EYEWITNESS TEST: the GPS indicator"
echo "================================================================"
echo
echo "This is for Scott, at the screen, with his own eyes."
echo "No SSH. No curl. Look at the glass."
echo
echo "  The screen at the station, or from a laptop:"
echo "    http://${LAN_IP}:${API_PORT}/"
echo
echo "Take about ten minutes. Read the whole page before you start."
echo

echo "----------------------------------------------------------------"
echo "WHAT THE BADGE IS"
echo "----------------------------------------------------------------"
echo
echo "  Top right of the bar, beside the Power button, on all four pages."
echo "  It is a pill with a shape and two or three words in it."
echo
echo "  IT REPORTS THE FIX. IT DOES NOT REPORT THE CABLE."
echo "  A receiver that is plugged in and talking perfectly can still have no"
echo "  idea where it is. That is what happens indoors, every single time."
echo "  A badge that went green because the dongle was plugged in would be"
echo "  green in the one state where the position is worthless."
echo
echo "  Four states. Each one has a shape AND a word, so you never have to"
echo "  judge it by colour:"
echo
echo "    ●  GPS OK    green   solved 3D fix, four or more satellites"
echo "    ▲  NO FIX    amber   talking, and lost. Searching, or indoors."
echo "    ✕  NO GPS    red     nothing is talking. No receiver, or no data."
echo "    ?  GPS ?     grey    not asked yet. Only in the first second."
echo

echo "----------------------------------------------------------------"
echo "THE STATION IS RUNNING A WORKAROUND. READ THIS FIRST."
echo "----------------------------------------------------------------"
echo
echo "  THE USB BRIDGE IS FAULTY. This is measured, not suspected."
echo
echo "  The dongle is a Prolific PL2303. Its byte clock runs about 8.5"
echo "  percent fast. At the correct 9600 the station decodes NOTHING."
echo "  At 10416 the same bytes decode cleanly."
echo
echo "  SO THE STATION NOW HOLDS THE PORT AT 10416, NOT 9600."
echo "  That is a workaround for broken hardware. It is not a design."
echo "  It compensates for the fault. It does not repair it."
echo
echo "  The relay says so in its log at every start. Read it with:"
echo "    journalctl -u mobilelab-gpsrelay.service -n 30"
echo "  You should see HARDWARE WORKAROUND ACTIVE in capitals."
echo
echo "  A CP2102 or an FT232R is on order. When it is fitted, set"
echo "  MOBILELAB_GPS_BAUD=9600 in .env and restart the relay. The warning"
echo "  then stops by itself. That is the whole removal."
echo
echo "----------------------------------------------------------------"
echo "AND A SECOND FAULT, WORSE, FOUND 2026-08-18"
echo "----------------------------------------------------------------"
echo
echo "  THE RECEIVER HAS GONE SILENT. It sends NO BYTES AT ALL."
echo
echo "  Measured at every rate, 9600 and 10000 and 10200 and 10416 and"
echo "  10600, before and after a USB unbind and rebind. Zero bytes."
echo
echo "  This is NOT the clock fault. The clock fault delivered plenty of"
echo "  bytes and they were the wrong bytes. This delivers nothing."
echo
echo "  WHAT THAT MEANS FOR YOU TODAY. The badge will read ✕ NO GPS and it"
echo "  will not change, indoors or outside. No amount of sky helps."
echo
echo "  CHECK THE PHYSICAL THINGS FIRST. Nobody has checked them yet:"
echo "    Is the dongle still fully seated in the USB socket?"
echo "    Is the receiver still plugged into the dongle?"
echo "    Did a cable get pulled while the station was outside?"
echo "    Is the receiver light on at all?"
echo
echo "  UNTIL BYTES COME BACK, the rest of this page cannot be run."
echo "  The workaround is configured and waiting. It is not proven."
echo

echo "----------------------------------------------------------------"
echo "STEP 1. INDOORS. Expect AMBER."
echo "----------------------------------------------------------------"
echo
echo "  Stand at the station, inside, with the receiver plugged in."
echo
echo "  YOU SHOULD SEE:  ▲ NO FIX, amber, with a dashed white outline."
echo
echo "  THIS IS THE CORRECT ANSWER INDOORS. It is not a fault. The receiver"
echo "  can hear satellites through the roof. It cannot get enough of them to"
echo "  work out where it is."
echo
echo "  IF YOU SEE GREEN INDOORS, STOP. Something is wrong. Green indoors on"
echo "  a first fix is the exact defect this badge was built to catch."
echo
echo "  Go to each of the four tabs. Chart, Enter, Learn, Sensors."
echo "  The badge must be in the same place on all four, saying the same thing."
echo

echo "----------------------------------------------------------------"
echo "STEP 2. OPEN THE DETAIL PANEL."
echo "----------------------------------------------------------------"
echo
echo "  Press the badge. A panel opens. Check these lines:"
echo
echo "    Fix type            should say No fix"
echo "    Satellites seen     should be more than zero, usually 5 to 12"
echo "    Satellites used     should be ZERO"
echo "    Needed for GPS OK   4 satellites and a 3D fix"
echo "    Position            should say No position"
echo "    Time of last fix    should say There is no fix yet"
echo "    Clock source        Network time, GPS time, or Onboard clock"
echo "    Receiver            /dev/mobilelab-gps"
echo
echo "  THE LINE THAT TEACHES THE MOST is Satellites seen against"
echo "  Satellites used. Seen is what it can hear. Used is what it solved"
echo "  with. Eight seen and zero used is a receiver that is working hard"
echo "  and getting nowhere. Show a student that pair."
echo
echo "  Press Close."
echo

echo "----------------------------------------------------------------"
echo "STEP 3. CARRY IT OUTSIDE. Expect the badge to change."
echo "----------------------------------------------------------------"
echo
echo "  Take the station outdoors, with a clear view of open sky."
echo "  Away from the house wall. Not under a tree. Not on a porch."
echo
echo "  NOW WAIT. This is the part people get wrong."
echo
echo "  A cold receiver needs 30 seconds to 15 minutes for its first fix."
echo "  It has to download the almanac from the satellites themselves, and"
echo "  that arrives slowly. It is not broken. It is reading."
echo "  After the first fix, later ones take seconds."
echo
echo "  WHAT YOU SHOULD SEE, IN THIS ORDER:"
echo
echo "    1. The badge stays ▲ NO FIX."
echo "    2. Open the panel every minute. Satellites SEEN climbs first."
echo "       That number rising is proof the antenna works, well before"
echo "       any fix arrives."
echo "    3. Satellites USED goes from 0 to 4 or more."
echo "    4. The badge turns ● GPS OK, green, with a solid white outline."
echo "    5. Open the panel. Position now shows two numbers. Check them"
echo "       against a phone map. They should agree to a few metres."
echo "       Time of last fix now shows a time."
echo
echo "  THE ONE THING TO REMEMBER: the badge went amber to green by itself."
echo "  You did not press anything. Nobody restarted anything."
echo
echo "  WHAT GREEN MEANS, EXACTLY. It means the receiver SOLVED a position."
echo "  It needs a 3D fix AND four or more satellites USED. A 3D fix solves"
echo "  four unknowns, so it needs four satellites to do it."
echo "  GREEN IS NOT about the cable, the dongle, or the workaround. A"
echo "  station running the workaround and a station with a sound bridge"
echo "  both go green on the same evidence, or neither does."
echo
echo "  NO GREEN BADGE HAS EVER BEEN SEEN ON THIS STATION. Not once. If you"
echo "  are the first to see it, write down the satellites used and the"
echo "  time, because that is a new fact about this build."
echo

echo "----------------------------------------------------------------"
echo "STEP 4. CHECK IT COMES BACK."
echo "----------------------------------------------------------------"
echo
echo "  Carry it back inside, still running."
echo
echo "  The badge stays green for a while. A receiver holds its last fix."
echo "  Within a minute or two it should fall back to ▲ NO FIX."
echo "  A badge that stays green indoors for ten minutes is reporting a"
echo "  position it no longer has."
echo

echo "----------------------------------------------------------------"
echo "SIX THINGS THAT MEAN STOP"
echo "----------------------------------------------------------------"
echo
echo "  Stop, write down what you saw, and tell the developer. Do not"
echo "  demonstrate the station to anyone until it is explained."
echo
echo "  1. GREEN INDOORS, on a cold start."
echo "     The badge is reporting the cable, not the fix. Every position"
echo "     recorded after that is a guess wearing a green light."
echo
echo "  2. GREEN WITH SATELLITES USED BELOW 4, or with Position empty."
echo "     The badge and the panel disagree. One of them is lying and you"
echo "     cannot tell which."
echo
echo "  3. THE RELAY LOG DOES NOT SAY HARDWARE WORKAROUND ACTIVE."
echo "     On this dongle that warning MUST be there. If it is missing,"
echo "     the station is holding the port at 9600, and at 9600 this"
echo "     dongle decodes nothing at all. Check the setting:"
echo "       grep MOBILELAB_GPS_BAUD /opt/mobile-lab-station/.env"
echo "     It should read 10416 until the new bridge is fitted."
echo "     IF THE NEW BRIDGE IS FITTED, the opposite applies. The warning"
echo "     must be GONE and the value must read 9600."
echo
echo "  4. THE BADGE NEVER MOVES OFF GREY."
echo "     Grey means nobody has answered. It should last under a second."
echo "     Grey that stays means the page cannot reach the API."
echo
echo "  5. SATELLITES SEEN STUCK AT ZERO after twenty minutes outside."
echo "     SEEN is the number that matters here, not USED. Seen at zero"
echo "     means the antenna hears nothing at all. That is the antenna or"
echo "     the cable, and it is not patience."
echo "     SEEN ABOVE ZERO WITH USED AT ZERO IS NOT THIS FAULT. That is"
echo "     the known bridge fault above. Do not report it as new."
echo
echo "  6. A POSITION THAT IS NOT WHERE YOU ARE."
echo "     Off by a few metres is normal. Off by a kilometre, or in another"
echo "     state, or exactly 0, 0, is not. Check the panel for the word"
echo "     SIMULATED in a pink box. If it is there, the station is"
echo "     replaying a recorded log and is not reading the sky."
echo

echo "----------------------------------------------------------------"
echo "WHAT THE STATION SAYS RIGHT NOW"
echo "----------------------------------------------------------------"
echo
GPS_JSON="$(curl -s --max-time 8 "http://127.0.0.1:${API_PORT}/api/gps" 2>/dev/null)"
if [ -z "${GPS_JSON}" ]; then
  echo "  The API did not answer. Check mobilelab-api.service."
else
  echo "  badge            $(echo "${GPS_JSON}" | jget label)"
  echo "  why              $(echo "${GPS_JSON}" | jget detail)"
  echo "  fix type         $(echo "${GPS_JSON}" | jget fix.mode_text)"
  echo "  satellites seen  $(echo "${GPS_JSON}" | jget fix.satellites_seen)"
  echo "  satellites used  $(echo "${GPS_JSON}" | jget fix.satellites_used)"
  echo "  position         $(echo "${GPS_JSON}" | jget position.lat), $(echo "${GPS_JSON}" | jget position.lon)"
  echo "  receiver         $(echo "${GPS_JSON}" | jget device)"
  echo "  simulated        $(echo "${GPS_JSON}" | jget simulated)"
  echo "  clock source     $(echo "${GPS_JSON}" | jget clock.source)"
fi
echo
echo "  If that says NO FIX and you are indoors, the station is correct."
echo "  If that says NO FIX and you are OUTSIDE, read the known fault at"
echo "  the top of this page before you report anything."
echo
echo "  OTHER PROGRAMS ON THE SERIAL PORT RIGHT NOW"
WC_STATE="$(systemctl is-active weather-collector.service 2>/dev/null | head -1)"
if [ -z "${WC_STATE}" ]; then
  WC_STATE="not-installed"
fi
echo "    weather-collector  ${WC_STATE}"
if [ "${WC_STATE}" = "active" ]; then
  echo "    IT IS RUNNING. It writes into /dev/ttyUSB0 every two seconds."
  echo "    If the GPS receiver holds that name, the receiver is being"
  echo "    corrupted right now. Stop it before you trust this page."
fi
if [ -e /dev/mobilelab-gps ]; then
  echo "    /dev/mobilelab-gps -> $(readlink -f /dev/mobilelab-gps)"
fi
echo
echo "================================================================"
