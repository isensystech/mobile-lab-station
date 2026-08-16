#!/usr/bin/env bash
set -uo pipefail

: <<'ABOUT'
Installs the boot splash.

It covers the boot with one branded still, from the firmware handover to the
moment the kiosk paints. It follows the water quality logger, which plays one
branded pass at boot and then hands off.

It edits two boot files. Both are backed up first, and both are checked before
this script finishes. A bad cmdline.txt stops the machine from booting, and SSH
does not come back, so every edit here is checked and reported.

It never touches wlan0, hostapd, dnsmasq, NetworkManager, dhcpcd, iptables, or
ufw. It leaves the wireless regulatory setting in cmdline.txt exactly as found.
ABOUT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

THEME="planetwerx"
THEME_DIR="/usr/share/plymouth/themes/${THEME}"
LOCKUP="${REPO_ROOT}/services/mobilelab/static/brand/planetwerx-lockup-white.png"
BOOT_DIR="/boot/firmware"
CMDLINE="${BOOT_DIR}/cmdline.txt"
CONFIG="${BOOT_DIR}/config.txt"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

WIDTH="${MOBILELAB_SPLASH_WIDTH:-1024}"
HEIGHT="${MOBILELAB_SPLASH_HEIGHT:-600}"

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: run this script with sudo." >&2
  exit 1
fi

for f in "${CMDLINE}" "${CONFIG}"; do
  if [ ! -f "${f}" ]; then
    echo "ERROR: ${f} is missing. This is not a Raspberry Pi boot layout." >&2
    exit 1
  fi
done

if [ ! -f "${LOCKUP}" ]; then
  echo "ERROR: the brand lockup is missing at ${LOCKUP}." >&2
  echo "  The splash is not drawn without it, on purpose." >&2
  exit 1
fi

echo "==> backing up the boot files"
cp -a "${CMDLINE}" "${CMDLINE}.before-splash-${STAMP}"
cp -a "${CONFIG}" "${CONFIG}.before-splash-${STAMP}"
echo "    ${CMDLINE}.before-splash-${STAMP}"
echo "    ${CONFIG}.before-splash-${STAMP}"

echo "==> drawing the splash at ${WIDTH} by ${HEIGHT}"
mkdir -p "${THEME_DIR}"
if ! python3 "${SCRIPT_DIR}/make-splash.py" \
     --lockup "${LOCKUP}" \
     --out "${THEME_DIR}" \
     --width "${WIDTH}" \
     --height "${HEIGHT}"; then
  echo "ERROR: the splash was not drawn. Nothing else was changed." >&2
  exit 1
fi

echo "==> installing the theme"
install -m 0644 "${SCRIPT_DIR}/plymouth/${THEME}.plymouth" "${THEME_DIR}/${THEME}.plymouth"
install -m 0644 "${SCRIPT_DIR}/plymouth/${THEME}.script" "${THEME_DIR}/${THEME}.script"
ls -1 "${THEME_DIR}" | sed 's/^/    /'

echo "==> turning off the firmware rainbow square"
if grep -qE "^disable_splash=" "${CONFIG}"; then
  sed -i 's/^disable_splash=.*/disable_splash=1/' "${CONFIG}"
  echo "    updated the existing disable_splash line"
else
  printf '\ndisable_splash=1\n' >> "${CONFIG}"
  echo "    added disable_splash=1"
fi

echo "==> quieting the kernel logos and the text cursor"
LINE="$(tr -d '\n' < "${CMDLINE}")"

for token in logo.nologo vt.global_cursor_default=0; do
  case " ${LINE} " in
    *" ${token} "*)
      echo "    ${token} was already present"
      ;;
    *)
      LINE="${LINE} ${token}"
      echo "    added ${token}"
      ;;
  esac
done

case " ${LINE} " in
  *" root="*) : ;;
  *)
    echo "ERROR: the new cmdline lost its root setting. Nothing was written." >&2
    exit 1
    ;;
esac

case " ${LINE} " in
  *" rootfstype="*) : ;;
  *)
    echo "ERROR: the new cmdline lost rootfstype. Nothing was written." >&2
    exit 1
    ;;
esac

printf '%s\n' "${LINE}" > "${CMDLINE}"

CMDLINE_LINES="$(wc -l < "${CMDLINE}" | tr -d ' ')"
if [ "${CMDLINE_LINES}" != "1" ]; then
  echo "ERROR: cmdline.txt now holds ${CMDLINE_LINES} lines. It must hold one." >&2
  echo "  Putting the backup back." >&2
  cp -a "${CMDLINE}.before-splash-${STAMP}" "${CMDLINE}"
  exit 1
fi
echo "    cmdline.txt is one line and keeps root and rootfstype"

echo "==> installing the background tool for the handover"
if ! command -v swaybg > /dev/null 2>&1; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y swaybg > /dev/null 2>&1
fi
if command -v swaybg > /dev/null 2>&1; then
  echo "    swaybg $(swaybg --version 2>&1 | head -1)"
else
  echo "WARNING: swaybg did not install. The gap before the kiosk paints will" >&2
  echo "  show the plain compositor background." >&2
fi

echo "==> making the desktop match the splash"
echo "    Plymouth stops when the display manager starts. The desktop then"
echo "    shows for a few seconds before the kiosk paints over it. That gap"
echo "    used to show the Raspberry Pi desktop on a purple background."
echo "    The desktop keeps every part it had. It only changes how it looks,"
echo "    so the gap matches the splash instead of breaking it."
echo "    The desktop stays usable, because Ctrl+Alt+K escapes onto it."

KIOSK_USER="${MOBILELAB_KIOSK_USER:-planetwerx}"
KIOSK_HOME="$(getent passwd "${KIOSK_USER}" | cut -d: -f6)"

if [ -z "${KIOSK_HOME}" ] || [ ! -d "${KIOSK_HOME}" ]; then
  echo "WARNING: no home directory for ${KIOSK_USER}. The desktop was left alone." >&2
else
  DESKTOP_CONFS="$(find "${KIOSK_HOME}/.config/pcmanfm" -name 'desktop-items-*.conf' 2> /dev/null)"
  if [ -z "${DESKTOP_CONFS}" ]; then
    echo "WARNING: no pcmanfm desktop configuration was found." >&2
  else
    for conf in ${DESKTOP_CONFS}; do
      cp -a "${conf}" "${conf}.before-splash-${STAMP}"
      sed -i \
        -e "s|^wallpaper=.*|wallpaper=${THEME_DIR}/splash.png|" \
        -e "s|^wallpaper_mode=.*|wallpaper_mode=stretch|" \
        -e "s|^desktop_bg=.*|desktop_bg=#052A30|" \
        -e "s|^desktop_shadow=.*|desktop_shadow=#052A30|" \
        -e "s|^show_trash=.*|show_trash=0|" \
        -e "s|^show_mounts=.*|show_mounts=0|" \
        -e "s|^show_documents=.*|show_documents=0|" \
        "${conf}"
      echo "    set ${conf}"
    done
  fi

  PANEL_INI="${KIOSK_HOME}/.config/wf-panel-pi/wf-panel-pi.ini"
  mkdir -p "$(dirname "${PANEL_INI}")"
  if [ -f "${PANEL_INI}" ]; then
    cp -a "${PANEL_INI}" "${PANEL_INI}.before-splash-${STAMP}"
  fi
  if ! grep -q "^autohide" "${PANEL_INI}" 2> /dev/null; then
    printf '[panel]\nautohide=true\nautohide_duration=300\n' >> "${PANEL_INI}"
    echo "    set the panel to hide itself"
    echo "    It still returns. Touch the top edge of the screen."
  fi
  chown -R "${KIOSK_USER}:${KIOSK_USER}" "${KIOSK_HOME}/.config/pcmanfm" "$(dirname "${PANEL_INI}")" 2> /dev/null
fi

echo "==> setting ${THEME} as the default theme and rebuilding the initramfs"
if ! plymouth-set-default-theme -R "${THEME}"; then
  echo "ERROR: the theme was not set. The boot files were already changed." >&2
  echo "  Put them back with the backups above if you stop here." >&2
  exit 1
fi

echo
echo "==> what is set now"
echo "    theme      $(plymouth-set-default-theme)"
echo "    cmdline    $(cat "${CMDLINE}")"
echo "    rainbow    $(grep -E '^disable_splash=' "${CONFIG}")"
echo
echo "The splash appears at the NEXT boot. Reboot to see it."
echo "To undo, put the two backups back and run:"
echo "  sudo plymouth-set-default-theme -R pix"
