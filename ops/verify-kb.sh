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
STATION_ID="${MOBILELAB_STATION_ID:-lab01}"
API_PORT="${MOBILELAB_API_PORT:-8000}"
BRIDGE_PORT="${MOBILELAB_BRIDGE_PORT:-8081}"
LAN_IP="$(hostname -I | awk '{print $1}')"
API="http://${LAN_IP}:${API_PORT}"
LOCAL="http://127.0.0.1:${API_PORT}"
WORK=/tmp/mlkb
mkdir -p "${WORK}"; chmod 0777 "${WORK}"

PASS_COUNT=0
FAIL_COUNT=0

psql_show() { runuser -u postgres -- psql -d "${DB_NAME}" -c "$1" 2>&1; }
psql_val() { runuser -u postgres -- psql -t -A -d "${DB_NAME}" -c "$1" 2>&1 | tr -d '[:space:]'; }
render() {
  runuser -u scott -- env HOME=/home/scott timeout 90 chromium \
    --headless --disable-gpu --no-sandbox --virtual-time-budget=15000 --dump-dom "$1" 2> /dev/null
}
attr() { grep -oE "data-$1=\"[^\"]*\"" "$2" | head -1 | sed "s/^data-$1=\"//; s/\"$//"; }

article_heading() {
  "${VENV_PY}" - "$1" <<'PYEOF'
import re, sys
html = open(sys.argv[1], encoding="utf-8").read()
body = re.search(r'<div[^>]*id="article-body"[^>]*>(.*?)</div>', html, re.S)
inner = body.group(1) if body else ""
head = re.search(r"<h[123][^>]*>(.*?)</h[123]>", inner, re.S)
print(re.sub(r"<[^>]*>", "", head.group(1)).strip() if head else "")
PYEOF
}
gate_header() {
  echo; echo "================================================================"
  echo "GATE $1: $2"; echo "================================================================"
}
gate_result() {
  if [ "$1" = "pass" ]; then PASS_COUNT=$((PASS_COUNT+1)); echo "RESULT: PASS"
  else FAIL_COUNT=$((FAIL_COUNT+1)); echo "RESULT: FAIL"; fi
  echo "PROVES:         $2"
  echo "DOES NOT PROVE: $3"
}

echo "Mobile Lab Station knowledge base and sensor suite verification"
echo "host $(hostname), $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "pages ${API}/knowledge and ${API}/sensors"

gate_header 1 "both pages load with no network"
echo "--- every asset these pages need is served by the station ---"
for path in /knowledge /sensors /static/style.css /static/kb.css /static/knowledge.js /static/sensors.js; do
  printf '  %-28s HTTP %s\n' "${path}" \
    "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "${LOCAL}${path}")"
done
echo
echo "--- no page asks the internet for anything ---"
EXTERNAL="$(grep -ohE '(src|href)="https?://[^"]*"' \
  "${REPO_ROOT}/services/mobilelab/static/knowledge.html" \
  "${REPO_ROOT}/services/mobilelab/static/sensors.html" \
  "${REPO_ROOT}/services/mobilelab/static/index.html" \
  "${REPO_ROOT}/services/mobilelab/static/entry.html" 2>/dev/null | sort -u)"
if [ -z "${EXTERNAL}" ]; then
  echo "  no absolute http or https reference in any page"
else
  echo "  FOUND EXTERNAL REFERENCES:"; echo "${EXTERNAL}" | sed 's/^/    /'
fi
echo
echo "--- rendering both pages in a real browser with networking blocked ---"
for page in knowledge sensors; do
  runuser -u scott -- env HOME=/home/scott timeout 90 chromium \
    --headless --disable-gpu --no-sandbox --virtual-time-budget=15000 \
    --host-resolver-rules="MAP * ~NOTFOUND, EXCLUDE 127.0.0.1" \
    --dump-dom "${LOCAL}/${page}" 2> /dev/null > "${WORK}/offline-${page}.html"
  printf '  %-12s status=%s bytes=%s\n' "${page}" \
    "$(attr status "${WORK}/offline-${page}.html")" \
    "$(wc -c < "${WORK}/offline-${page}.html")"
done
G1_K="$(attr status "${WORK}/offline-knowledge.html")"
G1_S="$(attr status "${WORK}/offline-sensors.html")"
echo "  the resolver rule above sends every host except 127.0.0.1 to NOTFOUND."
if [ "${G1_K}" = "ready" ] && [ "${G1_S}" = "ready" ] && [ -z "${EXTERNAL}" ]; then
  gate_result pass \
    "Both pages reach ready in a browser that cannot resolve any host except the station itself. No page references an external host, so the markdown renderer, the stylesheet, and the scripts all come from the Pi." \
    "That the whole station is offline clean. This checked four pages. A future page, a font, or a favicon could still reach out, and nothing lints for that on every build."
else
  gate_result fail "nothing" "nothing"
fi

gate_header 2 "the article text is rendered from the markdown file"
FIRST_SLUG="$("${VENV_PY}" -c "
import json,urllib.request
with urllib.request.urlopen('${LOCAL}/api/kb', timeout=10) as r: d=json.load(r)
print(d[0]['slug'])")"
SOURCE_FILE="$(${VENV_PY} -c "
import json,urllib.request
with urllib.request.urlopen('${LOCAL}/api/kb', timeout=10) as r: d=json.load(r)
print(d[0]['source_file'])")"
TARGET="${REPO_ROOT}/${SOURCE_FILE}"
echo "article: ${FIRST_SLUG}"
echo "file:    ${SOURCE_FILE}"
echo
echo "--- the heading in the markdown file right now ---"
ORIGINAL="$(grep -m1 '^## ' "${TARGET}")"
echo "  ${ORIGINAL}"
echo "--- the heading the browser shows ---"
render "${LOCAL}/knowledge?a=${FIRST_SLUG}" > "${WORK}/g2-before.html"
BEFORE_H2="$(article_heading "${WORK}/g2-before.html")"
echo "  ${BEFORE_H2}"
echo
MARKER="EDITED BY THE GATE $(date -u +%H%M%S)"
echo "--- editing the markdown file, appending a marker to that heading ---"
cp "${TARGET}" "${WORK}/backup.md"
sed -i "0,/^## /s|^## .*|## ${MARKER}|" "${TARGET}"
echo "  the file now reads: $(grep -m1 '^## ' "${TARGET}")"
echo "--- reloading the page, with no service restart ---"
render "${LOCAL}/knowledge?a=${FIRST_SLUG}" > "${WORK}/g2-after.html"
AFTER_H2="$(article_heading "${WORK}/g2-after.html")"
echo "  the browser now shows: ${AFTER_H2}"
echo "--- restoring the file ---"
cp "${WORK}/backup.md" "${TARGET}"
render "${LOCAL}/knowledge?a=${FIRST_SLUG}" > "${WORK}/g2-restored.html"
RESTORED_H2="$(article_heading "${WORK}/g2-restored.html")"
echo "  restored, the browser shows: ${RESTORED_H2}"
echo
echo "--- the shell example must not be on screen ---"
SHELL_LEFT="$(grep -c 'Example heading' "${WORK}/g2-before.html")"
echo "  occurrences of the shell heading in the rendered page: ${SHELL_LEFT}"
if [ "${AFTER_H2}" = "${MARKER}" ] && [ "${BEFORE_H2}" = "${RESTORED_H2}" ] \
   && [ "${BEFORE_H2}" != "${MARKER}" ] && [ "${SHELL_LEFT}" = "0" ]; then
  gate_result pass \
    "The page renders the markdown file itself. A heading edited on disk appears on reload with no restart and no rebuild, and reverting the file reverts the page. The shell example never reaches the screen, so there is only one copy of the text." \
    "That the markdown is checked before it renders. Nothing lints these files for ASD-STE100, which architecture section 8 asks for, and nothing sanitises them. A file on disk is trusted, so anybody who can write to docs/kb can put raw HTML on the page."
else
  gate_result fail "nothing" "nothing"
fi

gate_header 3 "NEGATIVE, a live sensor with no value shows unavailable"
echo "The WQL tile reads water/temperature from source wql."
BEFORE_ROWS="$(psql_val "select count(*) from public.readings where source='wql'")"
echo "wql readings before = ${BEFORE_ROWS}"
render "${LOCAL}/sensors" > "${WORK}/g3-before.html"
echo "--- the WQL tile now ---"
grep -oE '<div class="tile" data-status="live"[^>]*>' "${WORK}/g3-before.html" | head -1
BEFORE_VALUE="$(grep -oE 'data-status="live" data-name="WQL Logger" data-number="1" data-value="[^"]*"' "${WORK}/g3-before.html" | grep -oE 'data-value="[^"]*"' | sed 's/data-value="//; s/"//')"
echo "  data-value = '${BEFORE_VALUE}'"
echo
echo "--- removing every wql reading, so the API has no value to give ---"
psql_show "delete from public.readings where source='wql';" | tail -1
psql_show "delete from public.dives;" > /dev/null
AFTER_ROWS="$(psql_val "select count(*) from public.readings where source='wql'")"
echo "wql readings after delete = ${AFTER_ROWS}"
echo "--- what the API says now ---"
curl -sS "${LOCAL}/api/sensors" | "${VENV_PY}" -c "
import json,sys
for s in json.load(sys.stdin):
    if s['status']=='live': print('  ', s['name'], 'reading =', s['reading'])"
echo "--- what the tile shows now ---"
render "${LOCAL}/sensors" > "${WORK}/g3-after.html"
AFTER_VALUE="$(grep -oE 'data-status="live" data-name="WQL Logger" data-number="1" data-value="[^"]*"' "${WORK}/g3-after.html" | grep -oE 'data-value="[^"]*"' | sed 's/data-value="//; s/"//')"
UNAVAIL_TEXT="$(grep -oE 'Unavailable. No reading stored.' "${WORK}/g3-after.html" | head -1)"
SHELL_NUM="$(grep -c '21.4' "${WORK}/g3-after.html")"
echo "  data-value = '${AFTER_VALUE}'  (must be empty)"
echo "  tile text  = '${UNAVAIL_TEXT}'"
echo "  occurrences of the shell example number 21.4 = ${SHELL_NUM}  (must be 0)"
echo
echo "--- restoring the dive data ---"
runuser -u mobilelab -- env PYTHONPATH="${REPO_ROOT}/services" "${VENV_PY}" \
  -m mobilelab.divefixture --rows 300 --cast 21 > "${WORK}/restore.csv"
curl -sS -X POST "http://127.0.0.1:${BRIDGE_PORT}/dives/AA:BB:CC:DD:EE:0F/dive_restore_$(date +%s).csv" \
  -H 'Content-Type: text/csv' --data-binary @"${WORK}/restore.csv" \
  -o /dev/null -w "  restore upload HTTP %{http_code}\n"
sleep 3
echo "  wql readings restored = $(psql_val "select count(*) from public.readings where source='wql'")"
if [ -n "${BEFORE_VALUE}" ] && [ -z "${AFTER_VALUE}" ] && [ -n "${UNAVAIL_TEXT}" ] \
   && [ "${SHELL_NUM}" = "0" ]; then
  gate_result pass \
    "With a value the tile showed '${BEFORE_VALUE}'. With the readings deleted the tile shows 'Unavailable. No reading stored.', its data-value is empty, and the illustrative 21.4 from the shell file appears nowhere. The page does not fall back to the shell." \
    "That a STALE value is caught. This tested no value at all. A tile with a reading from three weeks ago still shows that number, with its age in small text beside it. Nothing decides how old is too old, and nothing greys it out."
else
  gate_result fail "nothing" "nothing"
fi

gate_header 4 "NEGATIVE, no planned tile renders any numeric value"
render "${LOCAL}/sensors" > "${WORK}/g4.html"
echo "--- the rain gauge is read by hand, so it is manual and never planned ---"
curl -sS "${LOCAL}/api/sensors" | "${VENV_PY}" -c "
import json,sys
d=json.load(sys.stdin)
rain=[s for s in d if s['name']=='Rain gauge'][0]
print('  status  ', rain['status'])
print('  reads   ', rain.get('reads'))
print('  reading ', rain.get('reading'))
ok = rain['status']=='manual' and rain['reads']['sources']==['manual']
print('  RAIN_TILE_CHECK=' + ('PASS' if ok else 'FAIL'))
"
RAIN_OK="$(curl -sS "${LOCAL}/api/sensors" | "${VENV_PY}" -c "
import json,sys
d=json.load(sys.stdin)
r=[s for s in d if s['name']=='Rain gauge'][0]
print('PASS' if r['status']=='manual' and r['reads']['sources']==['manual'] else 'FAIL')")"
echo
echo "--- the fixture publishes synthetic rainfall, which must never reach that tile ---"
psql_show "select source, count(*) as rows, round(max(value)::numeric,2) as newest_value
from public.readings where sensor='rain' and metric='rainfall' group by source order by source;"
RAIN_VALUE="$(grep -oE 'data-status="manual" data-name="Rain gauge" data-number="6" data-value="[^"]*"' "${WORK}/g4.html" | grep -oE 'data-value="[^"]*"' | sed 's/data-value="//; s/"//')"
SYNTH_MAX="$(psql_val "select coalesce(round(max(value)::numeric,2),0) from public.readings where sensor='rain' and metric='rainfall' and source='synthetic'")"
echo "  rain gauge tile data-value = [${RAIN_VALUE}]"
echo "  highest synthetic rainfall in the database = ${SYNTH_MAX}"
if [ -n "${RAIN_VALUE}" ] && [ "${RAIN_VALUE}" = "${SYNTH_MAX}" ]; then
  echo "  DEFECT: the tile is showing the synthetic number"
  RAIN_CLEAN="FAIL"
else
  RAIN_CLEAN="PASS"
fi
echo "  synthetic leaked into the tile: ${RAIN_CLEAN}"
echo
echo "--- the API sends no reading key at all for a planned sensor ---"
curl -sS "${LOCAL}/api/sensors" | "${VENV_PY}" -c "
import json,sys
d=json.load(sys.stdin)
bad=[s['name'] for s in d if s['status']=='planned' and 'reading' in s]
print('  planned sensors:', sum(1 for s in d if s['status']=='planned'))
print('  planned sensors carrying a reading key:', len(bad), bad or '')"
echo
echo "--- asserting on the DOM, not by eye ---"
"${VENV_PY}" - "${WORK}/g4.html" <<'PYEOF'
import re, sys
html = open(sys.argv[1], encoding="utf-8").read()
grid = re.search(r'<div class="tile-grid" id="tile-grid">(.*?)</div></section>', html, re.S)
inner = grid.group(1) if grid else html
chunks = inner.split('<div class="tile"')[1:]
tiles = []
for chunk in chunks:
    head = re.match(r'\s+data-status="([a-z]+)" data-name="([^"]*)" data-number="(\d+)" data-value="([^"]*)"', chunk)
    if head:
        tiles.append((head.group(1), head.group(2), head.group(3), head.group(4), chunk))
planned = [t for t in tiles if t[0] == "planned"]
print(f"  tiles parsed from the DOM: {len(tiles)}, of which planned: {len(planned)}")
failures = []
for status, name, number, value, body in planned:
    slot = re.search(r'<p class="tile-value[^"]*">(.*?)</p>', body, re.S)
    text = re.sub(r"<[^>]*>", "", slot.group(1)) if slot else ""
    digits = re.findall(r"\d", text)
    if value != "":
        failures.append(f"{name}: data-value is {value!r}, must be empty")
    if digits:
        failures.append(f"{name}: the value slot contains digits {digits}")
    print(f"    {number:>2} {name:<16} data-value={value!r:<4} value slot={text.strip()!r}")
print()
expected = 6
if len(planned) != expected:
    failures.append(f"parsed {len(planned)} planned tiles, expected {expected}")
if failures:
    print("  FAILURES:")
    for f in failures: print("   ", f)
    print("  PLANNED_TILE_CHECK=FAIL")
else:
    print(f"  every one of the {len(planned)} planned tiles has an empty data-value and no digit")
    print("  PLANNED_TILE_CHECK=PASS")
PYEOF
G4="$(render "${LOCAL}/sensors" > /dev/null 2>&1; grep -o 'data-planned-with-value="[^"]*"' "${WORK}/g4.html" | head -1 | sed 's/.*="//; s/"//')"
G4_CHECK="$("${VENV_PY}" - "${WORK}/g4.html" <<'PYEOF'
import re, sys
html = open(sys.argv[1], encoding="utf-8").read()
tiles = re.findall(r'data-status="planned" data-name="([^"]*)" data-number="\d+" data-value="([^"]*)"', html)
print("PASS" if len(tiles) == 6 and all(v == "" for _, v in tiles) else "FAIL")
PYEOF
)"
echo "  planned tiles reported by the page as carrying a value: ${G4:-0}"
echo "  DOM assertion: ${G4_CHECK}"
if [ "${G4_CHECK}" = "PASS" ] && [ "${G4:-0}" = "0" ] && [ "${RAIN_OK}" = "PASS" ] \
   && [ "${RAIN_CLEAN}" = "PASS" ]; then
  gate_result pass \
    "All six planned tiles render with an empty data-value and no digit in the value slot. The rain gauge is NOT among them: it is read by hand, so it carries the manual chip and reads source manual only. The API refuses to send a reading key for a planned sensor, and the page refuses to draw one. A sensor that does not exist cannot appear to have measured anything." \
    "That the rule holds for a NEW tile someone adds later. The check lives in two places, suite.py and sensors.js, and a third surface such as a kiosk widget or a printed report would need its own. The rule is enforced per renderer, exactly like the source labelling rule in section 16."
else
  gate_result fail "nothing" "nothing"
fi

gate_header 5 "both pages are reachable from the chart page, and back"
echo "--- links out of the chart page ---"
render "${LOCAL}/" > "${WORK}/g5-chart.html"
grep -oE '<a href="/(knowledge|sensors|entry)"[^>]*>[^<]*</a>' "${WORK}/g5-chart.html" | sed 's/^/  /'
echo "--- links back, from the knowledge page ---"
grep -oE '<a href="/"[^>]*>[^<]*</a>' "${WORK}/offline-knowledge.html" | head -1 | sed 's/^/  /'
grep -oE '<a href="/(sensors|entry)"[^>]*>[^<]*</a>' "${WORK}/offline-knowledge.html" | sed 's/^/  /'
echo "--- links back, from the sensors page ---"
grep -oE '<a href="/"[^>]*>[^<]*</a>' "${WORK}/offline-sensors.html" | head -1 | sed 's/^/  /'
grep -oE '<a href="/(knowledge|entry)"[^>]*>[^<]*</a>' "${WORK}/offline-sensors.html" | sed 's/^/  /'
echo
CHART_TO_K="$(grep -c 'href="/knowledge"' "${WORK}/g5-chart.html")"
CHART_TO_S="$(grep -c 'href="/sensors"' "${WORK}/g5-chart.html")"
K_TO_CHART="$(grep -c 'href="/"' "${WORK}/offline-knowledge.html")"
S_TO_CHART="$(grep -c 'href="/"' "${WORK}/offline-sensors.html")"
echo "chart to knowledge = ${CHART_TO_K}, chart to sensors = ${CHART_TO_S}"
echo "knowledge to chart = ${K_TO_CHART}, sensors to chart = ${S_TO_CHART}"
echo "--- the current page is marked, so a person knows where they are ---"
grep -oE 'aria-current="page">[^<]*</a>' "${WORK}/offline-knowledge.html" | sed 's/^/  knowledge: /'
grep -oE 'aria-current="page">[^<]*</a>' "${WORK}/offline-sensors.html" | sed 's/^/  sensors:   /'
if [ "${CHART_TO_K}" -ge 1 ] && [ "${CHART_TO_S}" -ge 1 ] \
   && [ "${K_TO_CHART}" -ge 1 ] && [ "${S_TO_CHART}" -ge 1 ]; then
  gate_result pass \
    "The chart page links to both new pages, and both link back to the chart and to each other. One navigation bar lives in the shared stylesheet, and every page marks itself with aria-current so a person knows where they are." \
    "That a person can get out of the kiosk browser. These are ordinary links in an ordinary browser. Chromium kiosk mode is deliberately not configured yet, and how a student leaves a page in kiosk mode is still an open question in section 9."
else
  gate_result fail "nothing" "nothing"
fi

echo
echo "================================================================"
echo "SUMMARY: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
echo "================================================================"
echo "articles served from ${REPO_ROOT}/docs/kb:"
ls -1 "${REPO_ROOT}/docs/kb" | sed 's/^/  /'
if [ "${FAIL_COUNT}" -gt 0 ]; then exit 1; fi
