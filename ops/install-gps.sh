#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VENV="${REPO_ROOT}/.venv"
GPS_LINK="/dev/mobilelab-gps"
GPS_BAUD="9600"
RELAY_PORT="2948"
USB_ID="3-2"

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: run this script with sudo." >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

echo "==> what this script does NOT touch"
echo "    wlan0, hostapd, dnsmasq, NetworkManager, dhcpcd, iptables, ufw."
echo "    systemd-timesyncd and NTP configuration."
echo "    SSH and a correct clock are both recovery critical."
echo

echo "==> installing gpsd"
apt-get update -qq
apt-get install -y -qq gpsd gpsd-clients util-linux-extra
dpkg-query -W -f='    gpsd ${Version}\n' gpsd
echo "    util-linux-extra supplies hwclock, which reads the RTC directly."
echo "    Debian trixie does not install it with the base system."

echo "==> checking for another program on the serial port"
CONFLICT=0
if systemctl is-active --quiet weather-collector.service; then
  echo "    WARNING: weather-collector.service is running."
  echo "    It hardcodes /dev/ttyUSB0 for a DFRobot SEN0658 that is not fitted,"
  echo "    so it opens the GPS receiver instead and corrupts every sentence."
  echo "    Stop it before you trust anything below:"
  echo "      sudo systemctl stop weather-collector.service"
  CONFLICT=1
fi
if [ "${CONFLICT}" -eq 0 ]; then
  echo "    no conflicting unit is running"
fi

echo "==> installing the udev rule"
install -m 0644 "${SCRIPT_DIR}/udev/70-mobilelab-gps.rules" \
  /etc/udev/rules.d/70-mobilelab-gps.rules
udevadm control --reload-rules
udevadm trigger --subsystem-match=tty --action=add
sleep 2

if [ -e "${GPS_LINK}" ]; then
  echo "    ${GPS_LINK} -> $(readlink -f "${GPS_LINK}")"
else
  echo "    ERROR: ${GPS_LINK} did not appear." >&2
  echo "    The dongle may be in a different USB socket. Read the real path with:" >&2
  echo "      udevadm info -q property -n /dev/ttyUSB0 | grep ID_PATH=" >&2
  echo "    Then edit ops/udev/70-mobilelab-gps.rules. See ops/udev/README.md." >&2
  exit 1
fi

if [ ! -x "${VENV}/bin/python" ]; then
  echo "ERROR: ${VENV} does not exist. Run ops/install-services.sh first." >&2
  exit 1
fi

echo "==> letting the service user read the code"
chmod -R a+rX "${REPO_ROOT}/services"

echo "==> installing the serial relay unit"
echo "    THE RELAY IS NOT OPTIONAL ON THIS HARDWARE. Measured 2026-08-17:"
echo "    a single 8N1 to 8O1 to 8N1 parity toggle stops this PL2303 dongle"
echo "    dead. It delivers nothing afterwards, and only a USB unbind and"
echo "    rebind brings it back. Closing the port does not. Restarting gpsd"
echo "    does not."
echo "    That parity toggle is exactly what gpsd's packet sniffer does to"
echo "    identify an unknown device. -s pins the speed and -b stops gpsd"
echo "    WRITING to the receiver, but neither stops the parity hunt."
echo "    So gpsd is not given the serial port at all. The relay holds it,"
echo "    sets 8N1 once, and serves the bytes over loopback TCP. A socket has"
echo "    no parity to hunt, so gpsd has nothing left to break."
echo "    See services/mobilelab/gpsrelay.py for the measurements."
sed "s|__REPO_ROOT__|${REPO_ROOT}|g" \
  "${SCRIPT_DIR}/systemd/mobilelab-gpsrelay.service" \
  > /etc/systemd/system/mobilelab-gpsrelay.service
chmod 0644 /etc/systemd/system/mobilelab-gpsrelay.service

echo "==> installing the GPS driver unit"
sed "s|__REPO_ROOT__|${REPO_ROOT}|g" \
  "${SCRIPT_DIR}/systemd/mobilelab-gps.service" \
  > /etc/systemd/system/mobilelab-gps.service
chmod 0644 /etc/systemd/system/mobilelab-gps.service
systemctl daemon-reload

echo "==> pointing gpsd at the relay, not at the serial port"
cat > /etc/default/gpsd <<EOF
START_DAEMON="true"
USBAUTO="false"
DEVICES="tcp://127.0.0.1:${RELAY_PORT}"
GPSD_OPTIONS="-n -b"
EOF
cat /etc/default/gpsd | sed 's/^/    /'

echo "==> USBAUTO is false on purpose"
echo "    With USBAUTO true, gpsd grabs every USB serial device that appears."
echo "    The RS485 dongle for the Modbus sensors is a USB serial device, so"
echo "    gpsd would take that too and fight the Modbus driver for it, and it"
echo "    would take the GPS dongle back off the relay."
echo
echo "==> -n is set on purpose"
echo "    Without it gpsd opens the source only when a client connects, and"
echo "    closes it when the last client leaves. A cold receiver needs minutes"
echo "    to find satellites. -n keeps it listening, so a person who carries"
echo "    the station outside gets a fix instead of a restart."

echo "==> stopping everything that can touch the serial port, BEFORE the power cycle"
echo "    ORDER MATTERS HERE, and getting it wrong wasted a debugging session."
echo "    A gpsd still configured for the raw device will re-grab it the moment"
echo "    the USB rebind fires, hunt the parity again, and put the dongle back"
echo "    into the stuck state. The power cycle then repairs nothing."
systemctl stop mobilelab-gps.service   > /dev/null 2>&1 || true
systemctl stop gpsd.service gpsd.socket > /dev/null 2>&1 || true
systemctl stop mobilelab-gpsrelay.service > /dev/null 2>&1 || true
sleep 2
if fuser /dev/ttyUSB0 > /dev/null 2>&1; then
  echo "    WARNING: something still holds /dev/ttyUSB0:"
  fuser -v /dev/ttyUSB0 2>&1 | sed 's/^/      /'
else
  echo "    the serial port is free"
fi

echo "==> power cycling the USB port before the first start"
echo "    The dongle may already be in the stuck state from an earlier run."
if [ -n "${USB_ID}" ] && [ -e "/sys/bus/usb/devices/${USB_ID}" ]; then
  echo "${USB_ID}" > /sys/bus/usb/drivers/usb/unbind 2>/dev/null || true
  sleep 3
  echo "${USB_ID}" > /sys/bus/usb/drivers/usb/bind 2>/dev/null || true
  sleep 4
  udevadm trigger --subsystem-match=tty --action=add
  sleep 2
  echo "    ${GPS_LINK} -> $(readlink -f "${GPS_LINK}" 2>/dev/null || echo MISSING)"
fi

echo "==> starting the relay, then gpsd, then the driver"
systemctl enable mobilelab-gpsrelay.service
systemctl restart mobilelab-gpsrelay.service
sleep 3
systemctl enable gpsd.service
systemctl restart gpsd.service
sleep 4
systemctl enable mobilelab-gps.service
systemctl restart mobilelab-gps.service
sleep 8

for unit in mobilelab-gpsrelay gpsd mobilelab-gps; do
  echo "    ${unit}.service is $(systemctl is-active ${unit}.service)"
done

echo
echo "==> the driver reports this now"
timeout 10 mosquitto_sub -h 127.0.0.1 -t mobilelab/gps/status -C 1 2>&1 \
  | "${VENV}/bin/python" "${SCRIPT_DIR}/gps-fixtures/show-status.py" \
  || echo "    no status yet"

echo
echo "==> done. Run ops/verify-gps.sh next."
if [ "${CONFLICT}" -eq 1 ]; then
  echo
  echo "==> REMINDER: weather-collector.service is still running and still holds"
  echo "    /dev/ttyUSB0. The gates will fail until you stop it."
fi
