#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

OUTDIR="/var/log/mobilelab/gps-soak"
MARKER="/var/lib/mobilelab/gps-soak.done"
UNIT="mobilelab-gps-soak.service"
RELAY="mobilelab-gpsrelay.service"
DRIVER="mobilelab-gps.service"
GPS_LINK="/dev/mobilelab-gps"
BUCKETS=25
BUCKET_SECONDS=60
DISARM=1

MODE="${1:-run}"

case "${MODE}" in
  --smoke)
    OUTDIR="/var/log/mobilelab/gps-soak-smoke"
    BUCKETS=2
    BUCKET_SECONDS=20
    DISARM=0
    ;;
  --restore-only|run|"")
    ;;
  *)
    echo "usage: gps-soak.sh [--smoke|--restore-only]" >&2
    exit 2
    ;;
esac

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: run this script with sudo." >&2
  exit 1
fi

mkdir -p "${OUTDIR}" "$(dirname "${MARKER}")"
chmod 0755 "${OUTDIR}"

log() {
  printf '%s %s\n' "$(date +%Y-%m-%dT%H:%M:%S)" "$*" | tee -a "${OUTDIR}/run.log"
}

fact() {
  printf 'FACT %s\n' "$1" >> "${OUTDIR}/run.log"
  printf 'FACT %s\n' "$1"
}

unit_state() {
  local state
  state="$(systemctl is-active "$1" 2>/dev/null | head -1)"
  if [ -z "${state}" ]; then state="unknown"; fi
  echo "${state}"
}

unit_enabled() {
  local state
  state="$(systemctl is-enabled "$1" 2>/dev/null | head -1)"
  if [ -z "${state}" ]; then state="not-installed"; fi
  echo "${state}"
}

port_holders() {
  local real
  real="$(readlink -f "${GPS_LINK}" 2>/dev/null || echo none)"
  if ! command -v fuser > /dev/null 2>&1; then
    echo "fuser-not-installed"
    return
  fi
  local found
  found="$(fuser "${GPS_LINK}" "${real}" 2>/dev/null | tr -s ' ' | sed 's/^ *//;s/ *$//')"
  if [ -z "${found}" ]; then
    echo "none"
  else
    echo "pids:${found}"
  fi
}

restore_relay() {
  log "restoring ${RELAY}"
  systemctl start "${RELAY}" > /dev/null 2>&1
  sleep 4
  local state
  state="$(unit_state "${RELAY}")"
  if [ "${state}" != "active" ]; then
    log "the relay did not come back on the first try. Trying restart."
    systemctl restart "${RELAY}" > /dev/null 2>&1
    sleep 4
    state="$(unit_state "${RELAY}")"
  fi
  fact "relay_after=${state}"
  fact "driver_after=$(unit_state "${DRIVER}")"
  fact "gpsd_after=$(unit_state gpsd.service)"

  {
    echo "taken $(date +%Y-%m-%dT%H:%M:%S%z), after the last bucket"
    echo ""
    echo "${RELAY} is ${state}"
    systemctl show "${RELAY}" -p ActiveState -p SubState -p ExecMainStartTimestamp \
      -p NRestarts 2>/dev/null | sed 's/^/  /'
    echo ""
    echo "the last lines the relay wrote:"
    journalctl -u "${RELAY}" -n 8 --no-pager -o cat 2>/dev/null | sed 's/^/  /'
    echo ""
    echo "gpsd.service is $(unit_state gpsd.service)"
    echo "${DRIVER} is $(unit_state "${DRIVER}")"
    echo "programs holding ${GPS_LINK}: $(port_holders)"
  } > "${OUTDIR}/restore.txt" 2>&1
  chmod 0644 "${OUTDIR}/restore.txt"

  if [ "${state}" = "active" ]; then
    log "the relay is active again"
  else
    log "WARNING the relay is ${state}. Gate 3 fails. Start it by hand."
  fi
}

render_report() {
  log "writing the report"
  python3 "${SCRIPT_DIR}/gps-soak.py" render \
    --outdir "${OUTDIR}" \
    --repo-root "${REPO_ROOT}" \
    --out "${OUTDIR}/report.txt" > /dev/null 2>> "${OUTDIR}/run.log"
  if [ -f "${OUTDIR}/report.txt" ]; then
    chmod 0644 "${OUTDIR}/report.txt"
    log "the report is at ${OUTDIR}/report.txt"
  else
    log "WARNING the report was not written"
  fi
}

if [ "${MODE}" = "--restore-only" ]; then
  log "restore-only was called. This is the safety net after the main run."
  restore_relay
  render_report
  chmod -f 0644 "${OUTDIR}/run.log"
  exit 0
fi

: > "${OUTDIR}/run.log"
chmod 0644 "${OUTDIR}/run.log"

log "GPS bridge soak starting. Diagnostic only. It changes no application code."

WC_STATE="absent"
if systemctl cat weather-collector.service > /dev/null 2>&1; then
  WC_STATE="$(unit_state weather-collector.service)"
fi

if [ "${WC_STATE}" = "active" ] && [ "${DISARM}" -eq 1 ]; then
  log "REFUSING TO MEASURE. weather-collector.service is running."
  log "  It writes into the same serial port. A run taken now measures the"
  log "  confound this soak exists to remove, and it would spend the one shot"
  log "  on an answer nobody can use."
  log ""
  log "  THE ONE SHOT IS NOT SPENT. A refusal is not a run. The unit stays"
  log "  armed and it fires again on the next boot."
  log ""
  log "  weather-collector is DISABLED and it started anyway. Another unit"
  log "  requires it. Disabling it is not enough. Mask it:"
  log "    sudo systemctl mask weather-collector.service"
  log "  Masking blocks it whatever tries to start it. Undo with unmask."
  log "  NOTE: weather-server.service requires it and will fail while masked."
  log ""
  log "  The relay was NOT stopped. Nothing was changed."
  fact "refused=weather-collector-active"
  fact "weather_collector_active=yes"
  fact "weather_collector_enabled=$(unit_enabled weather-collector.service)"
  fact "marker=$( [ -f "${MARKER}" ] && echo present || echo missing )"
  fact "armed_after=$(unit_enabled "${UNIT}")"
  chmod -f 0644 "${OUTDIR}/run.log"
  exit 0
fi

if [ "${WC_STATE}" = "active" ]; then
  log "WARNING weather-collector is running. This smoke run proves the"
  log "  mechanism only. Its numbers are corrupt and mean nothing."
fi

FINISHED=0
finish() {
  if [ "${FINISHED}" -eq 1 ]; then
    return
  fi
  FINISHED=1
  log "finishing. The relay is restored whether the soak worked or not."
  restore_relay
  render_report
  chmod -f 0644 "${OUTDIR}/run.log"
}
trap finish EXIT
trap 'log "a signal arrived. Stopping."; exit 143' INT TERM

if [ "${DISARM}" -eq 1 ]; then
  log "disarming BEFORE the measurement, not after"
  log "  A crash or a power cut during the soak must not leave this armed."
  log "  Disarming first makes this a single attempt, which is what one shot means."
  touch "${MARKER}"
  chmod 0644 "${MARKER}"
  if systemctl disable "${UNIT}" > /dev/null 2>&1; then
    log "  ${UNIT} is disabled"
  else
    log "  WARNING systemctl disable ${UNIT} failed. The marker still blocks it."
  fi
  fact "marker=$( [ -f "${MARKER}" ] && echo present || echo missing )"
  fact "armed_after=$(unit_enabled "${UNIT}")"
else
  log "SMOKE RUN. It does not disarm and it does not touch the marker."
  fact "marker=smoke-run"
  fact "armed_after=smoke-run"
fi

if [ -n "${INVOCATION_ID:-}" ]; then
  UPSEC="$(cut -d. -f1 /proc/uptime 2>/dev/null || echo 0)"
  case "${UPSEC}" in ''|*[!0-9]*) UPSEC=0 ;; esac
  if [ "${UPSEC}" -lt 600 ]; then
    fact "fired_by=systemd-boot"
  else
    fact "fired_by=systemd-late"
  fi
else
  fact "fired_by=hand"
fi
fact "boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)"
fact "uptime_at_wrapper_start=$(cut -d' ' -f1 /proc/uptime)"

if [ "${WC_STATE}" = "absent" ]; then
  fact "weather_collector_active=no"
  fact "weather_collector_enabled=absent"
elif [ "${WC_STATE}" = "active" ]; then
  fact "weather_collector_active=yes"
  fact "weather_collector_enabled=$(unit_enabled weather-collector.service)"
else
  fact "weather_collector_active=no"
  fact "weather_collector_enabled=$(unit_enabled weather-collector.service)"
fi

log "waiting for ${GPS_LINK}"
WAITED=0
while [ ! -e "${GPS_LINK}" ] && [ "${WAITED}" -lt 60 ]; do
  sleep 2
  WAITED=$((WAITED + 2))
done
if [ -e "${GPS_LINK}" ]; then
  fact "device_wait_seconds=${WAITED}"
  fact "device_real=$(readlink -f "${GPS_LINK}")"
  log "  ${GPS_LINK} appeared after ${WAITED} seconds"
else
  fact "device_wait_seconds=timeout"
  fact "device_real=missing"
  log "  ${GPS_LINK} never appeared. The soak runs anyway and records the hole."
fi

fact "relay_before=$(unit_state "${RELAY}")"
fact "gpsd_state=$(unit_state gpsd.service)"
fact "driver_before=$(unit_state "${DRIVER}")"

log "stopping ${RELAY} to take the port"
log "  It is STOPPED, not disabled. It comes back at the end of this script."
systemctl stop "${RELAY}" > /dev/null 2>&1
sleep 3
fact "relay_stopped=$(unit_state "${RELAY}")"

HOLDERS="$(port_holders)"
fact "other_holders=${HOLDERS}"
if [ "${HOLDERS}" != "none" ] && [ "${HOLDERS}" != "fuser-not-installed" ]; then
  log "WARNING something else holds the port: ${HOLDERS}"
  fuser -v "${GPS_LINK}" 2>&1 | tee -a "${OUTDIR}/run.log"
fi

BUDGET=$((BUCKETS * BUCKET_SECONDS + 150))
log "measuring ${BUCKETS} buckets of ${BUCKET_SECONDS} s, budget ${BUDGET} s"

timeout --signal=TERM --kill-after=30 "${BUDGET}" \
  python3 "${SCRIPT_DIR}/gps-soak.py" run \
    --device "${GPS_LINK}" \
    --outdir "${OUTDIR}" \
    --buckets "${BUCKETS}" \
    --bucket-seconds "${BUCKET_SECONDS}" 2>&1 | tee -a "${OUTDIR}/run.log"
ENGINE_RC="${PIPESTATUS[0]}"
fact "engine_exit=${ENGINE_RC}"
if [ "${ENGINE_RC}" -eq 124 ]; then
  log "the engine hit the ${BUDGET} s budget and was stopped"
elif [ "${ENGINE_RC}" -ne 0 ]; then
  log "the engine exited ${ENGINE_RC}"
fi

finish
exit 0
