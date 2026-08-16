#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: run this script with sudo." >&2
  exit 1
fi

KIOSK_USER="${MOBILELAB_KIOSK_USER:-planetwerx}"
KIOSK_UID="$(id -u "${KIOSK_USER}")"
KIOSK_HOME="$(getent passwd "${KIOSK_USER}" | cut -d: -f6)"
UNIT_DIR="${KIOSK_HOME}/.config/systemd/user"
LABWC_RC="${KIOSK_HOME}/.config/labwc/rc.xml"

echo "==> the kiosk runs as ${KIOSK_USER}, uid ${KIOSK_UID}, home ${KIOSK_HOME}"

echo
echo "==> SSH IS THE RECOVERY PATH. Checking it before anything else."
if ! systemctl is-active --quiet ssh; then
  echo "ERROR: ssh is not active. Refusing to install a kiosk with no way back." >&2
  exit 1
fi
if ! systemctl is-enabled --quiet ssh; then
  echo "ERROR: ssh is not enabled at boot. Refusing to install." >&2
  exit 1
fi
echo "    ssh is active and enabled at boot"

echo
echo "==> installing the user unit"
install -d -o "${KIOSK_USER}" -g "${KIOSK_USER}" "${UNIT_DIR}"
sed "s|__REPO_ROOT__|${REPO_ROOT}|g" \
  "${SCRIPT_DIR}/kiosk/mobilelab-kiosk.service" > "${UNIT_DIR}/mobilelab-kiosk.service"
chown "${KIOSK_USER}:${KIOSK_USER}" "${UNIT_DIR}/mobilelab-kiosk.service"
chmod 0644 "${UNIT_DIR}/mobilelab-kiosk.service"
chmod 0755 "${SCRIPT_DIR}/kiosk/kiosk-launch.sh"
echo "    ${UNIT_DIR}/mobilelab-kiosk.service"

echo
echo "==> adding the local escape keybinding to labwc"
echo "    Ctrl+Alt+K stops the kiosk and gives the desktop back."
if [ -f "${LABWC_RC}" ]; then
  cp -n "${LABWC_RC}" "${LABWC_RC}.before-kiosk" || true
fi
python3 - "${LABWC_RC}" <<'PYEOF'
import re
import sys

path = sys.argv[1]
try:
    text = open(path, encoding="utf-8").read()
except FileNotFoundError:
    text = '<?xml version="1.0"?>\n<openbox_config xmlns="http://openbox.org/3.4/rc">\n</openbox_config>\n'

if "mobilelab-kiosk.service" in text:
    print("    the keybinding is already there, leaving the file alone")
    raise SystemExit(0)

block = """  <keyboard>
    <keybind key="C-A-K">
      <action name="Execute" command="systemctl --user stop mobilelab-kiosk.service"/>
    </keybind>
    <keybind key="C-A-S-K">
      <action name="Execute" command="systemctl --user start mobilelab-kiosk.service"/>
    </keybind>
  </keyboard>
"""

if "</openbox_config>" in text:
    text = text.replace("</openbox_config>", block + "</openbox_config>")
else:
    text = text.rstrip() + "\n" + block
open(path, "w", encoding="utf-8").write(text)
print("    keybinding added, the rest of the file was left as it was")
PYEOF
chown "${KIOSK_USER}:${KIOSK_USER}" "${LABWC_RC}"

echo
echo "==> allowing the API to power the station down, and nothing else"
cat > /etc/sudoers.d/mobilelab-power <<'EOF'
mobilelab ALL=(root) NOPASSWD: /usr/bin/systemctl poweroff, /usr/bin/systemctl reboot
EOF
chmod 0440 /etc/sudoers.d/mobilelab-power
if visudo -c -f /etc/sudoers.d/mobilelab-power > /dev/null; then
  echo "    /etc/sudoers.d/mobilelab-power is valid"
else
  rm -f /etc/sudoers.d/mobilelab-power
  echo "ERROR: the sudoers file did not validate. It was removed." >&2
  exit 1
fi

echo
echo "==> enabling the kiosk for ${KIOSK_USER}"
loginctl enable-linger "${KIOSK_USER}" > /dev/null 2>&1 || true
runuser -u "${KIOSK_USER}" -- env XDG_RUNTIME_DIR="/run/user/${KIOSK_UID}" \
  systemctl --user daemon-reload
runuser -u "${KIOSK_USER}" -- env XDG_RUNTIME_DIR="/run/user/${KIOSK_UID}" \
  systemctl --user enable mobilelab-kiosk.service

echo
echo "==> state"
runuser -u "${KIOSK_USER}" -- env XDG_RUNTIME_DIR="/run/user/${KIOSK_UID}" \
  systemctl --user is-enabled mobilelab-kiosk.service
echo "    ssh after the change: $(systemctl is-active ssh), enabled: $(systemctl is-enabled ssh)"

echo
echo "==> HOW TO GET OUT, at the screen, with no SSH"
echo "    Ctrl+Alt+K        stops the kiosk, the desktop comes back"
echo "    Ctrl+Alt+Shift+K  starts the kiosk again"
echo "    Ctrl+Alt+F2       a text login on another screen, always works"
echo "    Ctrl+Alt+F7       back to the graphical screen"
echo
echo "==> HOW TO TURN THE KIOSK OFF FOR GOOD, one command"
echo "    sudo runuser -u ${KIOSK_USER} -- env XDG_RUNTIME_DIR=/run/user/${KIOSK_UID} \\"
echo "         systemctl --user disable --now mobilelab-kiosk.service"
echo
echo "==> done. The kiosk starts at the next login or reboot."
