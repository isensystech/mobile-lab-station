#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

MARKER="/var/lib/mobilelab/gps-soak.done"
UNIT="mobilelab-gps-soak.service"
LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"

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

echo "================================================================"
echo "EYEWITNESS: THE GPS BRIDGE SOAK"
echo "================================================================"
echo
echo "This is for Scott, with the station in his hands."
echo "It measures the bridge. It repairs nothing."
echo
echo "Read the whole page first. It takes about 35 minutes of clock time."
echo "Almost all of that is waiting."
echo

echo "----------------------------------------------------------------"
echo "WHAT THIS TEST ASKS"
echo "----------------------------------------------------------------"
echo
echo "  The USB bridge decays. Indoors it stayed clean for about twenty"
echo "  seconds, then went unreadable. The bytes kept coming at the same"
echo "  rate. The bytes became wrong. That is a byte clock running about"
echo "  six percent fast."
echo
echo "  ONE THING SPOILED THAT MEASUREMENT. weather-collector was writing"
echo "  into the same port every two seconds. It is disabled now."
echo
echo "  THE QUESTION: does the decay still happen with that program gone?"
echo
echo "  The station goes OUTSIDE for this, for two reasons. The receiver"
echo "  needs sky to report a fix. The bridge runs hotter outside, and a"
echo "  crystal that drifts as it warms is the leading suspect."
echo

echo "----------------------------------------------------------------"
echo "STEP 1. ARM IT. Do this indoors, before you carry it out."
echo "----------------------------------------------------------------"
echo
echo "  Run this one command:"
echo
echo "    sudo ops/install-gps-soak.sh"
echo
echo "  Read what it prints. It refuses to arm if weather-collector is"
echo "  running. That refusal is correct. Stop that service and run it again."
echo
echo "  The last lines must say the marker is absent and the unit is enabled."
echo "  Then the soak fires by itself on the next boot. You type nothing."
echo
echo "  IF YOU WANT TO REHEARSE FIRST, and not burn the one shot:"
echo "    sudo ops/gps-soak.sh --smoke"
echo "  That runs two buckets of twenty seconds. It does not disarm anything."
echo "  Read it with: ops/gps-soak-report.sh --smoke"
echo

echo "----------------------------------------------------------------"
echo "STEP 2. WHERE TO PUT THE STATION"
echo "----------------------------------------------------------------"
echo
echo "  Put it outside, on a flat surface, with a clear view of open sky."
echo
echo "  GOOD:  the middle of the yard, the driveway, a garden table."
echo "  BAD:   against the house wall, under a tree, on a covered porch,"
echo "         under a car port, beside a metal shed."
echo
echo "  The receiver must see most of the sky, not a slice of it. A wall"
echo "  takes away half the satellites and the run measures the wall."
echo
echo "  Put the dongle in the open air. Do not bury it under the case or"
echo "  under a cable coil. The temperature column is part of the test."
echo
echo "  LEAVE IT ALONE ONCE IT IS PLACED. Do not move it. Do not unplug the"
echo "  dongle. Do not touch the USB port. A replug resets the decay, and"
echo "  the decay is the thing being measured."
echo

echo "----------------------------------------------------------------"
echo "STEP 3. POWER IT ON. Then walk away."
echo "----------------------------------------------------------------"
echo
echo "  Power the station on. Start a timer for 30 minutes."
echo
echo "  The soak starts by itself, about a minute after boot."
echo "  It measures for 25 minutes."
echo
echo "  THE GPS BADGE GOES RED, AND STAYS RED, FOR THE WHOLE 25 MINUTES."
echo
echo "  THAT IS CORRECT. IT IS NOT A FAULT."
echo "  The soak takes the serial port off the relay to read it directly."
echo "  With the relay stopped, the badge has nothing to report, so it says"
echo "  no GPS. The relay comes back on its own at the end, and the badge"
echo "  goes back to amber or green."
echo
echo "  IF THE BADGE IS STILL RED 35 MINUTES AFTER POWER ON, that is a real"
echo "  fault. Read the report and check gate 3."
echo
echo "  Do not open the kiosk pages during the run. Nothing there is under"
echo "  test, and the CPU column reads cleaner without a browser working."
echo

echo "----------------------------------------------------------------"
echo "OPTIONAL. WATCH IT FROM INSIDE, OVER WIFI."
echo "----------------------------------------------------------------"
echo
if [ -n "${LAN_IP}" ]; then
  echo "  From a laptop on the same network:"
  echo "    ssh ${USER:-pi}@${LAN_IP}"
else
  echo "  From a laptop on the same network, ssh to the station."
fi
echo "    ops/gps-soak-report.sh --watch"
echo
echo "  It prints one line each minute. Press Ctrl-C to stop watching."
echo "  STOPPING THE WATCH DOES NOT STOP THE SOAK. They are separate."
echo
echo "  Watching is optional. The report holds everything the watch shows."
echo

echo "----------------------------------------------------------------"
echo "STEP 4. COME BACK. ONE COMMAND PRINTS THE REPORT."
echo "----------------------------------------------------------------"
echo
echo "  After 30 minutes, run this. It is the only command you need:"
echo
echo "    ops/gps-soak-report.sh"
echo
echo "  It needs no sudo. It prints a table of 25 minutes and a verdict in"
echo "  plain words at the bottom."
echo
echo "  READ THESE FOUR THINGS FIRST:"
echo
echo "    1. THE VERDICT, at the bottom. It answers the question directly."
echo "    2. THE MINUTE THE STREAM BECAME UNREADABLE. It gives a minute"
echo "       number, or it says the stream never became unreadable."
echo "    3. THE BEST COLUMN in the table. While it reads 9600 the bridge is"
echo "       behaving. When it starts reading 10000 or 10400 the byte clock"
echo "       is running fast. Note the minute where that first changes."
echo "    4. THE TEMPC COLUMN beside it. Look at the two together."
echo "       ONE RUN CANNOT PROVE THAT HEAT CAUSES THE DRIFT. The report"
echo "       says so itself. It reports the number and refuses the claim."
echo

echo "----------------------------------------------------------------"
echo "STEP 5. PROVE IT ONLY FIRES ONCE. This is a gate."
echo "----------------------------------------------------------------"
echo
echo "  Reboot the station a second time:"
echo
echo "    sudo reboot"
echo
echo "  Wait two minutes. Then run:"
echo
echo "    systemctl is-active ${UNIT}"
echo
echo "  IT MUST SAY inactive. The GPS badge must return to amber or green"
echo "  within a minute of boot, and not sit red for 25 minutes."
echo
echo "  IF IT RUNS A SECOND TIME, that is a defect. Disarm it by hand:"
echo "    sudo ops/install-gps-soak.sh disarm"
echo

echo "----------------------------------------------------------------"
echo "WHAT THIS TEST DOES NOT DO"
echo "----------------------------------------------------------------"
echo
echo "  It does not repair the bridge. It measures it."
echo "  It does not change the relay, the driver, the badge, or any code."
echo "  It does not power cycle the USB port during the run."
echo "  It does not stop weather-collector for you. It refuses to arm while"
echo "  that service runs, and it tells you what to do."
echo "  It does not touch wlan0, hostapd, dnsmasq, or any network setting."
echo

echo "----------------------------------------------------------------"
echo "STATE RIGHT NOW"
echo "----------------------------------------------------------------"
echo
echo "  soak unit     $(unit_enabled ${UNIT})"
if [ -f "${MARKER}" ]; then
  echo "  marker        present. The soak will NOT fire on the next boot."
  echo "                Run 'sudo ops/install-gps-soak.sh' to arm it again."
else
  echo "  marker        absent. The soak WILL fire on the next boot."
fi
if [ -f /var/log/mobilelab/gps-soak/report.txt ]; then
  echo "  report        /var/log/mobilelab/gps-soak/report.txt"
else
  echo "  report        none yet"
fi
echo
