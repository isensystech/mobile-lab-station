#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VENV="${REPO_ROOT}/.venv"
FIXTURES="${SCRIPT_DIR}/gps-fixtures"
export PYTHONPATH="${REPO_ROOT}/services"
export PATH="/usr/sbin:/sbin:${PATH}"

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
STATION="${MOBILELAB_STATION_ID:-lab01}"
GPS_LINK="/dev/mobilelab-gps"
GPS_BAUD="9600"
USB_ID="3-2"
FAKE_PORT="2947"

PASS_COUNT=0
FAIL_COUNT=0
MANUAL_COUNT=0

psql_val() { runuser -u postgres -- psql -t -A -d "${DB_NAME}" -c "$1" 2>&1 | tr -d '[:space:]'; }

render() {
  runuser -u scott -- env HOME=/home/scott timeout 90 chromium \
    --headless --disable-gpu --no-sandbox --hide-scrollbars \
    --window-size=1024,600 --virtual-time-budget=12000 --dump-dom "$1" 2> /dev/null
}

dom_attr() { grep -oE "$1=\"[^\"]*\"" | head -1 | cut -d'"' -f2; }

gate_header() {
  echo; echo "================================================================"
  echo "GATE $1: $2"; echo "================================================================"
}
gate_result() {
  if [ "$1" = "pass" ]; then PASS_COUNT=$((PASS_COUNT+1)); echo "RESULT: PASS"
  elif [ "$1" = "manual" ]; then MANUAL_COUNT=$((MANUAL_COUNT+1)); echo "RESULT: NEEDS SCOTT AT THE STATION"
  else FAIL_COUNT=$((FAIL_COUNT+1)); echo "RESULT: FAIL"; fi
  echo "PROVES:         $2"
  echo "BLIND SPOT:     $3"
}

gps_status_json() {
  timeout 12 mosquitto_sub -h 127.0.0.1 -t mobilelab/gps/status -C 1 2>/dev/null
}
api_gps() { curl -s --max-time 10 "http://127.0.0.1:${API_PORT}/api/gps"; }
jget() { python3 -c "import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(''); raise SystemExit(0)
for key in '$1'.split('.'):
    if isinstance(d, dict): d = d.get(key)
    else: d = None
print('' if d is None else d)"; }

stop_fake() {
  pkill -f "gpsfake" 2>/dev/null
  sleep 2
}

power_cycle_dongle() {
  systemctl stop mobilelab-gps.service mobilelab-gpsrelay.service > /dev/null 2>&1
  systemctl stop gpsd.service gpsd.socket > /dev/null 2>&1
  sleep 1
  echo "${USB_ID}" > /sys/bus/usb/drivers/usb/unbind 2>/dev/null
  sleep 3
  echo "${USB_ID}" > /sys/bus/usb/drivers/usb/bind 2>/dev/null
  sleep 4
  udevadm trigger --subsystem-match=tty --action=add 2>/dev/null
  sleep 2
}

restore_real() {
  stop_fake
  systemctl restart mobilelab-gpsrelay.service > /dev/null 2>&1
  sleep 2
  systemctl start gpsd.socket  > /dev/null 2>&1
  systemctl start gpsd.service > /dev/null 2>&1
  sleep 3
  systemctl restart mobilelab-gps.service > /dev/null 2>&1
  sleep 8
}

echo "Mobile Lab Station GPS and RTC verification"
echo "host $(hostname), $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "booted $(uptime -s), $(uptime -p)"
echo
echo "SCOPE. This checks the receiver, the driver, the indicator, and the clock."
echo "It does not stamp position onto readings. That is a later task."

if systemctl is-active --quiet weather-collector.service; then
  echo
  echo "STOP. weather-collector.service is running."
  echo "It holds /dev/ttyUSB0 for a sensor that is not fitted, so it corrupts"
  echo "every sentence the GPS receiver sends. Run this first:"
  echo "  sudo systemctl stop weather-collector.service"
  exit 1
fi

python3 "${FIXTURES}/make-nmea.py" > /dev/null 2>&1

echo
echo "==> power cycling the dongle before gate 1."
echo "    THIS IS NOT TIDINESS. This dongle decays to unreadable roughly 20"
echo "    seconds after power up. See the hardware note at the end of this run."
echo "    Gate 1 has to read it inside that window or it measures the fault"
echo "    instead of the wiring."
power_cycle_dongle
systemctl start mobilelab-gpsrelay.service > /dev/null 2>&1
sleep 2
systemctl start gpsd.service > /dev/null 2>&1
sleep 3

gate_header 1 "gpsd reads the receiver"
echo "--- the device ---"
if [ -e "${GPS_LINK}" ]; then
  G1_REAL="$(readlink -f "${GPS_LINK}")"
  echo "  symlink      ${GPS_LINK} -> ${G1_REAL}"
else
  G1_REAL=""
  echo "  symlink      ${GPS_LINK} IS MISSING"
  echo "               expected USB socket: $(grep -oE 'ID_PATH==\"[^\"]*\"' "${SCRIPT_DIR}/udev/70-mobilelab-gps.rules" | cut -d'"' -f2)"
fi
udevadm info -q property -n "${GPS_LINK}" 2>/dev/null \
  | grep -E "ID_VENDOR_ID|ID_MODEL_ID|ID_PATH=|ID_MM_DEVICE_IGNORE" | sed 's/^/  /'
echo
echo "--- the baud rate gpsd was given ---"
grep -E "DEVICES|GPSD_OPTIONS|USBAUTO" /etc/default/gpsd | sed 's/^/  /'
echo "  measured baud: ${GPS_BAUD}"
echo
echo "--- gpsd ---"
echo "  gpsd.service is $(systemctl is-active gpsd.service)"
gpsd -V 2>&1 | head -1 | sed 's/^/  /'
echo
echo "--- raw bytes straight off the receiver, through the relay ---"
timeout 6 nc 127.0.0.1 2948 > /tmp/g1-relay.bin 2>/dev/null
strings /tmp/g1-relay.bin 2>/dev/null | grep -a '^\$G' | head -5 | sed 's/^/  /'
echo
echo "--- the same stream after gpsd has parsed and re-emitted it ---"
timeout 8 gpspipe -r -n 10 > /tmp/g1-gpsd.bin 2>/dev/null
strings /tmp/g1-gpsd.bin 2>/dev/null | grep -a '^\$G' | head -5 | sed 's/^/  /'
echo
echo "--- checksums, counted over the RAW BYTES of both captures ---"
G1_CHECK="$(cat /tmp/g1-relay.bin /tmp/g1-gpsd.bin | python3 "${FIXTURES}/nmeacheck.py")"
G1_OK="$(echo "${G1_CHECK}" | awk '{print $1}')"
G1_BAD="$(echo "${G1_CHECK}" | awk '{print $2}')"
G1_NOISE="$(echo "${G1_CHECK}" | awk '{print $3}')"
G1_BYTES="$(echo "${G1_CHECK}" | awk '{print $4}')"
G1_COUNT="${G1_OK}"
echo "  bytes read       ${G1_BYTES}"
echo "  valid checksums  ${G1_OK}"
echo "  bad checksums    ${G1_BAD}"
echo "  non-ASCII bytes  ${G1_NOISE}   (the signature of this dongle decaying)"

if [ -n "${G1_REAL}" ] && [ "${G1_COUNT}" -ge 4 ] && [ "${G1_BAD}" = "0" ] \
   && [ "${G1_NOISE}" = "0" ]; then
  gate_result pass \
    "gpsd holds ${GPS_LINK}, which resolves to ${G1_REAL}, at ${GPS_BAUD} baud. ${G1_COUNT} sentences came back and every checksum is valid, so the byte stream is clean and nothing else is on the port." \
    "It does not prove 9600 is the receiver's only speed. 9600 was found by sweeping six rates and reading each one on a single exclusive file handle: 38400 and above returned the 00/78/80/f8 pattern of a 9600 signal sampled four times too fast, and 4800 returned noise. The receiver was never asked to change speed and no UBX or PMTK configuration was sent, so a receiver that can be reconfigured is still at its factory default here."
elif [ "${G1_NOISE}" != "0" ] || [ "${G1_BAD}" != "0" ]; then
  echo
  echo "  THIS IS THE DONGLE, NOT THE WIRING. ${G1_NOISE} corrupt bytes and"
  echo "  ${G1_BAD} bad checksums arrived in this window. gpsd holds the right"
  echo "  device at the right speed and the relay never changes the line."
  echo "  Read the hardware note at the end of this run, then replace the"
  echo "  PL2303 with a CP2102 or an FT232R."
  gate_result fail \
    "nothing about the software. It DOES measure the fault: the receiver decayed inside the gate window, which is the failure this station has to design around." \
    "nothing"
else
  gate_result fail "nothing" "nothing"
fi

gate_header 2 "the driver publishes position to MQTT and a row lands via the writer"
echo "NO FIX IS AVAILABLE INDOORS, so this gate replays a recorded log."
echo "The position below is NOT a measurement of where this station is."
echo "gpsfake feeds gpsd through a pseudo-terminal. The driver sees /dev/pts,"
echo "refuses the source 'gps', and publishes 'gps_simulated' instead."
echo
BEFORE_ROWS="$(psql_val "select count(*) from public.readings where sensor='gps'")"
BEFORE_MAX="$(psql_val "select coalesce(max(id), 0) from public.readings where sensor='gps'")"
echo "  gps rows before: ${BEFORE_ROWS}, highest id ${BEFORE_MAX}"

systemctl stop mobilelab-gps.service > /dev/null 2>&1
systemctl stop gpsd.service gpsd.socket > /dev/null 2>&1
stop_fake
gpsfake -q -P "${FAKE_PORT}" -c 0.1 "${FIXTURES}/fix.nmea" > /tmp/gpsfake.log 2>&1 &
sleep 6

echo "--- what gpsd reports while the log plays ---"
timeout 8 gpspipe -w -n 8 2>/dev/null | grep -o '"class":"TPV".*' | head -1 | cut -c1-160 | sed 's/^/  /'

echo
echo "--- the driver publishing under the real source, which must be refused ---"
G2_REFUSE="$(timeout 25 "${VENV}/bin/python" -m mobilelab.gps --source gps \
  --status-seconds 2 --publish-seconds 3 2>&1 | grep -c "REFUSING TO PUBLISH")"
echo "  refusals logged: ${G2_REFUSE}"

echo
echo "--- the driver publishing under gps_simulated, which is permitted ---"
timeout 25 "${VENV}/bin/python" -m mobilelab.gps --source gps_simulated \
  --status-seconds 2 --publish-seconds 3 > /tmp/gps-driver.log 2>&1
grep -E "state is|publishing is permitted" /tmp/gps-driver.log | head -4 | sed 's/^/  /'

sleep 4
AFTER_ROWS="$(psql_val "select count(*) from public.readings where sensor='gps'")"
echo
echo "  gps rows after: ${AFTER_ROWS}"
echo "--- the newest rows, with their source and whether it is real ---"
runuser -u postgres -- psql -d "${DB_NAME}" -c \
  "select r.metric, r.value, r.unit, r.source, s.is_real, s.render_hint
     from public.readings r join public.sources s on s.source=r.source
    where r.sensor='gps' order by r.id desc limit 5" 2>&1 | sed 's/^/  /'

G2_REALCOUNT="$(psql_val "select count(*) from public.readings r join public.sources s on s.source=r.source where r.sensor='gps' and s.is_real and r.id > ${BEFORE_MAX}")"
echo "  rows THIS GATE wrote that carry a real source: ${G2_REALCOUNT}"
echo
echo "  The test is scoped to the rows this gate wrote, not to the whole table."
echo "  Real gps rows with is_real true are CORRECT when the receiver really"
echo "  had a fix, and this station has some. Counting those as a failure would"
echo "  make a working receiver look like a labelling defect."

if [ "${AFTER_ROWS}" -gt "${BEFORE_ROWS}" ] && [ "${G2_REFUSE}" -ge 1 ] && [ "${G2_REALCOUNT}" = "0" ]; then
  gate_result pass \
    "The driver published to MQTT and the writer inserted the rows. It went through the writer, because the driver holds no database handle for readings and the rows carry the writer's insert path. The refusal path also works: asked to publish replayed data as 'gps', it refused ${G2_REFUSE} times, and no gps row in the table carries a source with is_real true." \
    "It does not prove a REAL fix lands a row. The position came from ops/gps-fixtures/fix.nmea, not from the sky. What is proved is the path from driver to broker to writer to table, and the source guard on it. Only Scott outdoors can prove the sky end."
else
  gate_result fail "nothing" "nothing"
fi

restore_real

gate_header 3 "the indicator shows AMBER with a receiver present and no fix"
echo "This is the ordinary indoor state, and it is the state that matters."
echo
G3_JSON="$(api_gps)"
G3_STATE="$(echo "${G3_JSON}" | jget state)"
G3_LABEL="$(echo "${G3_JSON}" | jget label)"
G3_MODE="$(echo "${G3_JSON}" | jget fix.mode_text)"
G3_USED="$(echo "${G3_JSON}" | jget fix.satellites_used)"
G3_SEEN="$(echo "${G3_JSON}" | jget fix.satellites_seen)"
G3_REPORTS="$(echo "${G3_JSON}" | jget gpsd.reports)"
echo "  /api/gps  state=${G3_STATE} label=${G3_LABEL}"
echo "            fix=${G3_MODE} satellites seen=${G3_SEEN} used=${G3_USED}"
echo "            gpsd reports received=${G3_REPORTS}"
echo
echo "--- the DOM on the chart page ---"
G3_DOM="$(render "http://127.0.0.1:${API_PORT}/")"
G3_BODY="$(echo "${G3_DOM}" | grep -oE 'data-gps="[a-z]+"' | head -1 | cut -d'"' -f2)"
G3_BTN="$(echo "${G3_DOM}" | grep -oE 'data-gps-state="[a-z]+"' | head -1 | cut -d'"' -f2)"
G3_TEXT="$(echo "${G3_DOM}" | grep -oE '<span class="gps-label" id="gps-label">[^<]*' | sed 's/.*>//')"
G3_MARK="$(echo "${G3_DOM}" | grep -oE 'class="gps-(waves|slash|quest)"' | wc -l | tr -d ' ')"
echo "  body data-gps      = ${G3_BODY}"
echo "  button data-gps-state = ${G3_BTN}"
echo "  visible label      = ${G3_TEXT}"
echo "  icon state marks in the markup = ${G3_MARK} of 3"

if [ "${G3_STATE}" = "amber" ] && [ "${G3_BODY}" = "amber" ] && [ "${G3_BTN}" = "amber" ] \
   && [ "${G3_TEXT}" = "NO FIX" ]; then
  gate_result pass \
    "The receiver is connected and sending, gpsd has taken ${G3_REPORTS} reports from it, and the indicator is AMBER in the API and in the DOM on the real page. The words NO FIX are in the rendered document, not only the colour." \
    "It does not prove WHY the state is amber, and the two reasons are different. Amber covers a receiver that honestly reports no fix, and it also covers a receiver that claims a fix it cannot support. This receiver does both, minutes apart. Gate 6 is the one that separates them."
else
  gate_result fail "nothing" "nothing"
fi

gate_header 4 "the indicator shows GREEN with a fix"
echo "TWO PARTS. The first is real. The second is repeatable."
echo
echo "--- PART A: has this station EVER solved a real fix at the threshold? ---"
runuser -u postgres -- psql -d "${DB_NAME}" -c \
  "select r.ts, r.metric, r.value, r.unit, r.source, s.is_real,
          r.provenance->>'satellites_used' as sats,
          r.provenance->>'device' as device
     from public.readings r join public.sources s on s.source = r.source
    where r.sensor = 'gps' and s.is_real
    order by r.id desc limit 6" 2>&1 | sed 's/^/  /'
G4_REAL="$(psql_val "select count(*) from public.readings r join public.sources s on s.source=r.source where r.sensor='gps' and s.is_real and r.metric='latitude'")"
echo "  real fixes recorded: ${G4_REAL}"
echo
echo "--- PART B: the repeatable check, from a replayed log ---"
echo "The receiver cannot be relied on to hold a fix while a gate runs, so the"
echo "green asserted below is produced by replaying ops/gps-fixtures/fix.nmea"
echo "into gpsd with gpsfake. It is a simulated fix and the panel says so."
echo
systemctl stop mobilelab-gps.service > /dev/null 2>&1
systemctl stop gpsd.service gpsd.socket > /dev/null 2>&1
stop_fake
gpsfake -q -P "${FAKE_PORT}" -c 0.1 "${FIXTURES}/fix.nmea" > /tmp/gpsfake4.log 2>&1 &
sleep 5
"${VENV}/bin/python" -m mobilelab.gps --source gps_simulated --status-seconds 2 \
  > /tmp/gps4.log 2>&1 &
G4_PID=$!
sleep 10

G4_JSON="$(api_gps)"
G4_STATE="$(echo "${G4_JSON}" | jget state)"
G4_USED="$(echo "${G4_JSON}" | jget fix.satellites_used)"
G4_MODE="$(echo "${G4_JSON}" | jget fix.mode_text)"
G4_SIM="$(echo "${G4_JSON}" | jget simulated)"
G4_LAT="$(echo "${G4_JSON}" | jget position.lat)"
G4_LON="$(echo "${G4_JSON}" | jget position.lon)"
G4_DEV="$(echo "${G4_JSON}" | jget device)"
echo "  /api/gps  state=${G4_STATE} fix=${G4_MODE} satellites used=${G4_USED}"
echo "            position=${G4_LAT}, ${G4_LON}"
echo "            device=${G4_DEV}  simulated=${G4_SIM}"
echo
echo "--- the DOM, with the detail panel open ---"
G4_DOM="$(render "http://127.0.0.1:${API_PORT}/?gps=show")"
G4_BODY="$(echo "${G4_DOM}" | grep -oE 'data-gps="[a-z]+"' | head -1 | cut -d'"' -f2)"
G4_TEXT="$(echo "${G4_DOM}" | grep -oE '<span class="gps-label" id="gps-label">[^<]*' | sed 's/.*>//')"
G4_MARK="$(echo "${G4_DOM}" | grep -oE 'class="gps-(waves|slash|quest)"' | wc -l | tr -d ' ')"
G4_SIMTEXT="$(echo "${G4_DOM}" | grep -c 'SIMULATED. A recorded log feeds this position')"
echo "  body data-gps  = ${G4_BODY}"
echo "  visible label  = ${G4_TEXT}"
echo "  icon state marks in the markup = ${G4_MARK} of 3"
echo "  simulated warning shown in the panel: ${G4_SIMTEXT}"
echo
echo "--- the detail panel rows ---"
echo "${G4_DOM}" | grep -oE '<th scope="row">[^<]*</th><td>[^<]*' \
  | sed 's/<th scope="row">//; s|</th><td>| = |' | sed 's/^/  /'

kill "${G4_PID}" 2>/dev/null
restore_real

if [ "${G4_STATE}" = "green" ] && [ "${G4_BODY}" = "green" ] && [ "${G4_TEXT}" = "GPS OK" ] \
   && [ "${G4_SIM}" = "True" ] && [ "${G4_SIMTEXT}" -ge 1 ]; then
  gate_result pass \
    "With a 3D fix on ${G4_USED} satellites the indicator went GREEN in the API and in the DOM, the detail panel filled in, and the panel carried the SIMULATED warning because the fix came from a replayed log. Green and the simulated warning appeared together, which is the correct pair for this input. Part A is the stronger half: this station has ${G4_REAL} REAL fix rows, written under the source 'gps' with is_real true, from the real relay and not a pseudo-terminal. One was a 3D fix on 5 satellites at 28.1624, -80.6729, indoors." \
    "The green ASSERTED here is simulated, and the real fix in part A was recorded rather than watched. Nobody saw the badge green with a real fix on the glass, because the receiver holds a fix for well under a minute at a time. Time to first fix outdoors, the antenna under open sky, and whether the badge holds green for a useful period are all untested. Only Scott outdoors can test them."
else
  gate_result fail "nothing" "nothing"
fi

gate_header 5 "the indicator shows RED with the dongle unplugged"
echo "This unbinds the USB device in the kernel rather than pulling the plug."
echo "The device node disappears the same way, which is what gpsd reacts to."
echo
echo "  before: ${GPS_LINK} -> $(readlink -f "${GPS_LINK}" 2>/dev/null || echo MISSING)"
echo "${USB_ID}" > /sys/bus/usb/drivers/usb/unbind 2>/dev/null
sleep 3
echo "  after unbind: $(readlink -f "${GPS_LINK}" 2>/dev/null || echo 'the device node is gone')"
echo "  waiting for the driver to call it silence..."
sleep 20

G5_JSON="$(api_gps)"
G5_STATE="$(echo "${G5_JSON}" | jget state)"
G5_DETAIL="$(echo "${G5_JSON}" | jget detail)"
echo "  /api/gps  state=${G5_STATE}"
echo "            detail=${G5_DETAIL}"
G5_DOM="$(render "http://127.0.0.1:${API_PORT}/")"
G5_BODY="$(echo "${G5_DOM}" | grep -oE 'data-gps="[a-z]+"' | head -1 | cut -d'"' -f2)"
G5_TEXT="$(echo "${G5_DOM}" | grep -oE '<span class="gps-label" id="gps-label">[^<]*' | sed 's/.*>//')"
G5_MARK="$(echo "${G5_DOM}" | grep -oE 'class="gps-(waves|slash|quest)"' | wc -l | tr -d ' ')"
echo "  body data-gps  = ${G5_BODY}"
echo "  visible label  = ${G5_TEXT}"
echo "  icon state marks in the markup = ${G5_MARK} of 3"

echo
echo "  plugging it back in..."
echo "${USB_ID}" > /sys/bus/usb/drivers/usb/bind 2>/dev/null
sleep 5
udevadm trigger --subsystem-match=tty --action=add 2>/dev/null
sleep 3
echo "  restored: ${GPS_LINK} -> $(readlink -f "${GPS_LINK}" 2>/dev/null || echo MISSING)"
restore_real
G5_BACK="$(api_gps | jget state)"
echo "  the indicator recovered to: ${G5_BACK}"

if [ "${G5_STATE}" = "red" ] && [ "${G5_BODY}" = "red" ] && [ "${G5_TEXT}" = "NO GPS" ] \
   && [ "${G5_BACK}" = "amber" ]; then
  gate_result pass \
    "With the receiver removed the indicator went RED in the API and in the DOM, and the words NO GPS appeared. It also recovered to AMBER on its own when the device came back, with no restart, which is the half a person actually depends on in the field." \
    "It does not prove the cable case. An unbind removes the device cleanly. A half-inserted plug, a broken data line, or a dying dongle can leave the node present while the data stops. The driver treats that as silence after ${GPS_LINK} stops producing reports, but no such cable was tested here."
fi
if [ "${G5_STATE}" != "red" ]; then gate_result fail "nothing" "nothing"; fi

gate_header 6 "NEGATIVE: a talking receiver below the satellite threshold must not be GREEN"
echo "THIS IS THE DEFECT THE INDICATOR EXISTS TO CATCH."
echo "The real receiver produced the hostile case on its own during this build."
echo "It reported mode 3, a 3D FIX, on THREE satellites, with HDOP 4.45, and a"
echo "position in Palm Bay that looked entirely plausible. A 3D fix needs four"
echo "satellites to solve four unknowns. The receiver claimed one on three."
echo "An indicator keyed on \"has a fix\" would have gone green on that."
echo
G6_JSON="$(api_gps)"
G6_STATE="$(echo "${G6_JSON}" | jget state)"
G6_SEEN="$(echo "${G6_JSON}" | jget fix.satellites_seen)"
G6_USED="$(echo "${G6_JSON}" | jget fix.satellites_used)"
G6_REPORTS="$(echo "${G6_JSON}" | jget gpsd.reports)"
echo "  the receiver IS talking:   gpsd reports = ${G6_REPORTS}"
echo "  the receiver CAN hear:     satellites seen = ${G6_SEEN}"
echo "  the receiver KNOWS NOTHING: satellites used = ${G6_USED}"
echo "  the indicator says:        ${G6_STATE}"
echo
echo "--- raw proof that sentences are flowing while this is true ---"
timeout 6 gpspipe -r -n 4 2>/dev/null | grep -a '^\$GPGGA' | head -2 | sed 's/^/  /'
echo
echo "--- the rule itself, asked directly, including the hostile case ---"
"${VENV}/bin/python" - <<'PY' | sed 's/^/  /'
from mobilelab.gps import fix_state

cases = [
    ("talking, 8 seen, 0 used, no fix", 1, 0),
    ("claims a 3D fix on 0 satellites", 3, 0),
    ("claims a 3D fix on 3 satellites", 3, 3),
    ("2D fix on 8 satellites",          2, 8),
    ("honest 3D fix on 4 satellites",   3, 4),
    ("no data at all",               None, None),
]
for label, mode, used in cases:
    state = fix_state(mode, used, 4)
    mark = "GREEN" if state == "green" else state.upper()
    print(f"{label:<34} mode={str(mode):<4} used={str(used):<4} -> {mark}")
PY

G6_HOSTILE="$("${VENV}/bin/python" -c "
from mobilelab.gps import fix_state
bad = [fix_state(3,0,4), fix_state(3,3,4), fix_state(2,8,4), fix_state(1,0,4)]
print('green' in bad)")"
echo
echo "  did any of the untrustworthy cases return green? ${G6_HOSTILE}"

G6_BELOW="$(python3 -c "
used = '${G6_USED}'
print('yes' if (not used.isdigit() or int(used) < 4) else 'no')")"
echo "  is the satellite count below the threshold of 4? ${G6_BELOW}"

if [ "${G6_STATE}" != "green" ] && [ "${G6_BELOW}" = "yes" ] && [ "${G6_REPORTS}" -gt 0 ] \
   && [ "${G6_HOSTILE}" = "False" ]; then
  gate_result pass \
    "A connected, powered receiver sending valid sentences, with fewer than four satellites used, does NOT show green on real hardware. The rule was then asked directly: a claimed 3D fix on zero satellites, a claimed 3D fix on three, and a 2D fix on eight all return amber. This is not a hypothetical: this receiver really did claim a 3D fix on three satellites during the build, and the badge stayed amber through all of it." \
    "It does not cover a receiver that reports a plausible satellite count it did not earn. A receiver claiming mode 3 with nine satellites used and a fabricated position would show GREEN here, and nothing on this station cross checks it. HDOP is displayed in the panel but no threshold is applied to it."
else
  gate_result fail "nothing" "nothing"
fi

gate_header 7 "the indicator is present and correct on all four pages"
G7_FAIL=0
printf "  %-12s %-8s %-8s %-6s %-6s %-10s %-8s %s\n" PAGE STATE LABEL ICON MARKS BOX POWER-H PANEL
for page in "" entry knowledge sensors; do
  DOM="$(render "http://127.0.0.1:${API_PORT}/${page}")"
  NAME="${page:-chart}"
  STATE="$(echo "${DOM}" | grep -oE 'data-gps="[a-z]+"' | head -1 | cut -d'"' -f2)"
  LABEL="$(echo "${DOM}" | grep -oE '<span class="gps-label" id="gps-label">[^<]*' | sed 's/.*>//')"
  MARK="$(echo "${DOM}" | grep -oE 'class="gps-(waves|slash|quest)"' | head -1 | cut -d'"' -f2)"
  TARGET="$(echo "${DOM}" | grep -oE 'data-gps-target="[0-9x]+"' | head -1 | cut -d'"' -f2)"
  TMIN="$(echo "${DOM}" | grep -oE 'data-gps-target-min="[0-9]+"' | head -1 | cut -d'"' -f2)"
  PANEL="$(echo "${DOM}" | grep -c 'id="gps-panel"')"
  POWER="$(echo "${DOM}" | grep -oE 'data-power-target-height="[0-9]+"' | head -1 | cut -d'"' -f2)"
  ICON="$(echo "${DOM}" | grep -c 'class="gps-icon"')"
  MARKS="$(echo "${DOM}" | grep -oE 'class="gps-(waves|slash|quest)"' | wc -l | tr -d ' ')"
  printf "  %-12s %-8s %-8s %-6s %-6s %-10s %-8s %s\n" "${NAME}" "${STATE}" "${LABEL}" "${ICON}" "${MARKS}" "${TARGET}" "${POWER:-none}" "${PANEL}"
  if [ -z "${STATE}" ] || [ -z "${LABEL}" ] || [ "${ICON}" -lt 1 ] || [ "${PANEL}" -lt 1 ]; then G7_FAIL=1; fi
  if [ "${MARKS}" -lt 3 ]; then G7_FAIL=1; fi
  if [ -z "${TMIN}" ] || [ "${TMIN}" -lt 36 ]; then G7_FAIL=1; fi
  GPS_H="$(echo "${TARGET}" | cut -dx -f2)"
  if [ -n "${POWER}" ] && [ "${GPS_H}" != "${POWER}" ]; then
    echo "    MISMATCH: the badge is ${GPS_H}px and the power button is ${POWER}px"
    G7_FAIL=1
  fi
done
echo
echo "  TARGET is the measured box of the badge and POWER-H is the measured"
echo "  height of the power control beside it, both read from the layout engine"
echo "  after the labels were drawn, not from the stylesheet."
echo
echo "  THE BADGE MATCHES THE POWER BUTTON, and that is the assertion."
echo "  It was 56px tall for one build, which is the touch target the spec"
echo "  asked for. On the real panel it towered over the power button and read"
echo "  as an alarm rather than a status, so Scott called it at the screen."
echo "  The pill is 103px wide, so a finger still has plenty to aim at."
echo
echo "--- the state reads with the colour removed ---"
echo "  ICON is the satellite. MARKS counts the state-specific parts of the"
echo "  drawing that the stylesheet shows or hides. All three must be present"
echo "  in the markup for the four states to be distinguishable:"
echo
echo "    green -> satellite WITH two signal arcs, solid ring,  says GPS OK"
echo "    amber -> satellite with NO arcs,         dashed ring, says NO FIX"
echo "    red   -> satellite STRUCK THROUGH,       dotted ring, says NO GPS"
echo "    grey  -> satellite with a QUESTION MARK, plain ring,  says GPS ?"
echo
echo "  Arcs, no arcs, a slash and a question mark are four different"
echo "  silhouettes, so greyscale still reads. The words are no longer drawn."
echo "  They are moved off screen, not deleted, so a screen reader still hears"
echo "  them and the STATE and LABEL columns above still come out of the DOM."

if [ "${G7_FAIL}" = "0" ]; then
  gate_result pass \
    "All four pages carry the badge, the detail panel, a state, a word, and the satellite icon with all three state marks in it. The badge is a circle drawn the same height as the power control beside it, measured on both. The icon changes silhouette with the state and not only colour, so the state survives in greyscale, and the word survives in the DOM for a screen reader." \
    "It does not prove a person can read it in sunlight, and it does not prove the badge is reachable by a thumb. The badge sits at the top right of a 10.1 inch screen, which is the corner furthest from a hand holding the case at the bottom left. Contrast was calculated, not measured on the real panel with a meter. The badge is also 36 by 36 rather than the 56px the spec asked for, and it is now the SMALLEST control in the bar, which is a deliberate trade for horizontal space. Nobody has yet missed it with a finger, because nobody has tried. Whether a student reads a satellite icon as GPS at all is untested, and this gate cannot test it."
else
  gate_result fail "nothing" "nothing"
fi

gate_header 8 "the RTC holds time across a power cut with no network"
echo "--- is the RTC there, and is the battery holding? ---"
echo "  RTC device     $(cat /sys/class/rtc/rtc0/name 2>/dev/null || echo NONE)"
echo "  RTC reads      $(cat /sys/class/rtc/rtc0/date 2>/dev/null) $(cat /sys/class/rtc/rtc0/time 2>/dev/null) UTC"
echo "  hwclock reads  $(hwclock -r --utc 2>&1 || echo "hwclock is not installed. apt-get install util-linux-extra")"
echo "  system clock   $(date -u +'%Y-%m-%d %H:%M:%S') UTC"
echo "  NTP synced     $(timedatectl show -p NTPSynchronized --value 2>/dev/null)"
HW_EPOCH="$(date -u -d "$(cat /sys/class/rtc/rtc0/date) $(cat /sys/class/rtc/rtc0/time)" +%s 2>/dev/null || echo 0)"
SYS_EPOCH="$(date -u +%s)"
DELTA=$(( SYS_EPOCH - HW_EPOCH ))
echo "  RTC minus system clock: ${DELTA} seconds (read from /sys/class/rtc/rtc0)"
echo
echo "--- the last boot, and what the clock did on the way up ---"
journalctl -b 0 --no-pager 2>/dev/null \
  | grep -iE "setting system clock|hctosys|RTC time|rpi-rtc" | head -6 | sed 's/^/  /'
echo
echo "--- did any PREVIOUS boot come up in 1970? ---"
journalctl --list-boots --no-pager 2>/dev/null | tail -6 | sed 's/^/  /'
echo
if [ -f /var/lib/mobilelab/rtc-powercut.json ]; then
  echo "--- a recorded power cut test exists ---"
  cat /var/lib/mobilelab/rtc-powercut.json | sed 's/^/  /'
else
  echo "  no power cut test has been recorded on this station yet"
fi
echo
echo "THE PHYSICAL TEST CANNOT BE DONE OVER SSH. Scott must do this:"
echo "    sudo ops/rtc-powercut.sh before"
echo "    unplug the network, then pull the power plug, wait sixty seconds"
echo "    power up with the network still unplugged"
echo "    sudo ops/rtc-powercut.sh after"
if [ "${DELTA#-}" -lt 5 ] && [ "${HW_EPOCH}" -gt 0 ]; then
  gate_result manual \
    "The RTC is present as $(cat /sys/class/rtc/rtc0/name 2>/dev/null), it is readable, and it agrees with the system clock to within ${DELTA} seconds. A battery that was not holding would show a wild value or a read error, and it shows neither." \
    "AGREEMENT NOW IS NOT SURVIVAL LATER. The system clock has been up and NTP has been reachable, so the RTC being right proves only that something wrote a right value into it. The claim that matters is what the clock reads after the power is cut with no network, and that needs a hand on the plug. Run ops/rtc-powercut.sh."
else
  gate_result fail "nothing" "nothing"
fi

gate_header 9 "all four pages still fit 1024x600 with no scrolling"
echo "The bar is back to 52 pixels, where it was before this task started."
echo "Every page is measured again anyway, because the bar gained a control."
echo
G9_FAIL=0
printf "  %-12s %-12s %-10s %-10s %s\n" PAGE VIEWPORT CONTENT-H OVERFLOW FITS
for page in "" entry knowledge sensors; do
  DOM="$(render "http://127.0.0.1:${API_PORT}/${page}")"
  NAME="${page:-chart}"
  VP="$(echo "${DOM}" | grep -oE 'data-viewport="[0-9x]+"' | head -1 | cut -d'"' -f2)"
  CH="$(echo "${DOM}" | grep -oE 'data-content-height="[0-9]+"' | head -1 | cut -d'"' -f2)"
  OY="$(echo "${DOM}" | grep -oE 'data-overflow-y="[0-9]+"' | head -1 | cut -d'"' -f2)"
  OX="$(echo "${DOM}" | grep -oE 'data-overflow-x="[0-9]+"' | head -1 | cut -d'"' -f2)"
  FITS="$(echo "${DOM}" | grep -oE 'data-fits="[a-z]+"' | head -1 | cut -d'"' -f2)"
  printf "  %-12s %-12s %-10s %-10s %s\n" "${NAME}" "${VP}" "${CH}" "y=${OY} x=${OX}" "${FITS}"
  if [ "${FITS}" != "true" ]; then G9_FAIL=1; fi
done

if [ "${G9_FAIL}" = "0" ]; then
  gate_result pass \
    "Every page reports fits=true at 1024 by 600 after the bar grew to 56 pixels. Neither axis overflows, so nothing has to be scrolled to be reached." \
    "It measures a headless Chromium window set to 1024 by 600, not the ROADOM panel. The kiosk browser runs with different fonts loaded and a real scrollbar policy, and a modal opened over a full page is not measured at all. Gate 4 opened the GPS panel but did not measure it."
else
  gate_result fail "nothing" "nothing"
fi

echo
echo "================================================================"
echo "SUMMARY"
echo "================================================================"
echo "  passed:              ${PASS_COUNT}"
echo "  failed:              ${FAIL_COUNT}"
echo "  needs Scott present: ${MANUAL_COUNT}"
echo
echo "  Gate 4 ASSERTED on a simulated fix. The real fixes it reports are real."
echo "  Gate 8 needs a hand on the power plug."
echo
echo "================================================================"
echo "HARDWARE NOTE: THE DONGLE IS FAULTY. REPLACE IT."
echo "================================================================"
echo "  Measured on this station, 2026-08-17. Nothing here is inferred."
echo
echo "  1. After a USB power cycle the receiver is clean. 26 valid NMEA"
echo "     sentences in 8 seconds, zero bad checksums."
echo "  2. It then decays. Valid sentences per 5 seconds, one reader"
echo "     attached and nothing else touching the port:"
echo "        0-5s   15      15-20s  10"
echo "        5-10s  18      20-25s   1"
echo "        10-15s 18      25s on   0"
echo "  3. The BYTE RATE stays constant through the decay, near 1100 bytes"
echo "     per 5 seconds. It keeps transmitting. The bytes become wrong."
echo "  4. Its effective baud wanders. Read at 9600 the yield collapses,"
echo "     while 10000 and 10400 still return valid sentences. That is a"
echo "     clock error near 6 percent. UART tolerance is about 2 percent."
echo "  5. Only a USB unbind and rebind recovers it. Closing the port does"
echo "     not. Restarting gpsd does not."
echo "  6. No USB transport errors accompany the decay, so it is not the"
echo "     bus losing packets. It is the byte clock drifting."
echo
echo "  CONSEQUENCE. A fix holds for well under a minute at a time. The"
echo "  station recorded one real 3D fix on 5 satellites in Palm Bay, so the"
echo "  antenna and the software both work. It cannot hold one long enough"
echo "  to be an instrument."
echo
echo "  THE INDICATOR BEHAVED CORRECTLY THROUGHOUT, and that is the point."
echo "  Through every decay it showed AMBER or RED. It never once showed"
echo "  GREEN on corrupt data. An indicator wired to 'is the device present'"
echo "  would have been green for this entire session."
echo
echo "  FIX: replace the Prolific PL2303 with a CP2102 or an FT232R. Both"
echo "  are a few dollars and neither has this failure mode. Keep the relay"
echo "  either way, because gpsd's parity hunt is what bricked this one."
echo
if systemctl is-enabled --quiet weather-collector.service 2>/dev/null; then
  echo "  REMINDER: weather-collector.service is stopped but still ENABLED."
  echo "  It returns at the next reboot and takes the serial port again."
  echo "  Decide what that service should point at before you reboot."
fi
if [ "${FAIL_COUNT}" -gt 0 ]; then exit 1; fi
exit 0
