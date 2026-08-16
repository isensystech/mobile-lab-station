/*
 * The overlay chart page, as a rehearsal rig.
 *
 * It draws three series on one time axis: salinity, the public record, and the
 * local rain gauge. A person reveals them one at a time during a lesson.
 *
 * It reads the local API. It never reads the fixture and it never reads the
 * database. The chart therefore shows the same numbers the kiosk will show.
 *
 * The page writes its state onto the body as data attributes. A headless
 * browser can then read the result without a screenshot, which is how
 * ops/verify-chart.sh and ops/verify-rehearsal.sh check the rules.
 *
 * SERIES ZERO IS THE RESPONSE. Every other series is a driver, and each driver
 * is correlated against series zero on its own. Architecture section 6 makes
 * sensor and metric the join key, so two rainfall series from two sources are
 * the ordinary case here, not a special one.
 */

import {
  assignAxes,
  axisBounds,
  buildCaption,
  buildDatasets,
  buildShiftNote,
  classifyProvenance,
  correlationAtStep,
  estimateLag,
  needsSimulatedBanner,
  pearson,
  stepMillis,
  strengthWord,
} from "/static/chart-core.js";

/*
 * The rig. Salinity first, because it is the response. Then the public record,
 * then the local gauge, which is the order the lesson reveals them in.
 *
 * The two rainfall series differ ONLY by source. Replacing a synthetic series
 * with a real one is a change of source and nothing else, so no code changes
 * when real data arrives.
 */
const DEFAULT_SERIES = [
  "water:salinity:synthetic:Salinity",
  "rain:rainfall:public_synthetic:NOAA",
  "rain:rainfall:synthetic:Rain Gauge",
];

const state = {
  payload: null,
  chart: null,
  estimate: null,
  drivers: [],
  shiftHours: 0,
  normalize: false,
  hidden: {},
  axisIds: [],
};

const el = (id) => document.getElementById(id);

function params() {
  const search = new URLSearchParams(window.location.search);
  const asked = search.getAll("series");
  return {
    hours: Number(search.get("hours") || el("range").value || 168),
    station: search.get("station_id") || el("station").value || "",
    series: asked.length ? asked : DEFAULT_SERIES,
    show: search.get("show"),
  };
}

async function fetchMulti() {
  const chosen = params();
  const to = new Date();
  const from = new Date(to.getTime() - chosen.hours * 3600000);

  const query = new URLSearchParams();
  chosen.series.forEach((spec) => query.append("series", spec));
  query.set("from", from.toISOString());
  query.set("to", to.toISOString());
  if (chosen.station) query.set("station_id", chosen.station);

  const response = await fetch(`/api/series/multi?${query.toString()}`);
  if (!response.ok) throw new Error(`The API answered ${response.status}.`);
  return response.json();
}

async function fetchStations() {
  try {
    const response = await fetch("/api/stations");
    if (!response.ok) return [];
    return await response.json();
  } catch (error) {
    return [];
  }
}

function renderBanner(payload) {
  const badge = el("simulated-banner");
  const simulated = needsSimulatedBanner(payload.series);
  /*
   * A series is untrusted when its labelling is malformed, AND ALSO when the
   * station does not recognise its source at all.
   *
   * An unknown source arrives from the API marked not real with a valid dashed
   * hint, so the shape check alone would call it well labelled. It is not. The
   * station is guessing. source_known says so, and saying UNKNOWN SOURCE is
   * more honest than saying SIMULATED, because nobody knows what it is.
   */
  const untrusted = payload.series.filter(
    (s) => !classifyProvenance(s).trusted || s.source_known === false
  );

  /*
   * Architecture section 5. The badge is persistent and it is not a tooltip.
   *
   * It is bound to is_real across EVERY series the page loaded, not only the
   * visible ones. Hiding a fake line does not make it real, and during
   * rehearsal this badge is how a person sees at a glance that something on
   * this screen is still a generator. It goes out on its own when every series
   * is real.
   */
  badge.classList.toggle("sim-hidden", !simulated);
  document.body.dataset.simulated = simulated ? "true" : "false";
  document.body.dataset.untrusted = untrusted.length ? "true" : "false";

  if (untrusted.length) {
    badge.textContent = "UNKNOWN SOURCE";
    el("sim-detail").textContent =
      "The station cannot confirm where these numbers come from. It therefore " +
      "treats them as not real. Do not use them as evidence.";
    el("warning").textContent =
      "A line has no usable provenance. The chart drew it as not real on purpose.";
  } else if (simulated) {
    badge.textContent = "SIMULATED DATA";
    el("sim-detail").textContent =
      "A generator made these numbers. Do not use them as evidence about any real place.";
    el("warning").textContent = "";
  } else {
    el("warning").textContent = "";
  }
}

function renderProvenance(payload) {
  const body = document.querySelector("#provenance-table tbody");
  body.innerHTML = "";
  payload.series.forEach((series, index) => {
    const verdict = classifyProvenance(series);
    const drawn = verdict.stepped ? "stepped" : verdict.dashed ? "dashed" : "solid";
    const row = document.createElement("tr");
    row.innerHTML = `
      <td>${series.name || series.key}</td>
      <td>${series.sensor} ${series.metric}</td>
      <td>${verdict.source}</td>
      <td><span class="tag ${verdict.isReal ? "tag-real" : "tag-fake"}">${
        verdict.isReal ? "REAL" : "NOT REAL"
      }</span></td>
      <td>${drawn}</td>`;
    body.appendChild(row);

    document.body.dataset[`${series.key}Dashed`] = String(verdict.dashed);
    document.body.dataset[`${series.key}Real`] = String(verdict.isReal);
    document.body.dataset[`${series.key}Stepped`] = String(verdict.stepped);
    if (index === 0) {
      document.body.dataset.aDashed = String(verdict.dashed);
      document.body.dataset.aReal = String(verdict.isReal);
    }
    if (index === 1) {
      document.body.dataset.bDashed = String(verdict.dashed);
      document.body.dataset.bReal = String(verdict.isReal);
    }
  });

  el("served-note").textContent =
    `The API answered from ${payload.served_from}. ` +
    `${payload.axis.length} time slots. ` +
    (payload.bucket ? `Each slot covers ${payload.bucket}.` : "Full detail, no grouping.");
  document.body.dataset.servedFrom = payload.served_from;
  document.body.dataset.points = String(payload.axis.length);
  document.body.dataset.seriesCount = String(payload.series.length);
}

/*
 * Correlate every driver against the response, one at a time.
 *
 * Reporting one number for "rainfall" would hide the whole lesson. The local
 * gauge and the cell average disagree, and the size of that disagreement is the
 * point. So each driver gets its own line, its own r, and its own source.
 */
function measureDrivers(payload) {
  const axisMillis = payload.axis.map((stamp) => new Date(stamp).getTime());
  const response = payload.series[0].values.map(Number);

  return payload.series.slice(1).map((series, offset) => {
    const index = offset + 1;
    const estimate = estimateLag(axisMillis, series.values.map(Number), response, 24);
    return {
      index,
      key: series.key,
      name: series.name || series.key,
      source: series.source,
      estimate,
    };
  });
}

function renderCaption() {
  const { payload, drivers } = state;
  const responseName = payload.series[0].name || payload.series[0].metric;

  const usable = drivers.filter((driver) => driver.estimate.usable);
  const strongest = usable.slice().sort(
    (a, b) => Math.abs(b.estimate.r) - Math.abs(a.estimate.r)
  )[0];

  const caption = buildCaption(
    strongest ? strongest.name : "rainfall",
    responseName,
    strongest ? strongest.estimate : { usable: false }
  );
  el("caption-headline").textContent = caption.headline;
  el("caption-detail").textContent = caption.detail;

  /*
   * One line per rainfall series, each labelled by its source, each showing r.
   */
  const pairBox = el("caption-pairs");
  pairBox.innerHTML = "";
  const summary = [];
  const line = document.createElement("p");
  line.className = "caption-pair";
  const chunks = [];
  drivers.forEach((driver) => {
    if (!driver.estimate.usable) {
      chunks.push(`<b>${driver.name}</b> (${driver.source}) not enough data`);
      return;
    }
    const hours = Math.round(driver.estimate.lagHours);
    const hourWord = hours === 1 ? "hour" : "hours";
    chunks.push(
      `<b>${driver.name}</b> from ${driver.source}: ` +
        `${strengthWord(driver.estimate.r)}, r = ${driver.estimate.r.toFixed(2)} ` +
        `at about ${hours} ${hourWord}`
    );
    summary.push(`${driver.name}=${driver.estimate.r.toFixed(3)}`);
    document.body.dataset[`${driver.key}R`] = driver.estimate.r.toFixed(3);
    document.body.dataset[`${driver.key}Strength`] = strengthWord(driver.estimate.r);
    document.body.dataset[`${driver.key}LagHours`] = driver.estimate.lagHours.toFixed(2);
  });
  line.innerHTML = chunks.join('<span class="pair-sep">|</span>');
  pairBox.appendChild(line);
  document.body.dataset.pairR = summary.join(",");

  const step = stepMillis(payload.axis.map((s) => new Date(s).getTime()));
  const stepHours = step / 3600000;
  const shiftSteps = stepHours ? Math.round(state.shiftHours / stepHours) : 0;
  const response = payload.series[0].values.map(Number);
  const first = payload.series[1] ? payload.series[1].values.map(Number) : [];
  const at =
    shiftSteps >= 0
      ? correlationAtStep(first, response, shiftSteps)
      : correlationAtStep(response, first, -shiftSteps);

  el("caption-shift").textContent = buildShiftNote(
    payload.series[1] ? payload.series[1].name : "rainfall",
    state.shiftHours,
    at.r,
    at.samples
  );

  document.body.dataset.caption = `${caption.headline} ${caption.detail}`;
  document.body.dataset.captionShift = el("caption-shift").textContent;
  document.body.dataset.lagHours =
    strongest && strongest.estimate.usable ? strongest.estimate.lagHours.toFixed(2) : "none";
  document.body.dataset.lagR =
    strongest && strongest.estimate.usable ? strongest.estimate.r.toFixed(3) : "none";
  document.body.dataset.shiftHours = String(state.shiftHours);
}

function formatWhen(value) {
  const when = new Date(value);
  const day = String(when.getDate()).padStart(2, "0");
  const month = when.toLocaleString("en", { month: "short" });
  const hour = String(when.getHours()).padStart(2, "0");
  const minute = String(when.getMinutes()).padStart(2, "0");
  return `${day} ${month} ${hour}:${minute}`;
}

/*
 * A stable fingerprint of where a line was actually drawn.
 *
 * The rule is that hiding one series must not change how the others look. A row
 * count cannot show that, and an eye cannot either. This reads the pixel
 * position of every point Chart.js placed for one series, and hashes it. Two
 * renders that agree on this string put that line on exactly the same pixels.
 */
function fingerprint(chart, datasetIndex) {
  const meta = chart.getDatasetMeta(datasetIndex);
  if (!meta || !meta.data || !meta.data.length) return "none";
  let hash = 2166136261;
  for (const point of meta.data) {
    const text = `${point.x.toFixed(2)},${point.y.toFixed(2)};`;
    for (let i = 0; i < text.length; i += 1) {
      hash ^= text.charCodeAt(i);
      hash = Math.imul(hash, 16777619) >>> 0;
    }
  }
  return `${meta.data.length}:${hash.toString(16)}`;
}

function renderChart() {
  const { payload } = state;
  const step = stepMillis(payload.axis.map((s) => new Date(s).getTime()));
  const stepHours = step / 3600000;
  const shiftSteps = stepHours ? Math.round(state.shiftHours / stepHours) : 0;

  const axisIds = assignAxes(payload.series);
  state.axisIds = axisIds;

  /* Every driver moves with the slider. The response stays where it is. */
  const shiftKeys = payload.series.map((_s, index) => index).filter((index) => index > 0);

  const { axisMillis, datasets } = buildDatasets(payload, {
    normalize: state.normalize,
    shiftSteps,
    shiftKeys,
    hidden: state.hidden,
    axisIds,
  });

  /*
   * FIXED BOUNDS. This is what makes a toggle safe.
   *
   * Chart.js scales an axis to the data it can see. Hiding a series would
   * therefore rescale the axis and move every line that stayed on screen. A
   * person revealing a second line would watch the first one jump, and the
   * lesson would look like a fault.
   *
   * The bounds come from ALL the data, hidden or not, so a toggle cannot move
   * anything.
   */
  const bounds = axisBounds(payload.series, axisIds, { normalize: state.normalize });
  const unitOf = (axis) => {
    const found = payload.series.find((_s, index) => axisIds[index] === axis);
    return found ? found.unit || "" : "";
  };
  const nameOf = (axis) => {
    const names = payload.series
      .filter((_s, index) => axisIds[index] === axis)
      .map((series) => series.name || series.metric);
    return names.join(" and ");
  };

  const scales = {
    x: {
      type: "linear",
      min: axisMillis.length ? axisMillis[0] : undefined,
      max: axisMillis.length ? axisMillis[axisMillis.length - 1] : undefined,
      ticks: { maxTicksLimit: 10, callback: (value) => formatWhen(value) },
      title: { display: true, text: "Time" },
    },
    y: {
      position: "left",
      min: state.normalize ? 0 : bounds.y ? bounds.y.min : undefined,
      max: state.normalize ? 1 : bounds.y ? bounds.y.max : undefined,
      title: {
        display: true,
        text: state.normalize ? "Scaled 0 to 1" : `${nameOf("y")} (${unitOf("y")})`,
      },
    },
  };

  const hasSecondAxis = axisIds.includes("y1");
  if (!state.normalize && hasSecondAxis) {
    scales.y1 = {
      position: "right",
      grid: { drawOnChartArea: false },
      min: bounds.y1 ? bounds.y1.min : undefined,
      max: bounds.y1 ? bounds.y1.max : undefined,
      title: { display: true, text: `${nameOf("y1")} (${unitOf("y1")})` },
    };
  }

  if (state.chart) state.chart.destroy();
  state.chart = new Chart(el("chart"), {
    type: "line",
    data: { datasets },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      animation: false,
      parsing: false,
      interaction: { mode: "nearest", intersect: false },
      scales,
      plugins: {
        tooltip: {
          callbacks: {
            title: (items) => {
              if (!items.length) return "";
              const item = items[0];
              const when =
                item.parsed && item.parsed.x !== undefined ? item.parsed.x : item.raw && item.raw.x;
              return when === undefined || when === null ? "" : formatWhen(when);
            },
          },
        },
        legend: { display: false },
      },
    },
  });
  state.chart.update("none");

  /*
   * Publish the chart configuration, so a gate can assert on what was drawn
   * instead of looking at it.
   */
  const config = datasets.map((set, index) => ({
    key: payload.series[index].key,
    name: payload.series[index].name,
    source: payload.series[index].source,
    isReal: set.mobilelab.isReal,
    dashed: set.mobilelab.dashed,
    stepped: set.stepped,
    colour: set.borderColor,
    axis: set.yAxisID,
    hidden: Boolean(set.hidden),
  }));
  document.body.dataset.chartConfig = JSON.stringify(config);

  /*
   * Measure the lines as DRAWN, at no further lag.
   *
   * The caption reports a correlation it computes from the payload. This reads
   * the shifted values that actually reached the canvas and correlates them
   * point against point. When the slider sits at the measured delay the two
   * numbers must agree, because the lines are then on top of each other. If the
   * shift ran the wrong way, this number stays weak while the caption claims
   * strong, and that disagreement is the fault made visible.
   */
  const drawnResponse = datasets[0].data.map((point) => point.y);
  datasets.forEach((set, index) => {
    if (index === 0) return;
    const drawn = set.data.map((point) => point.y);
    const { r } = pearson(
      drawn.map((v) => (v === null ? NaN : v)),
      drawnResponse.map((v) => (v === null ? NaN : v))
    );
    document.body.dataset[`${payload.series[index].key}AlignR`] = r.toFixed(3);
  });
  document.body.dataset.responseFingerprint = fingerprint(state.chart, 0);
  document.body.dataset.visible = payload.series
    .filter((series) => !state.hidden[series.key])
    .map((series) => series.key)
    .join(",");

  /*
   * The button takes the colour of its own line, from the chart itself. One
   * source of truth, so a colour change in the chart moves the button with it.
   */
  payload.series.forEach((series, index) => {
    const button = el(`toggle-${series.key}`);
    if (button) button.style.setProperty("--series-colour", datasets[index].borderColor);
  });
}

function renderToggles() {
  const { payload } = state;
  payload.series.forEach((series) => {
    const button = el(`toggle-${series.key}`);
    if (!button) return;
    const shown = !state.hidden[series.key];
    button.setAttribute("aria-pressed", shown ? "true" : "false");
  });
}

function renderAll() {
  renderBanner(state.payload);
  renderProvenance(state.payload);
  renderChart();
  renderCaption();
  renderToggles();
  document.body.dataset.status = "ready";
}

async function load() {
  document.body.dataset.status = "loading";
  try {
    const payload = await fetchMulti();
    state.payload = payload;
    state.drivers = measureDrivers(payload);
    state.estimate = state.drivers.length ? state.drivers[0].estimate : null;

    /*
     * Every series is visible when the page opens. Architecture aside, this is
     * the rehearsal requirement: the rig boots showing all three.
     */
    state.hidden = {};
    const show = params().show;
    if (show !== null && show !== undefined) {
      const wanted = new Set(show.split(",").filter(Boolean));
      payload.series.forEach((series) => {
        state.hidden[series.key] = !wanted.has(series.key);
      });
    }

    renderAll();

    const preset = new URLSearchParams(window.location.search).get("autoshift");
    if (preset !== null && Number.isFinite(Number(preset))) {
      el("lag").value = String(Number(preset));
      el("lag").dispatchEvent(new Event("input"));
    }
  } catch (error) {
    document.body.dataset.status = "error";
    document.body.dataset.error = String(error.message || error);
    el("caption-headline").textContent = "The chart could not get the data.";
    el("caption-detail").textContent = String(error.message || error);
    el("warning").textContent = "Check that mobilelab-api runs, and that data exists in this range.";
  }
}

function wire() {
  el("range").addEventListener("change", load);
  el("reload").addEventListener("click", load);

  document.querySelectorAll(".series-toggle").forEach((button) => {
    button.addEventListener("click", () => {
      const key = button.dataset.series;
      state.hidden[key] = !state.hidden[key];
      if (state.payload) {
        renderChart();
        renderToggles();
      }
    });
  });

  el("normalize").addEventListener("change", (event) => {
    state.normalize = event.target.checked;
    if (state.payload) {
      renderChart();
      document.body.dataset.normalized = String(state.normalize);
    }
  });

  el("lag").addEventListener("input", (event) => {
    state.shiftHours = Number(event.target.value);
    el("lag-value").textContent = `${state.shiftHours} h`;
    if (state.payload) {
      renderChart();
      renderCaption();
    }
  });

  const openModal = (id) => document.getElementById(id).classList.remove("modal-hidden");
  const closeModal = (id) => document.getElementById(id).classList.add("modal-hidden");
  el("detail-open").addEventListener("click", () => openModal("detail-panel"));
  el("detail-close").addEventListener("click", () => closeModal("detail-panel"));
  el("simulated-banner").addEventListener("click", () => openModal("sim-panel"));
  el("sim-close").addEventListener("click", () => closeModal("sim-panel"));

  el("use-estimate").addEventListener("click", () => {
    const best = state.drivers
      .filter((driver) => driver.estimate.usable)
      .sort((a, b) => Math.abs(b.estimate.r) - Math.abs(a.estimate.r))[0];
    if (!best) return;
    el("lag").value = String(Math.round(best.estimate.lagHours));
    el("lag").dispatchEvent(new Event("input"));
  });
}

async function fillStations() {
  const stations = await fetchStations();
  const select = el("station");
  select.innerHTML = "";
  if (!stations.length) {
    const option = document.createElement("option");
    option.value = "";
    option.textContent = "this station";
    select.appendChild(option);
    return;
  }
  stations.forEach((station) => {
    const option = document.createElement("option");
    option.value = station.station_id;
    option.textContent = station.label || station.station_id;
    select.appendChild(option);
  });
}

wire();
fillStations().then(load);
