/*
 * The overlay chart page.
 *
 * It reads the local API. It never reads the fixture and it never reads the
 * database. The chart therefore shows the same numbers the kiosk will show.
 *
 * The page writes its state onto the body as data attributes. A headless
 * browser can then read the result without a screenshot, which is how
 * ops/verify-chart.sh checks the rules.
 */

import {
  buildCaption,
  buildDatasets,
  buildShiftNote,
  classifyProvenance,
  correlationAtStep,
  estimateLag,
  needsSimulatedBanner,
  stepMillis,
} from "/static/chart-core.js";

const PAIR = {
  a: { sensor: "rain", metric: "rainfall", source: "synthetic", name: "rainfall" },
  b: { sensor: "water", metric: "salinity", source: "synthetic", name: "salinity" },
};

const state = {
  payload: null,
  chart: null,
  estimate: null,
  shiftHours: 0,
  normalize: false,
};

const el = (id) => document.getElementById(id);

function params() {
  const search = new URLSearchParams(window.location.search);
  return {
    hours: Number(search.get("hours") || el("range").value || 168),
    station: search.get("station_id") || el("station").value || "",
    source: search.get("source") || PAIR.a.source,
  };
}

async function fetchPair() {
  const chosen = params();
  const to = new Date();
  const from = new Date(to.getTime() - chosen.hours * 3600000);
  const query = new URLSearchParams({
    a_sensor: PAIR.a.sensor,
    a_metric: PAIR.a.metric,
    a_source: chosen.source,
    b_sensor: PAIR.b.sensor,
    b_metric: PAIR.b.metric,
    b_source: chosen.source,
    from: from.toISOString(),
    to: to.toISOString(),
  });
  if (chosen.station) query.set("station_id", chosen.station);

  const response = await fetch(`/api/series/pair?${query.toString()}`);
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
  const banner = el("simulated-banner");
  const simulated = needsSimulatedBanner(payload.series);
  const untrusted = payload.series.filter((s) => !classifyProvenance(s).trusted);

  banner.classList.toggle("banner-hidden", !simulated);
  document.body.dataset.simulated = simulated ? "true" : "false";
  document.body.dataset.untrusted = untrusted.length ? "true" : "false";

  if (untrusted.length) {
    el("banner-detail").textContent =
      "The station cannot confirm where these numbers come from. It therefore " +
      "treats them as not real. Do not use them as evidence.";
    el("warning").textContent =
      "A line has no usable provenance. The chart drew it as not real on purpose.";
  } else if (simulated) {
    el("banner-detail").textContent =
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
    const row = document.createElement("tr");
    row.innerHTML = `
      <td>${index === 0 ? "First" : "Second"}</td>
      <td>${series.sensor} ${series.metric}</td>
      <td>${verdict.source}</td>
      <td><span class="tag ${verdict.isReal ? "tag-real" : "tag-fake"}">${
        verdict.isReal ? "REAL" : "NOT REAL"
      }</span></td>
      <td>${verdict.dashed ? "dashed" : "solid"}</td>`;
    body.appendChild(row);
    document.body.dataset[index === 0 ? "aDashed" : "bDashed"] = String(verdict.dashed);
    document.body.dataset[index === 0 ? "aReal" : "bReal"] = String(verdict.isReal);
  });

  el("served-note").textContent =
    `The API answered from ${payload.served_from}. ` +
    `${payload.axis.length} time slots. ` +
    (payload.bucket ? `Each slot covers ${payload.bucket}.` : "Full detail, no grouping.");
  document.body.dataset.servedFrom = payload.served_from;
  document.body.dataset.points = String(payload.axis.length);
}

function renderCaption() {
  const { payload, estimate } = state;
  const caption = buildCaption(PAIR.a.name, PAIR.b.name, estimate);
  el("caption-headline").textContent = caption.headline;
  el("caption-detail").textContent = caption.detail;

  const step = stepMillis(payload.axis.map((s) => new Date(s).getTime()));
  const stepHours = step / 3600000;
  const shiftSteps = stepHours ? Math.round(state.shiftHours / stepHours) : 0;
  const a = payload.series[0].values.map(Number);
  const b = payload.series[1].values.map(Number);
  const at = shiftSteps >= 0 ? correlationAtStep(a, b, shiftSteps) : correlationAtStep(b, a, -shiftSteps);

  el("caption-shift").textContent = buildShiftNote(PAIR.b.name, state.shiftHours, at.r, at.samples);

  document.body.dataset.caption = `${caption.headline} ${caption.detail}`;
  document.body.dataset.captionShift = el("caption-shift").textContent;
  document.body.dataset.lagHours = estimate.usable ? estimate.lagHours.toFixed(2) : "none";
  document.body.dataset.lagR = estimate.usable ? estimate.r.toFixed(3) : "none";
  document.body.dataset.shiftHours = String(state.shiftHours);
}

function renderChart() {
  const { payload } = state;
  const step = stepMillis(payload.axis.map((s) => new Date(s).getTime()));
  const stepHours = step / 3600000;
  const shiftSteps = stepHours ? Math.round(state.shiftHours / stepHours) : 0;

  const { axisMillis, datasets } = buildDatasets(payload, {
    normalize: state.normalize,
    shiftSteps,
  });

  const unitA = payload.series[0].unit || "";
  const unitB = payload.series[1].unit || "";

  const scales = {
    x: {
      type: "linear",
      ticks: {
        maxTicksLimit: 10,
        callback: (value) => {
          const when = new Date(value);
          return `${String(when.getDate()).padStart(2, "0")} ${when.toLocaleString("en", {
            month: "short",
          })} ${String(when.getHours()).padStart(2, "0")}:00`;
        },
      },
      title: { display: true, text: "Time" },
    },
    y: {
      position: "left",
      title: { display: true, text: state.normalize ? "Scaled 0 to 1" : `${PAIR.a.name} (${unitA})` },
    },
  };
  if (!state.normalize) {
    scales.y1 = {
      position: "right",
      grid: { drawOnChartArea: false },
      title: { display: true, text: `${PAIR.b.name} (${unitB})` },
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
        legend: {
          labels: {
            generateLabels: (chart) =>
              chart.data.datasets.map((set, index) => ({
                text: set.mobilelab && !set.mobilelab.isReal ? `${set.label} - NOT REAL` : set.label,
                strokeStyle: set.borderColor,
                fillStyle: set.borderColor,
                lineDash: set.borderDash,
                datasetIndex: index,
              })),
          },
        },
      },
    },
  });
  void axisMillis;
}

function renderAll() {
  renderBanner(state.payload);
  renderProvenance(state.payload);
  renderChart();
  renderCaption();
  document.body.dataset.status = "ready";
}

async function load() {
  document.body.dataset.status = "loading";
  try {
    const payload = await fetchPair();
    state.payload = payload;

    const axisMillis = payload.axis.map((stamp) => new Date(stamp).getTime());
    state.estimate = estimateLag(
      axisMillis,
      payload.series[0].values.map(Number),
      payload.series[1].values.map(Number),
      24
    );
    renderAll();

    /*
     * autoshift presets the slider. A headless browser cannot drag, and
     * ops/verify-chart.sh has to prove the slider changes the caption. This
     * only sets a control a person could set by hand.
     */
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

  el("normalize").addEventListener("change", (event) => {
    state.normalize = event.target.checked;
    if (state.payload) {
      renderChart();
      document.body.dataset.normalized = String(state.normalize);
    }
  });

  el("lag").addEventListener("input", (event) => {
    state.shiftHours = Number(event.target.value);
    el("lag-value").textContent = `${state.shiftHours} hours`;
    if (state.payload) {
      renderChart();
      renderCaption();
    }
  });

  el("use-estimate").addEventListener("click", () => {
    if (!state.estimate || !state.estimate.usable) return;
    const hours = Math.round(state.estimate.lagHours);
    el("lag").value = String(hours);
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
