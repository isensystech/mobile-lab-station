#!/usr/bin/env bash
set -uo pipefail

PROFILE="${HOME}/.config/mobilelab-kiosk"
URL="${MOBILELAB_KIOSK_URL:-http://localhost:8000/}"
WAIT_SECONDS="${MOBILELAB_KIOSK_WAIT:-60}"
SPLASH="${MOBILELAB_SPLASH:-/usr/share/plymouth/themes/planetwerx/splash.png}"

log() {
  echo "kiosk: $1"
}

wait_for_wayland() {
  local socket="${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY:-wayland-0}"
  local waited=0
  while [ ! -S "${socket}" ]; do
    if [ "${waited}" -ge "${WAIT_SECONDS}" ]; then
      log "gave up waiting for ${socket}"
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
  log "the compositor is up at ${socket} after ${waited} seconds"
  return 0
}

wait_for_api() {
  local waited=0
  while ! curl -sS -o /dev/null --max-time 2 "${URL}"; do
    if [ "${waited}" -ge "${WAIT_SECONDS}" ]; then
      log "the API did not answer at ${URL}, starting anyway"
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  log "the API answered after ${waited} seconds"
  return 0
}

clear_crash_flags() {
  local prefs="${PROFILE}/Default/Preferences"
  local state="${PROFILE}/Local State"
  if [ -f "${prefs}" ]; then
    sed -i 's/"exit_type":"[^"]*"/"exit_type":"Normal"/g; s/"exited_cleanly":false/"exited_cleanly":true/g' "${prefs}"
  fi
  if [ -f "${state}" ]; then
    sed -i 's/"exit_type":"[^"]*"/"exit_type":"Normal"/g; s/"exited_cleanly":false/"exited_cleanly":true/g' "${state}"
  fi
  log "cleared the crash flags, so no restore bubble appears"
}

mkdir -p "${PROFILE}/Default"

drop_cache() {
  rm -rf "${PROFILE}/Default/Cache" "${PROFILE}/Default/Code Cache" \
         "${PROFILE}/GrShaderCache" "${PROFILE}/ShaderCache" 2> /dev/null
  log "dropped the browser cache, so a deploy always reaches the screen"
}

drop_cache

wait_for_wayland || exit 1

start_background() {
  if [ ! -f "${SPLASH}" ]; then
    log "no splash image at ${SPLASH}, the compositor background stays plain"
    return 0
  fi
  if ! command -v swaybg > /dev/null 2>&1; then
    log "swaybg is absent, the compositor background stays plain"
    return 0
  fi
  pkill -x swaybg > /dev/null 2>&1
  swaybg -m fill -i "${SPLASH}" > /dev/null 2>&1 &
  log "the splash sits behind the kiosk, so a restart shows branding not grey"
}

start_background
wait_for_api
clear_crash_flags

log "starting Chromium on ${URL}"

exec chromium \
  --kiosk \
  --ozone-platform=wayland \
  --user-data-dir="${PROFILE}" \
  --no-first-run \
  --no-default-browser-check \
  --noerrdialogs \
  --disable-infobars \
  --disable-session-crashed-bubble \
  --hide-crash-restore-bubble \
  --disable-features=Translate,TranslateUI,ChromeWhatsNewUI,MediaRouter,PrivacySandboxSettings4,DefaultBrowserPromptRefresh \
  --disable-component-update \
  --check-for-update-interval=31536000 \
  --disable-background-networking \
  --disable-breakpad \
  --disable-sync \
  --password-store=basic \
  --default-background-color=052A30 \
  --disable-pinch \
  --overscroll-history-navigation=0 \
  --disable-translate \
  --host-resolver-rules="MAP * ~NOTFOUND , EXCLUDE localhost , EXCLUDE 127.0.0.1" \
  "${URL}"
