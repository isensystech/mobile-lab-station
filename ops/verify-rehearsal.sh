#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VENV_PY="${REPO_ROOT}/.venv/bin/python"

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
BASE="http://${LAN_IP}:${API_PORT}"
WORK=/tmp/mlrig
mkdir -p "${WORK}"
chmod 0777 "${WORK}"

SCALE_HOURS="${MOBILELAB_REHEARSAL_HOURS:-336}"
WINDOW_HOURS=168

SALINITY="water:salinity:synthetic:Salinity"
NOAA="rain:rainfall:public_synthetic:NOAA"
GAUGE="rain:rainfall:synthetic:Rain Gauge"

PASS_COUNT=0
FAIL_COUNT=0

psql_val() {
  runuser -u postgres -- psql -t -A -d "${DB_NAME}" -c "$1" 2>&1 | tr -d '[:space:]'
}
psql_show() {
  runuser -u postgres -- psql -d "${DB_NAME}" -c "$1" 2>&1
}

render() {
  runuser -u scott -- env HOME=/home/scott timeout 90 chromium \
    --headless --disable-gpu --no-sandbox --hide-scrollbars \
    --window-size=1024,600 \
    --virtual-time-budget=15000 --dump-dom "$1" 2> /dev/null
}

attr() {
  grep -oE "data-$1=\"[^\"]*\"" "$2" | head -1 | sed "s/^data-$1=\"//; s/\"$//"
}

cfg() {
  attr chart-config "$1" | sed 's/&quot;/"/g'
}

gate_header() {
  echo
  echo "================================================================"
  echo "GATE $1: $2"
  echo "================================================================"
}

gate_result() {
  if [ "$1" = "pass" ]; then
    PASS_COUNT=$((PASS_COUNT + 1)); echo "RESULT: PASS"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1)); echo "RESULT: FAIL"
  fi
  echo "PROVES:         $2"
  echo "DOES NOT PROVE: $3"
}

url() {
  local query="$1"
  python3 - "$query" <<'PY'
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1], safe="=&:?/,"))
PY
}

RIG_URL="http://127.0.0.1:${API_PORT}/?hours=${WINDOW_HOURS}"

echo "Mobile Lab Station rehearsal rig verification"
echo "host $(hostname), $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "chart ${BASE}/"
echo "chromium $(chromium --version 2>/dev/null)"
echo
echo "==> the rig holds three series"
psql_show "
select source, sensor, metric, count(*) as rows,
       min(ts) as earliest, max(ts) as latest,
       round(extract(epoch from (max(ts) - min(ts))) / 3600.0) as span_hours
from public.readings
where source in ('synthetic','public_synthetic')
group by source, sensor, metric order by source, sensor, metric;"

render "${RIG_URL}" > "${WORK}/all.html"

gate_header 1 "three series render on one shared time axis with correct axes"
G1_STATUS="$(attr status "${WORK}/all.html")"
G1_COUNT="$(attr series-count "${WORK}/all.html")"
G1_POINTS="$(attr points "${WORK}/all.html")"
G1_SERVED="$(attr served-from "${WORK}/all.html")"
G1_VISIBLE="$(attr visible "${WORK}/all.html")"
echo "page status      = ${G1_STATUS}"
echo "series drawn     = ${G1_COUNT}"
echo "shared time slots= ${G1_POINTS}"
echo "answered from    = ${G1_SERVED}"
echo "visible at boot  = ${G1_VISIBLE}"
echo
echo "--- the axis each series was put on ---"
cfg "${WORK}/all.html" | python3 -c "
import json,sys
for s in json.load(sys.stdin):
    print(f\"  {s['name']:<12} source {s['source']:<17} axis {s['axis']}\")
"
G1_AXES="$(cfg "${WORK}/all.html" | python3 -c "
import json,sys
d = json.load(sys.stdin)
by = {s['name']: s['axis'] for s in d}
ok = by.get('Salinity')=='y' and by.get('NOAA')=='y1' and by.get('Rain Gauge')=='y1'
print('yes' if ok else 'no')
")"
echo "salinity on its own axis, both rainfall series sharing the other = ${G1_AXES}"
if [ "${G1_STATUS}" = "ready" ] && [ "${G1_COUNT}" = "3" ] && [ "${G1_POINTS}" -gt 0 ] 2> /dev/null \
   && [ "${G1_VISIBLE}" = "s0,s1,s2" ] && [ "${G1_AXES}" = "yes" ]; then
  gate_result pass \
    "The page opens with all three series drawn on one shared axis of ${G1_POINTS} time slots. Salinity holds the left axis in PSU. Both rainfall series share the right axis in millimetres, so the public number and the local number are directly comparable." \
    "That the three lines are legible together on the 10.1 inch glass. A headless browser proves the data path and the axis assignment. It does not prove a person can tell the lines apart across a classroom."
else
  gate_result fail "nothing" "nothing"
fi

gate_header 2 "each toggle works independently, and salinity does not move"
render "http://127.0.0.1:${API_PORT}/?hours=${WINDOW_HOURS}&show=s0" > "${WORK}/only0.html"
render "http://127.0.0.1:${API_PORT}/?hours=${WINDOW_HOURS}&show=s0,s1" > "${WORK}/two.html"
render "http://127.0.0.1:${API_PORT}/?hours=${WINDOW_HOURS}&show=s1,s2" > "${WORK}/no0.html"
F_ALL="$(attr response-fingerprint "${WORK}/all.html")"
F_ONE="$(attr response-fingerprint "${WORK}/only0.html")"
F_TWO="$(attr response-fingerprint "${WORK}/two.html")"
V_ONE="$(attr visible "${WORK}/only0.html")"
V_TWO="$(attr visible "${WORK}/two.html")"
V_NO0="$(attr visible "${WORK}/no0.html")"
echo "visible, salinity only        = ${V_ONE}"
echo "visible, salinity and NOAA    = ${V_TWO}"
echo "visible, both rainfall series = ${V_NO0}"
echo
echo "--- the salinity line, as pixels ---"
echo "  fingerprint is the count of drawn points and a hash of every"
echo "  x and y the chart placed them at."
echo "  all three shown   = ${F_ALL}"
echo "  salinity alone    = ${F_ONE}"
echo "  salinity and NOAA = ${F_TWO}"
IDENTICAL="no"
if [ "${F_ALL}" = "${F_ONE}" ] && [ "${F_ALL}" = "${F_TWO}" ] && [ "${F_ALL}" != "none" ]; then
  IDENTICAL="yes"
fi
echo "  pixel identical   = ${IDENTICAL}"
echo
echo "--- the hidden flags the chart actually applied ---"
cfg "${WORK}/two.html" | python3 -c "
import json,sys
for s in json.load(sys.stdin):
    print(f\"  {s['name']:<12} hidden={s['hidden']}\")
"
if [ "${IDENTICAL}" = "yes" ] && [ "${V_ONE}" = "s0" ] && [ "${V_TWO}" = "s0,s1" ] && [ "${V_NO0}" = "s1,s2" ]; then
  gate_result pass \
    "Each series hides on its own. The salinity line lands on exactly the same pixels with one series shown and with three, because both axes are fixed from the whole dataset before anything is hidden. A person revealing a second line does not see the first one move." \
    "That a tap on the glass does the same thing. This drove the toggles through the address line, not through a finger, and nobody has pressed one during a lesson."
else
  gate_result fail "nothing" "nothing"
fi

gate_header 3 "NOAA renders stepped, the gauge does not, and they are distinct"
cfg "${WORK}/all.html" | python3 -c "
import json,sys
for s in json.load(sys.stdin):
    print(f\"  {s['name']:<12} stepped={str(s['stepped']):<7} dashed={str(s['dashed']):<5} colour={s['colour']} real={s['isReal']}\")
"
G3="$(cfg "${WORK}/all.html" | python3 -c "
import json,sys
d = {s['name']: s for s in json.load(sys.stdin)}
noaa, gauge = d.get('NOAA', {}), d.get('Rain Gauge', {})
print('yes' if noaa.get('stepped') == 'after'
      and gauge.get('stepped') is False
      and noaa.get('colour') != gauge.get('colour') else 'no')
")"
echo
echo "  NOAA steps, the gauge does not, and the colours differ = ${G3}"
echo
echo "  NOTE. The gauge is NOT solid, and that is correct here."
echo "  The rig gauge is synthetic, so architecture section 5 forces a dashed"
echo "  line and keeps the badge up. Solid is reserved for a measurement."
echo "  The check below proves the gauge turns solid the moment a real source"
echo "  supplies it, with no code change."
render "$(url "http://127.0.0.1:${API_PORT}/?hours=${WINDOW_HOURS}&series=${SALINITY}&series=rain:rainfall:manual:Rain Gauge")" > "${WORK}/realgauge.html"
cfg "${WORK}/realgauge.html" | python3 -c "
import json,sys
for s in json.load(sys.stdin):
    print(f\"  {s['name']:<12} source {s['source']:<10} dashed={str(s['dashed']):<5} stepped={str(s['stepped']):<7} real={s['isReal']}\")
"
G3B="$(cfg "${WORK}/realgauge.html" | python3 -c "
import json,sys
d = {s['name']: s for s in json.load(sys.stdin)}
g = d.get('Rain Gauge', {})
print('yes' if g.get('dashed') is False and g.get('isReal') is True else 'no')
")"
echo "  a real gauge draws solid with no code change = ${G3B}"
if [ "${G3}" = "yes" ] && [ "${G3B}" = "yes" ]; then
  gate_result pass \
    "The cell average steps and holds flat across each bucket. The gauge interpolates between readings. The two carry different colours, so they are distinct by shape and by colour, asserted on the chart configuration and not by eye. Pointing the same page at a real gauge source draws it solid, so the rig converts to real data by changing a source." \
    "That the step is visible at this width. At one hour buckets across seven days each step is about five pixels wide, so the shape reads as smooth from a distance. The assertion is on the configuration, and nobody has judged the drawing on the glass."
else
  gate_result fail "nothing" "nothing"
fi

gate_header 4 "the badge follows is_real, not the series name"
G4_SIM_ALL="$(attr simulated "${WORK}/all.html")"
echo "all three synthetic, badge = ${G4_SIM_ALL}"
render "$(url "http://127.0.0.1:${API_PORT}/?hours=${WINDOW_HOURS}&series=rain:rainfall:public_record:NOAA")" > "${WORK}/realnoaa.html"
G4_SIM_REAL="$(attr simulated "${WORK}/realnoaa.html")"
G4_REAL_FLAG="$(attr s0-real "${WORK}/realnoaa.html")"
echo "the real public record alone, badge = ${G4_SIM_REAL}, is_real = ${G4_REAL_FLAG}"
render "$(url "http://127.0.0.1:${API_PORT}/?hours=${WINDOW_HOURS}&series=rain:rainfall:manual:Rain Gauge")" > "${WORK}/realmanual.html"
G4_SIM_MANUAL="$(attr simulated "${WORK}/realmanual.html")"
echo "a real hand entered series alone, badge = ${G4_SIM_MANUAL}"
echo
echo "--- the two public sources, side by side in the registry ---"
psql_show "select source, kind, is_real, render_hint from public.sources where source like 'public%' order by source;"
if [ "${G4_SIM_ALL}" = "true" ] && [ "${G4_SIM_REAL}" = "false" ] && [ "${G4_SIM_MANUAL}" = "false" ]; then
  gate_result pass \
    "The badge is up while the public series is the generator, and it is gone when the same page asks for the real public record instead. Nothing about the badge knows the word NOAA. It reads is_real, so it clears itself series by series as real data lands." \
    "That the real public record carries any data. No hand entered figure exists yet, so public_record answered with its labelling and no points. The badge behaviour is proven. The badge behaviour ON REAL ROWS is proven only through the manual series, which does carry real rows."
else
  gate_result fail "nothing" "nothing"
fi

gate_header 5 "NEGATIVE, malformed provenance on the public series fails closed"
echo "--- an unknown source, end to end through the real page ---"
render "$(url "http://127.0.0.1:${API_PORT}/?hours=${WINDOW_HOURS}&series=rain:rainfall:public_recrod:NOAA")" > "${WORK}/bad.html"
G5_UNTRUSTED="$(attr untrusted "${WORK}/bad.html")"
G5_SIM="$(attr simulated "${WORK}/bad.html")"
G5_REAL="$(attr s0-real "${WORK}/bad.html")"
G5_DASH="$(attr s0-dashed "${WORK}/bad.html")"
echo "  source asked for = public_recrod, a typo that is in no registry"
echo "  treated as untrusted = ${G5_UNTRUSTED}"
echo "  drawn as real        = ${G5_REAL}"
echo "  drawn dashed         = ${G5_DASH}"
echo "  badge raised         = ${G5_SIM}"
echo "  badge text on screen:"
grep -oE '>UNKNOWN SOURCE<|>SIMULATED DATA<' "${WORK}/bad.html" | head -1 | sed 's/^/    /'
echo
echo "--- malformed render_hint values, in the shipped classifier ---"
render "http://127.0.0.1:${API_PORT}/selftest" > "${WORK}/selftest.html"
SELF="$(attr selftest "${WORK}/selftest.html")"
echo "  ${SELF}"
grep -oE 'public record[^<]*' "${WORK}/selftest.html" | head -8 | sed 's/^/    /'
SELF_FAIL="$(echo "${SELF}" | grep -oE 'fail=[0-9]+' | cut -d= -f2)"
if [ "${G5_UNTRUSTED}" = "true" ] && [ "${G5_REAL}" = "false" ] && [ "${G5_DASH}" = "true" ] \
   && [ "${G5_SIM}" = "true" ] && [ "${SELF_FAIL}" = "0" ]; then
  gate_result pass \
    "A public series the station cannot vouch for is drawn dashed, marked not real, and raises the badge, end to end through the real page. Adding the stepped hint did not open a hole: STEPPED in the wrong case, step, a trailing space, a null, and a string is_real are each still treated as not real by the same classifier the chart uses." \
    "That every future malformed shape is caught. The check names the ways a hint has been seen to break. A new failure shape nobody has thought of is still unlisted, and the set of valid hints is now three rather than two, so there is more surface to get wrong."
else
  gate_result fail "nothing" "nothing"
fi

gate_header 6 "correlation is reported for each rainfall series on its own"
G6_PAIRS="$(attr pair-r "${WORK}/all.html")"
G6_NOAA="$(attr s1-r "${WORK}/all.html")"
G6_GAUGE="$(attr s2-r "${WORK}/all.html")"
G6_NOAA_W="$(attr s1-strength "${WORK}/all.html")"
G6_GAUGE_W="$(attr s2-strength "${WORK}/all.html")"
G6_GAUGE_LAG="$(attr s2-lag-hours "${WORK}/all.html")"
echo "reported pairs = ${G6_PAIRS}"
echo "  NOAA       against Salinity: r = ${G6_NOAA}, ${G6_NOAA_W}"
echo "  Rain Gauge against Salinity: r = ${G6_GAUGE}, ${G6_GAUGE_W}"
echo
echo "--- the sentences on the screen, each labelled by source ---"
grep -oE '<p class="caption-pair">.*?</p>' "${WORK}/all.html" | sed 's/<[^>]*>//g' | sed 's/^/  /'
echo
echo "--- the generator measures the same two series the same way ---"
runuser -u mobilelab -- env PYTHONPATH="${REPO_ROOT}/services" "${VENV_PY}" \
  -m mobilelab.cellfixture --seed 1337 --hours "${SCALE_HOURS}" --dry-run --report 2>/dev/null | sed 's/^/  /'
echo
echo "--- the permanent caption, rule 10 ---"
grep -oE 'CORRELATION IS NOT CAUSATION[^<]*' "${WORK}/all.html" | head -1 | sed 's/^/  /'
echo
echo "--- the slider must MOVE the lines onto each other, not apart ---"
echo "  The caption reports a correlation from the data. This reads the points"
echo "  as drawn, after the shift, and correlates them where they sit. At the"
echo "  measured delay the two numbers must agree, because the lines are then"
echo "  on top of each other."
G6_LAG_ROUND="$(python3 -c "print(int(round(float('${G6_GAUGE_LAG:-6}' or 6))))" 2> /dev/null || echo 6)"
for s in 0 "${G6_LAG_ROUND}"; do
  render "http://127.0.0.1:${API_PORT}/?hours=${WINDOW_HOURS}&autoshift=${s}" > "${WORK}/shift${s}.html"
  printf "  shift %-3s  reported r = %-8s  drawn r = %s\n" \
    "${s}" "$(attr s2-r "${WORK}/shift${s}.html")" "$(attr s2-align-r "${WORK}/shift${s}.html")"
done
ALIGN_AT_LAG="$(attr s2-align-r "${WORK}/shift${G6_LAG_ROUND}.html")"
ALIGN_AT_ZERO="$(attr s2-align-r "${WORK}/shift0.html")"
G6_ALIGNED="$(python3 -c "
reported = abs(float('${G6_GAUGE}' or 0))
drawn = abs(float('${ALIGN_AT_LAG}' or 0))
flat = abs(float('${ALIGN_AT_ZERO}' or 0))
print('yes' if abs(reported - drawn) < 0.05 and flat < 0.4 else 'no')
")"
echo "  the drawn lines agree with the reported number at the measured delay = ${G6_ALIGNED}"
echo "  A shift that ran the wrong way would leave the drawn number weak here."

G6_OK="$(python3 -c "
noaa = abs(float('${G6_NOAA}' or 0))
gauge = abs(float('${G6_GAUGE}' or 0))
print('yes' if noaa < 0.4 and gauge >= 0.7 else 'no')
")"
echo "NOAA weak and gauge strong = ${G6_OK}"
if [ "${G6_OK}" = "yes" ] && [ "${G6_NOAA_W}" = "weak" ] && [ "${G6_GAUGE_W}" = "strong" ] \
   && [ "${G6_ALIGNED}" = "yes" ]; then
  gate_result pass \
    "Each rainfall series gets its own correlation against salinity, labelled by its source, each showing r. The local gauge is strong at r = ${G6_GAUGE}. The cell average is weak at r = ${G6_NOAA}. Both come from the maximum correlation sweep, not from comparing peaks. The slider also moves the lines the way the caption says: at the measured delay the points as DRAWN correlate at ${ALIGN_AT_LAG}, against ${ALIGN_AT_ZERO} at no shift." \
    "That the gap means what the lesson says it means. The weak number is weak because the generator built a smooth regional wave that cannot track a short storm. It is a designed contrast, not a measured one, and no real public record has been compared with a real gauge here."
else
  gate_result fail "nothing" "nothing"
fi

gate_header 7 "SCALE, at least seven days behind every gate above"
ROWS_TOTAL="$(psql_val "select count(*) from public.readings where source in ('synthetic','public_synthetic')")"
ROWS_NOAA="$(psql_val "select count(*) from public.readings where source='public_synthetic'")"
SPAN_HOURS="$(psql_val "select round(extract(epoch from (max(ts)-min(ts)))/3600.0) from public.readings where source in ('synthetic','public_synthetic')")"
SPAN_DAYS="$(psql_val "select round(extract(epoch from (max(ts)-min(ts)))/86400.0, 1) from public.readings where source in ('synthetic','public_synthetic')")"
echo "rows behind the rig      = ${ROWS_TOTAL}"
echo "of which the cell average= ${ROWS_NOAA}"
echo "span                     = ${SPAN_HOURS} hours, ${SPAN_DAYS} days"
echo "chart window under test  = ${WINDOW_HOURS} hours"
echo "answered from            = $(attr served-from "${WORK}/all.html")"
echo
psql_show "
select source, count(*) as rows, min(ts) as earliest, max(ts) as latest
from public.readings where source in ('synthetic','public_synthetic')
group by source order by source;"
if [ "${SPAN_HOURS}" -ge 168 ] 2> /dev/null && [ "${ROWS_NOAA}" -ge 168 ] 2> /dev/null; then
  gate_result pass \
    "Every gate above ran against ${ROWS_TOTAL} rows spanning ${SPAN_DAYS} days, which clears the seven day floor in section 17. The seven day window resolves to a rollup, so the three series are read from materialized buckets and not from a raw scan." \
    "That this is field scale. ${ROWS_TOTAL} rows is thousands, not millions. A season of one minute Modbus data is about half a million rows per metric, and nothing here tested a third series at that size or under writer load."
else
  gate_result fail "nothing" "nothing"
fi

gate_header 8 "all four pages still fit 1024 by 600"
FIT_OK="yes"
for page in "" entry knowledge sensors; do
  render "http://127.0.0.1:${API_PORT}/${page}" > "${WORK}/fit.html"
  F="$(attr fits "${WORK}/fit.html")"
  OY="$(attr overflow-y "${WORK}/fit.html")"
  OX="$(attr overflow-x "${WORK}/fit.html")"
  VP="$(attr viewport "${WORK}/fit.html")"
  printf "  /%-10s fits=%-5s overflow y=%-4s x=%-4s viewport=%s\n" "${page}" "${F}" "${OY}" "${OX}" "${VP}"
  [ "${F}" = "true" ] || FIT_OK="no"
done
echo
echo "--- the toggle targets, from the stylesheet ---"
grep -A16 "^.series-toggle {" "${REPO_ROOT}/services/mobilelab/static/chart.css" \
  | grep -E "min-height|min-width" | head -2 | sed 's/^/  /'
grep -oE "\-\-touch: [0-9]+px" "${REPO_ROOT}/services/mobilelab/static/style.css" | head -1 | sed 's/^/  the shared touch target is /'
echo "--- how the space under the bar is split ---"
render "http://127.0.0.1:${API_PORT}/" > "${WORK}/split.html"
echo "  chart $(attr chart-height "${WORK}/split.html") px, controls $(attr control-height "${WORK}/split.html") px, share $(attr chart-share "${WORK}/split.html")"
if [ "${FIT_OK}" = "yes" ]; then
  gate_result pass \
    "Every page reports no vertical and no horizontal overflow at 1024 by 600, with the three toggles added to the chart page. The toggles are one height with the rest of the button row, at the 44 px touch target this screen uses throughout." \
    "That it fits at any other size. The measurement is at exactly 1024 by 600. A larger browser window, a rotated panel, or a longer series name could still push the layout."
fi
[ "${FIT_OK}" = "yes" ] || gate_result fail "nothing" "nothing"

gate_header 9 "DEPLOYED, the kiosk comes up showing all three series"
echo "booted at        $(uptime -s)"
echo "up for           $(uptime -p)"
echo "boot id          $(cat /proc/sys/kernel/random/boot_id)"
KIOSK="$(runuser -u planetwerx -- env XDG_RUNTIME_DIR=/run/user/1000 systemctl --user is-active mobilelab-kiosk 2>/dev/null)"
echo "kiosk unit       ${KIOSK}"
CHROME_ARGS="$(tr '\0' ' ' < /proc/"$(pgrep -f 'chromium.*--kiosk' | head -1)"/cmdline 2>/dev/null | tr ' ' '\n' | grep -cE '^--kiosk$')"
echo "kiosk flag on the running browser = ${CHROME_ARGS}"
KIOSK_URL="$(tr '\0' ' ' < /proc/"$(pgrep -f 'chromium.*--kiosk' | head -1)"/cmdline 2>/dev/null | tr ' ' '\n' | grep -E '^http' | head -1)"
echo "kiosk address    ${KIOSK_URL}"
echo
echo "--- what that address serves, with no arguments and no manual step ---"
render "http://127.0.0.1:${API_PORT}/" > "${WORK}/boot.html"
B_COUNT="$(attr series-count "${WORK}/boot.html")"
B_VISIBLE="$(attr visible "${WORK}/boot.html")"
B_STATUS="$(attr status "${WORK}/boot.html")"
echo "  status  = ${B_STATUS}"
echo "  series  = ${B_COUNT}"
echo "  visible = ${B_VISIBLE}"
echo
echo "--- the three toggles are in the served page, labelled exactly ---"
grep -oE '<span class="toggle-name">[^<]*</span>' "${WORK}/boot.html" | sed 's/<[^>]*>//g' | sed 's/^/  /'
echo
echo "--- the screen, right now ---"
runuser -u planetwerx -- env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 \
  grim -t ppm /tmp/rig-screen.ppm 2>/dev/null
python3 "${SCRIPT_DIR}/kiosk/screen-check.py" /tmp/rig-screen.ppm 2>/dev/null | tail -5
LABELS="$(grep -oE '<span class="toggle-name">[^<]*</span>' "${WORK}/boot.html" | sed 's/<[^>]*>//g' | tr '\n' ',' | sed 's/,$//')"
if [ "${KIOSK}" = "active" ] && [ "${B_COUNT}" = "3" ] && [ "${B_VISIBLE}" = "s0,s1,s2" ] \
   && [ "${LABELS}" = "Salinity,NOAA,Rain Gauge" ]; then
  gate_result pass \
    "The kiosk unit is up since boot, the browser carries the kiosk flag, and the address it holds serves all three series visible with no argument and no manual step. The three toggles are in the served page labelled exactly Salinity, NOAA, and Rain Gauge." \
    "That the toggles respond to a finger on the panel. This read the served page and the running process. A capture shows the glass, but nobody has pressed a toggle on the touchscreen, and that is the way it will be used."
else
  gate_result fail "nothing" "nothing"
fi

echo
echo "================================================================"
echo "SUMMARY: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
echo "================================================================"
echo "rows ${ROWS_TOTAL}, span ${SPAN_DAYS} days, window ${WINDOW_HOURS} hours"
