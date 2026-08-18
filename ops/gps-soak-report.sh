#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

OUTDIR="${MOBILELAB_SOAK_DIR:-/var/log/mobilelab/gps-soak}"

unit_enabled() {
  local state
  state="$(systemctl is-enabled "$1" 2>/dev/null | head -1)"
  if [ -z "${state}" ]; then state="not-installed"; fi
  echo "${state}"
}

unit_active() {
  local state
  state="$(systemctl is-active "$1" 2>/dev/null | head -1)"
  if [ -z "${state}" ]; then state="unknown"; fi
  echo "${state}"
}
MARKER="/var/lib/mobilelab/gps-soak.done"
UNIT="mobilelab-gps-soak.service"
MODE="${1:-print}"

if [ "${MODE}" = "--watch" ]; then
  echo "Watching the soak live. Press Ctrl-C to stop watching."
  echo "Stopping the watch does NOT stop the soak."
  echo
  exec journalctl -u "${UNIT}" -f -o cat
fi

if [ "${MODE}" = "--smoke" ]; then
  OUTDIR="/var/log/mobilelab/gps-soak-smoke"
fi

if [ -f "${OUTDIR}/report.txt" ]; then
  cat "${OUTDIR}/report.txt"
  exit 0
fi

if [ -f "${OUTDIR}/run.log" ] && grep -q "^FACT refused=" "${OUTDIR}/run.log" \
   && [ ! -f "${OUTDIR}/buckets.jsonl" ]; then
  echo "================================================================"
  echo "THE SOAK REFUSED TO MEASURE. THE ONE SHOT IS NOT SPENT."
  echo "================================================================"
  echo
  sed -n "/REFUSING TO MEASURE/,\$p" "${OUTDIR}/run.log" | sed "s/^[0-9T:-]* //"
  echo
  echo "  Fix the cause, then reboot. It fires again by itself."
  exit 1
fi

if [ -f "${OUTDIR}/buckets.jsonl" ]; then
  echo "================================================================"
  echo "THE SOAK HAS NOT FINISHED. This is the part that is measured so far."
  echo "================================================================"
  echo
  python3 "${SCRIPT_DIR}/gps-soak.py" render \
    --outdir "${OUTDIR}" --repo-root "${REPO_ROOT}"
  exit 0
fi

echo "================================================================"
echo "THERE IS NO REPORT YET."
echo "================================================================"
echo
echo "  looked in     ${OUTDIR}"
echo "  soak unit     $(unit_enabled ${UNIT})"
echo "  soak now      $(unit_active ${UNIT})"
if [ -f "${MARKER}" ]; then
  echo "  marker        present. The soak has already used its one shot."
else
  echo "  marker        absent. The soak fires on the next boot."
fi
echo
if systemctl is-active --quiet "${UNIT}" 2>/dev/null; then
  echo "  IT IS RUNNING NOW. It takes 25 minutes. Watch it with:"
  echo "    ops/gps-soak-report.sh --watch"
else
  echo "  If the marker is present and no report exists, the run died early."
  echo "  Read what it managed to say:"
  echo "    journalctl -u ${UNIT} -b -1 --no-pager"
  echo "    cat ${OUTDIR}/run.log"
fi
exit 1
