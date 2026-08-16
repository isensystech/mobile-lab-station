/*
 * The sensor suite page.
 *
 * TWO RULES SHAPE THIS FILE.
 *
 * 1. A PLANNED sensor shows no value, no placeholder, and no example. The API
 *    sends no `reading` key at all for a planned sensor, so there is nothing to
 *    draw. This code also refuses to draw one if a future API ever sent it.
 *
 * 2. A LIVE or MANUAL sensor shows the newest real reading. If the API sends
 *    `reading: null`, the tile says the value is unavailable. It NEVER falls
 *    back to the illustrative number in sensors.html.
 *
 * The page writes counts onto the body so a headless browser can check both
 * rules without a person looking. That is gates 3 and 4.
 */

const PILL = { live: "Live", manual: "Manual", planned: "Planned" };

function whenText(iso) {
  const when = new Date(iso);
  const minutes = Math.round((Date.now() - when.getTime()) / 60000);
  if (minutes < 1) return "just now";
  if (minutes < 60) return `${minutes} minutes ago`;
  const hours = Math.round(minutes / 60);
  if (hours < 48) return `${hours} hours ago`;
  return `${Math.round(hours / 24)} days ago`;
}

function tidy(value) {
  const rounded = Math.round(value * 100) / 100;
  return String(rounded);
}

function buildTile(sensor) {
  const tile = document.createElement("div");
  tile.className = "tile";
  tile.dataset.status = sensor.status;
  tile.dataset.name = sensor.name;
  tile.dataset.number = String(sensor.number);

  const head = document.createElement("div");
  head.className = "tile-head";
  head.innerHTML =
    `<p class="tile-name">${sensor.name}</p>` +
    `<span class="pill pill-${sensor.status}">${PILL[sensor.status] || sensor.status}</span>`;
  tile.appendChild(head);

  const params = document.createElement("p");
  params.className = "tile-params";
  params.textContent = sensor.parameters;
  tile.appendChild(params);

  const value = document.createElement("p");
  const meta = document.createElement("p");
  meta.className = "tile-meta";

  const planned = sensor.status === "planned";
  const hasReading = !planned && sensor.reading != null;

  if (planned) {
    /*
     * Rule 1. Nothing numeric, ever. data-value stays empty so a test can
     * assert on it rather than reading the text by eye.
     */
    value.className = "tile-value tile-none";
    value.textContent = "Not fitted. No readings.";
    tile.dataset.value = "";
    meta.textContent = `Planned for ${sensor.tier}. Interface: ${sensor.interface}.`;
  } else if (hasReading) {
    value.className = "tile-value";
    value.innerHTML =
      `${tidy(sensor.reading.value)} <span class="unit">${sensor.reading.unit || ""}</span>`;
    tile.dataset.value = tidy(sensor.reading.value);
    meta.textContent =
      `Measured ${whenText(sensor.reading.ts)}, from ${sensor.reading.source}.`;
  } else {
    /*
     * Rule 2. The API had no reading. Say so. Do not reach for the shell.
     */
    value.className = "tile-value tile-none tile-unavailable";
    value.textContent = "Unavailable. No reading stored.";
    tile.dataset.value = "";
    meta.textContent = `This sensor reads ${sensor.reads.sensor} ${sensor.reads.metric}.`;
  }

  tile.appendChild(value);
  tile.appendChild(meta);

  const note = document.createElement("p");
  note.className = "tile-note";
  note.textContent = sensor.note;
  tile.appendChild(note);

  return { tile, planned, hasReading };
}

async function start() {
  const grid = document.getElementById("tile-grid");
  let sensors;
  try {
    const response = await fetch("/api/sensors");
    if (!response.ok) throw new Error(`The API answered ${response.status}.`);
    sensors = await response.json();
  } catch (error) {
    /*
     * Even on failure the shell must go. A stale example number is worse than
     * an empty page.
     */
    grid.innerHTML =
      '<div class="tile"><p class="tile-value tile-none tile-unavailable">' +
      "Unavailable. The station did not answer.</p></div>";
    document.body.dataset.status = "error";
    document.body.dataset.plannedWithValue = "0";
    return;
  }

  grid.innerHTML = "";
  let planned = 0;
  let live = 0;
  let manual = 0;
  let withValue = 0;
  let unavailable = 0;
  let plannedWithValue = 0;

  sensors.forEach((sensor) => {
    const built = buildTile(sensor);
    grid.appendChild(built.tile);
    if (built.planned) {
      planned += 1;
      if (Object.prototype.hasOwnProperty.call(sensor, "reading")) plannedWithValue += 1;
    } else {
      if (sensor.status === "live") live += 1;
      if (sensor.status === "manual") manual += 1;
      if (built.hasReading) withValue += 1;
      else unavailable += 1;
    }
  });

  /*
   * The working count counts CAPABILITY, not data.
   *
   * A rain gauge that nobody read this morning still works. Counting only the
   * tiles that carry a number today would drop it, and the page would say the
   * station has less than it has.
   */
  const working = live + manual;

  const isAre = (n) => (n === 1 ? "is" : "are");
  const hasHave = (n) => (n === 1 ? "has" : "have");

  document.getElementById("counts").textContent =
    `${working} of ${sensors.length} sensors work today. ` +
    `${live} ${isAre(live)} live and ${manual} ${isAre(manual)} read by hand. ` +
    `${planned} ${isAre(planned)} planned. ` +
    `Of the ${working} that work, ${withValue} ${hasHave(withValue)} a reading now and ` +
    `${unavailable} ${hasHave(unavailable)} none yet.`;

  document.body.dataset.status = "ready";
  document.body.dataset.sensorCount = String(sensors.length);
  document.body.dataset.workingCount = String(working);
  document.body.dataset.liveCount = String(live);
  document.body.dataset.manualCount = String(manual);
  document.body.dataset.plannedCount = String(planned);
  document.body.dataset.valueCount = String(withValue);
  document.body.dataset.unavailableCount = String(unavailable);
  document.body.dataset.plannedWithValue = String(plannedWithValue);
}

start();
