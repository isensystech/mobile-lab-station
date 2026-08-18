/*
 * The GPS status indicator.
 *
 * It sits beside the Power control, and it loads on every page, because a
 * person who is about to record something needs to know whether the station
 * knows where it is, whichever page they are looking at.
 *
 * THE STATE IS THE FIX, NOT THE CABLE.
 *
 * A receiver that is plugged in, powered, and sending perfect sentences with
 * valid checksums can still have no idea where it is. That is what happens
 * indoors, every time. This dongle sees eight satellites through the roof and
 * uses none of them. An indicator that went green because bytes were arriving
 * would be green in the one state where the position is worthless, and a
 * student would write down a location the station never had.
 *
 * So green means a solved 3D fix on four or more satellites. Nothing else.
 *
 * COLOUR IS NEVER THE ONLY SIGNAL.
 *
 * The badge is a 36px circle with a satellite in it, because the bar has no
 * horizontal space to spare. A satellite drawn identically in four colours
 * would leave colour carrying the whole meaning, which fails for a deuteranope
 * and fails in Florida sun. So the DRAWING changes with the state, not only its
 * colour. The stylesheet shows or hides a part of the icon per state:
 *
 *     GREEN  satellite with two signal arcs   solid ring    GPS OK
 *     AMBER  satellite, no arcs               dashed ring   NO FIX
 *     RED    satellite struck through         dotted ring   NO GPS
 *     GREY   satellite with a question mark   plain ring    GPS ?
 *
 * The words in the last column are still set on every change. They live in
 * #gps-label, which the stylesheet moves off screen rather than deleting, and
 * in the button's aria-label. A screen reader still hears them, and a gate can
 * still assert on the word without reading a pixel.
 */

const gpsButton = document.getElementById("gps-open");
const gpsPanel = document.getElementById("gps-panel");
const gpsClose = document.getElementById("gps-close");
const gpsLabel = document.getElementById("gps-label");

const GPS_HIDDEN = "modal-hidden";
const GPS_POLL_MS = 4000;

/*
 * GREY is the only state this file invents. It means "not asked yet".
 *
 * It is deliberately NOT the state for a driver that is missing or dead. The
 * API answers RED for those, because they are real faults and a grey badge
 * reads as harmless. Grey lasts until the first answer arrives, and no longer.
 */
const KNOWN_STATES = ["green", "amber", "red", "grey"];

const FALLBACK_LABELS = {
  green: "GPS OK",
  amber: "NO FIX",
  red: "NO GPS",
  grey: "GPS ?",
};

let lastPayload = null;

/*
 * Report the real size of the badge, the way fit.js reports the real size of
 * the page.
 *
 * A gate that reads the stylesheet proves what was asked for, not what was
 * drawn. A long label, an inherited font, or a bar that ran out of room would
 * all change the drawn size and leave the stylesheet saying 56. So the number
 * the gate reads comes from the layout engine after the label is in place.
 */
function reportTarget() {
  const box = gpsButton.getBoundingClientRect();
  const width = Math.round(box.width);
  const height = Math.round(box.height);
  document.body.dataset.gpsTarget = `${width}x${height}`;
  document.body.dataset.gpsTargetMin = String(Math.min(width, height));

  /*
   * Report the power control's height beside it, where there is one.
   *
   * The badge must READ as the same kind of control as the power button, and
   * the only way to check that is to measure both and compare. A gate that
   * asserts a fixed pixel count would still pass on the day somebody changes
   * the bar and the two stop matching.
   */
  const power = document.getElementById("power-open");
  if (power) {
    document.body.dataset.powerTargetHeight = String(
      Math.round(power.getBoundingClientRect().height)
    );
  }
}

function setState(state, label) {
  const known = KNOWN_STATES.includes(state) ? state : "grey";
  gpsButton.dataset.gpsState = known;
  gpsButton.dataset.gps = known;
  document.body.dataset.gps = known;
  gpsLabel.textContent = label || FALLBACK_LABELS[known];
  gpsButton.setAttribute(
    "aria-label",
    `GPS status: ${gpsLabel.textContent}. Press for detail.`
  );
  reportTarget();
}

function text(value, fallback) {
  if (value === null || value === undefined || value === "") return fallback || "Not known";
  return String(value);
}

function coordinate(payload) {
  const lat = payload.position && payload.position.lat;
  const lon = payload.position && payload.position.lon;
  if (lat === null || lat === undefined || lon === null || lon === undefined) {
    return "No position";
  }
  return `${Number(lat).toFixed(5)}, ${Number(lon).toFixed(5)}`;
}

function fillDetail(payload) {
  const fix = payload.fix || {};
  const clock = payload.clock || {};
  const driver = payload.driver || {};
  const threshold = payload.threshold || {};

  const rows = [
    ["State", `${payload.label || ""} - ${text(payload.detail, "")}`],
    ["Fix type", text(fix.mode_text)],
    ["Satellites used", text(fix.satellites_used, "0")],
    ["Satellites seen", text(fix.satellites_seen, "0")],
    ["Needed for GPS OK", `${text(threshold.min_satellites_used, "4")} satellites and a 3D fix`],
    ["Position", coordinate(payload)],
    ["Time of last fix", text(payload.last_fix_at, "There is no fix yet")],
    ["Clock source", `${text(clock.source)}. ${text(clock.note, "")}`],
    ["Station clock", text(clock.system_time)],
    ["Receiver", text(payload.device, "No device")],
    ["Driver report", driver.stale ? "The driver is silent" : `${text(driver.age_seconds, "0")} seconds ago`],
  ];

  const body = document.getElementById("gps-rows");
  body.innerHTML = "";
  for (const [name, value] of rows) {
    const row = document.createElement("tr");
    const head = document.createElement("th");
    head.scope = "row";
    head.textContent = name;
    const cell = document.createElement("td");
    cell.textContent = value;
    row.append(head, cell);
    body.append(row);
  }

  /*
   * Hard rule 3. A replayed log is not a measurement, and the panel says so in
   * words rather than leaving the reader to notice a source name.
   */
  const warn = document.getElementById("gps-simulated");
  if (payload.simulated) {
    warn.textContent =
      "SIMULATED. A recorded log feeds this position. It is not a measurement of where the station is.";
    warn.classList.remove("gps-hidden");
  } else {
    warn.classList.add("gps-hidden");
  }
}

async function pollGps() {
  try {
    const response = await fetch("/api/gps", { cache: "no-store" });
    if (!response.ok) throw new Error(`the API answered ${response.status}`);
    const payload = await response.json();
    lastPayload = payload;
    setState(payload.state, payload.label);
    if (!gpsPanel.classList.contains(GPS_HIDDEN)) fillDetail(payload);
  } catch (error) {
    /*
     * The API is unreachable. That is not a GPS fault, but from the screen it
     * is the same thing: the station cannot tell you where it is. RED is
     * honest here. Green would not be.
     */
    lastPayload = null;
    setState("red", "NO GPS");
  }
}

if (gpsButton && gpsPanel) {
  setState("grey", "GPS ?");

  gpsButton.addEventListener("click", () => {
    if (lastPayload) fillDetail(lastPayload);
    gpsPanel.classList.remove(GPS_HIDDEN);
    document.body.dataset.gpsPanel = "open";
  });

  gpsClose.addEventListener("click", () => {
    gpsPanel.classList.add(GPS_HIDDEN);
    document.body.dataset.gpsPanel = "closed";
  });

  gpsPanel.addEventListener("click", (event) => {
    if (event.target === gpsPanel) {
      gpsPanel.classList.add(GPS_HIDDEN);
      document.body.dataset.gpsPanel = "closed";
    }
  });

  document.body.dataset.gpsPanel = "closed";

  pollGps();
  setInterval(pollGps, GPS_POLL_MS);

  /*
   * gps=show opens the detail panel, the same as a press on the badge. The
   * power dialog, the About card, and the lag slider carry the same kind of
   * hook, for the same reason: a headless browser cannot tap.
   */
  if (new URLSearchParams(window.location.search).get("gps") === "show") {
    window.setTimeout(() => {
      if (lastPayload) fillDetail(lastPayload);
      gpsPanel.classList.remove(GPS_HIDDEN);
      document.body.dataset.gpsPanel = "open";
    }, 600);
  }
}
