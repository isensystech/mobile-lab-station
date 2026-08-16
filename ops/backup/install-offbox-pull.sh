#!/usr/bin/env bash
set -uo pipefail

: <<'ABOUT'
Installs the nightly off box copy.

THIS SCRIPT RUNS ON THE OPERATOR LAPTOP, not on the Pi. It writes a launchd
agent that pulls the station dumps every night.

launchd runs a missed job when the laptop wakes. So a closed lid delays the
copy. It does not cancel it.

The installer COPIES the script out of the repository first.

macOS protects the Documents folder. A launchd agent cannot run a script that
lives there. It stops with "Operation not permitted" and exit code 126. The
copy also keeps the nightly job working if somebody moves the repository.
ABOUT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PULL="${SCRIPT_DIR}/offbox-pull.sh"

INSTALL_DIR="${HOME}/Library/Application Support/mobile-lab-station"
INSTALLED_PULL="${INSTALL_DIR}/offbox-pull.sh"

LABEL="com.planetwerx.mobilelab-backup-pull"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
LOCAL_DIR="${MOBILELAB_OFFBOX_DIR:-${HOME}/mobile-lab-backups}"
HOUR="${MOBILELAB_OFFBOX_HOUR:-3}"
MINUTE="${MOBILELAB_OFFBOX_MINUTE:-30}"

if [ "$(uname)" != "Darwin" ]; then
  echo "ERROR: this installer is for macOS. The Pi does not run it." >&2
  exit 1
fi

if [ ! -x "${PULL}" ]; then
  echo "ERROR: ${PULL} is missing or not executable." >&2
  exit 1
fi

mkdir -p "${HOME}/Library/LaunchAgents"
mkdir -p "${LOCAL_DIR}"
mkdir -p "${INSTALL_DIR}"

cp "${PULL}" "${INSTALLED_PULL}"
chmod 0755 "${INSTALLED_PULL}"

cat > "${PLIST}" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${INSTALLED_PULL}</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>${HOUR}</integer>
    <key>Minute</key>
    <integer>${MINUTE}</integer>
  </dict>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>${LOCAL_DIR}/launchd.out.log</string>
  <key>StandardErrorPath</key>
  <string>${LOCAL_DIR}/launchd.err.log</string>
</dict>
</plist>
PLISTEOF

plutil -lint "${PLIST}" > /dev/null || {
  echo "ERROR: the plist is not valid." >&2
  exit 1
}

launchctl bootout "gui/$(id -u)/${LABEL}" > /dev/null 2>&1 || true
if ! launchctl bootstrap "gui/$(id -u)" "${PLIST}" 2>&1; then
  echo "ERROR: launchctl refused to load the agent." >&2
  exit 1
fi

echo "installed ${LABEL}"
echo "  runs every day at $(printf '%02d:%02d' "${HOUR}" "${MINUTE}") local time"
echo "  script  ${INSTALLED_PULL}"
echo "          copied from ${PULL}"
echo "          Re run this installer after you change the script."
echo "  copies land in ${LOCAL_DIR}"
echo "  logs    ${LOCAL_DIR}/pull.log"
echo "          ${LOCAL_DIR}/launchd.err.log"
echo
echo "to run it now:"
echo "  launchctl kickstart -k gui/$(id -u)/${LABEL}"
echo "to remove it:"
echo "  launchctl bootout gui/$(id -u)/${LABEL} && rm ${PLIST}"
