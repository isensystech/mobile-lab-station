/*
 * The manual entry form.
 *
 * The common case is one person, standing at the screen, entering the rain
 * gauge three times a day. Everything here serves that case.
 *
 * After a save the form keeps the name and the site, clears the numbers, and
 * puts the cursor back on the first number. The person can enter the next
 * reading without touching anything else.
 *
 * The page writes its state onto the body as data attributes, so a headless
 * browser can read the result. ops/verify-entry.sh uses that.
 */

const el = (id) => document.getElementById(id);

const state = {
  metrics: [],
  clock: null,
  editing: null,
};

function localInputValue(date) {
  const pad = (n) => String(n).padStart(2, "0");
  return (
    `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}` +
    `T${pad(date.getHours())}:${pad(date.getMinutes())}`
  );
}

async function loadClock() {
  const response = await fetch("/api/clock");
  const clock = await response.json();
  state.clock = clock;

  const alarm = el("clock-alarm");
  alarm.classList.toggle("alarm-hidden", clock.ok);
  document.body.dataset.clockOk = String(clock.ok);

  if (!clock.ok) {
    el("clock-alarm-detail").textContent = clock.problems[0] || "";
    el("clock-panel-detail").textContent = clock.problems.join(" ");
    /*
     * HARD RULE 13. Do not guess a time. An empty box a person must fill is
     * safer than a wrong time a person may not read.
     */
    el("ts").value = "";
    el("ts").disabled = true;
    el("now-button").disabled = true;
    el("save").disabled = true;
    el("ts-note").textContent = "The station will not fill this in while the clock is wrong.";
    document.body.dataset.tsPrefilled = "false";
    document.body.dataset.saveEnabled = "false";
    return clock;
  }

  el("ts").disabled = false;
  el("now-button").disabled = false;
  el("save").disabled = false;
  if (!el("ts").value) el("ts").value = localInputValue(new Date());
  el("ts-note").textContent = "The station clock reads " + new Date(clock.now).toLocaleString() + ".";
  document.body.dataset.tsPrefilled = "true";
  document.body.dataset.saveEnabled = "true";
  return clock;
}

async function loadMetrics() {
  const response = await fetch("/api/metrics");
  state.metrics = await response.json();

  const list = el("metric-list");
  list.innerHTML = "";
  state.metrics.forEach((metric, index) => {
    const row = document.createElement("div");
    row.className = "metric-row";
    row.dataset.key = metric.key;
    row.innerHTML = `
      <div class="metric-name">
        ${metric.label}
        <span class="metric-hint">${metric.plausible_range}</span>
      </div>
      <div class="metric-value">
        <input type="number" class="value-input" inputmode="decimal"
               step="${metric.step}" placeholder="number"
               data-key="${metric.key}" ${index === 0 ? 'id="first-value"' : ""}>
      </div>
      <div class="metric-unit">
        <select class="unit-input" data-key="${metric.key}">
          ${metric.units.map((u) => `<option value="${u}">${u}</option>`).join("")}
        </select>
      </div>
      <p class="metric-warn" data-warn="${metric.key}"></p>`;
    list.appendChild(row);
  });

  list.querySelectorAll(".value-input").forEach((input) => {
    input.addEventListener("input", () => warnIfOutOfRange(input));
  });
  list.querySelectorAll(".unit-input").forEach((select) => {
    select.addEventListener("change", () => {
      const input = list.querySelector(`.value-input[data-key="${select.dataset.key}"]`);
      warnIfOutOfRange(input);
    });
  });
}

function canonicalise(metric, raw, unit) {
  if (unit === metric.canonical_unit) return raw;
  if (unit === "degF") return ((raw - 32) * 5) / 9;
  if (unit === "in") return raw * 25.4;
  if (unit === "uScm") return raw / 1000;
  if (unit === "ppt") return raw;
  return raw;
}

/*
 * Warn early, but never block. HARD RULE 1.
 *
 * The warning tells the person the number looks wrong before they save. The
 * Save button stays live. The station stores the value with a flag.
 */
function warnIfOutOfRange(input) {
  if (!input) return;
  const metric = state.metrics.find((m) => m.key === input.dataset.key);
  const warn = document.querySelector(`[data-warn="${input.dataset.key}"]`);
  const row = input.closest(".metric-row");
  if (!metric || !warn) return;

  if (input.value === "") {
    warn.textContent = "";
    row.classList.remove("flagged");
    return;
  }

  const unit = document.querySelector(`.unit-input[data-key="${metric.key}"]`).value;
  const canonical = canonicalise(metric, Number(input.value), unit);

  if (canonical < metric.low || canonical > metric.high) {
    warn.textContent =
      `Looks wrong. Usually ${metric.plausible_range}. It still saves, marked for review.`;
    row.classList.add("flagged");
  } else {
    warn.textContent = "";
    row.classList.remove("flagged");
  }
}

function collectEntries() {
  const entries = [];
  document.querySelectorAll(".value-input").forEach((input) => {
    if (input.value === "") return;
    const metric = state.metrics.find((m) => m.key === input.dataset.key);
    const unit = document.querySelector(`.unit-input[data-key="${metric.key}"]`).value;
    entries.push({
      sensor: metric.sensor,
      metric: metric.metric,
      value_raw: Number(input.value),
      unit_raw: unit,
    });
  });
  return entries;
}

function clearNumbers() {
  document.querySelectorAll(".value-input").forEach((input) => {
    input.value = "";
    input.closest(".metric-row").classList.remove("flagged");
  });
  document.querySelectorAll(".metric-warn").forEach((warn) => {
    warn.textContent = "";
  });
  el("note").value = "";
}

function describeFlag(reading) {
  return reading.quality_flag === "implausible"
    ? '<span class="tag-flag">FLAGGED, CHECK THIS</span>'
    : "";
}

function renderRecent(batches) {
  const holder = el("recent");
  holder.innerHTML = "";
  document.body.dataset.recentBatches = String(batches.length);

  if (!batches.length) {
    holder.innerHTML = '<p class="muted">Nothing entered yet.</p>';
    return;
  }

  batches.forEach((batch) => {
    const card = document.createElement("div");
    card.className = "batch";
    const when = new Date(batch.ts).toLocaleString();
    const typed = new Date(batch.entered_at).toLocaleString();
    card.innerHTML = `
      <div class="batch-head">
        <span class="batch-when">${when}</span>
        <span class="batch-who">${batch.observer || "no name"} at ${batch.site_label || "no site"}</span>
        <span class="batch-who">typed ${typed}</span>
      </div>
      ${batch.note ? `<p class="batch-note">${batch.note}</p>` : ""}
      <table>
        <thead><tr><th>Measurement</th><th>You typed</th><th>Stored as</th><th></th><th></th></tr></thead>
        <tbody>
        ${batch.readings
          .map(
            (r) => `
          <tr data-reading="${r.reading_id}" class="${r.quality_flag === "implausible" ? "flagged" : ""}">
            <td>${r.sensor} ${r.metric}</td>
            <td>${r.value_raw ?? ""} ${r.unit_raw ?? ""}</td>
            <td>${r.value ?? ""} ${r.unit ?? ""}</td>
            <td>${describeFlag(r)}</td>
            <td><button type="button" class="btn btn-secondary reading-fix"
                        data-reading="${r.reading_id}">Fix</button></td>
          </tr>`
          )
          .join("")}
        </tbody>
      </table>`;
    holder.appendChild(card);
  });

  holder.querySelectorAll(".reading-fix").forEach((button) => {
    button.addEventListener("click", () => openCorrection(Number(button.dataset.reading), batches));
  });

  const flagged = batches.reduce(
    (total, b) => total + b.readings.filter((r) => r.quality_flag === "implausible").length,
    0
  );
  document.body.dataset.flaggedVisible = String(flagged);
}

async function loadRecent() {
  const response = await fetch("/api/observations/recent?limit=5");
  renderRecent(await response.json());
}

function openCorrection(readingId, batches) {
  let found = null;
  batches.forEach((b) =>
    b.readings.forEach((r) => {
      if (r.reading_id === readingId) found = r;
    })
  );
  if (!found) return;

  state.editing = found;
  const metric = state.metrics.find((m) => m.key === `${found.sensor}/${found.metric}`);
  el("correct-what").textContent =
    `${found.sensor} ${found.metric}, entered as ${found.value_raw} ${found.unit_raw}.`;
  el("correct-value").value = found.value_raw ?? "";
  el("correct-unit").innerHTML = (metric ? metric.units : [found.unit_raw])
    .map((u) => `<option value="${u}" ${u === found.unit_raw ? "selected" : ""}>${u}</option>`)
    .join("");
  el("correct-result").textContent = "";
  el("correct-panel").classList.remove("modal-hidden");
}

function closeCorrection() {
  el("correct-panel").classList.add("modal-hidden");
  state.editing = null;
}

async function saveCorrection() {
  if (!state.editing) return;
  const response = await fetch(`/api/readings/${state.editing.reading_id}`, {
    method: "PATCH",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      value_raw: Number(el("correct-value").value),
      unit_raw: el("correct-unit").value,
    }),
  });
  const result = await response.json();
  if (!response.ok) {
    el("correct-result").textContent = result.detail || "The fix did not save.";
    return;
  }
  el("correct-result").textContent = "Saved. The charts were updated too.";
  closeCorrection();
  await loadRecent();
}

async function deleteReading() {
  if (!state.editing) return;
  const response = await fetch(`/api/readings/${state.editing.reading_id}`, { method: "DELETE" });
  const result = await response.json();
  if (!response.ok) {
    el("correct-result").textContent = result.detail || "The reading did not go away.";
    return;
  }
  closeCorrection();
  await loadRecent();
}

async function save(event) {
  event.preventDefault();
  const result = el("save-result");
  const entries = collectEntries();

  if (!entries.length) {
    result.className = "save-result save-bad";
    result.textContent = "Type at least one number first.";
    return;
  }
  if (!el("ts").value) {
    result.className = "save-result save-bad";
    result.textContent = "Fill in the date and time of the reading.";
    return;
  }

  el("save").disabled = true;
  result.className = "save-result";
  result.textContent = "Saving...";

  const body = {
    ts: new Date(el("ts").value).toISOString(),
    observer: el("observer").value || null,
    site_label: el("site").value || null,
    note: el("note").value || null,
    entries,
  };

  try {
    const response = await fetch("/api/observations", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    const saved = await response.json();

    if (!response.ok) {
      result.className = "save-result save-bad";
      const detail = saved.detail;
      result.textContent =
        typeof detail === "string" ? detail : (detail && detail.advice) || "The reading did not save.";
      document.body.dataset.lastSave = "error";
      await loadClock();
      return;
    }

    const flagged = saved.readings.filter((r) => r.quality_flag === "implausible").length;
    result.className = flagged ? "save-result save-bad" : "save-result save-ok";
    result.textContent = flagged
      ? `Saved ${saved.stored_readings} readings. ${flagged} looks wrong and is marked for review.`
      : `Saved ${saved.stored_readings} readings.`;

    document.body.dataset.lastSave = "ok";
    document.body.dataset.lastObservation = saved.observation_id;
    document.body.dataset.lastFlagged = String(flagged);

    /* Repeat entry is the common case. Keep who and where. Clear the numbers. */
    clearNumbers();
    el("ts").value = localInputValue(new Date());
    await loadRecent();
    showTab("enter");
    const first = el("first-value");
    if (first) first.focus();
  } catch (error) {
    result.className = "save-result save-bad";
    result.textContent = String(error.message || error);
    document.body.dataset.lastSave = "error";
  } finally {
    el("save").disabled = state.clock ? !state.clock.ok : false;
  }
}

function showTab(which) {
  const enter = which === "enter";
  el("tab-enter").setAttribute("aria-selected", String(enter));
  el("tab-recent").setAttribute("aria-selected", String(!enter));
  el("panel-enter").hidden = !enter;
  el("panel-recent").hidden = enter;
  document.body.dataset.tab = which;
}

function showWho() {
  const who = el("observer").value.trim();
  const where = el("site").value.trim();
  el("who-now").textContent = who || where ? `${who || "no name"} at ${where || "no site"}` : "";
}

const openModal = (id) => document.getElementById(id).classList.remove("modal-hidden");
const closeModal = (id) => document.getElementById(id).classList.add("modal-hidden");

function wire() {
  el("entry-form").addEventListener("submit", save);

  el("tab-enter").addEventListener("click", () => showTab("enter"));
  el("tab-recent").addEventListener("click", () => showTab("recent"));

  el("who-open").addEventListener("click", () => openModal("who-panel"));
  el("who-close").addEventListener("click", () => { showWho(); closeModal("who-panel"); });
  el("note-open").addEventListener("click", () => openModal("note-panel"));
  el("note-close").addEventListener("click", () => closeModal("note-panel"));
  el("clock-more").addEventListener("click", () => openModal("clock-panel"));
  el("clock-close").addEventListener("click", () => closeModal("clock-panel"));
  el("observer").addEventListener("input", showWho);
  el("site").addEventListener("input", showWho);
  el("clear").addEventListener("click", clearNumbers);
  el("now-button").addEventListener("click", () => {
    el("ts").value = localInputValue(new Date());
  });
  el("correct-cancel").addEventListener("click", closeCorrection);
  el("correct-save").addEventListener("click", saveCorrection);
  el("correct-delete").addEventListener("click", deleteReading);
}

async function start() {
  wire();
  showTab("enter");
  await loadMetrics();
  await loadClock();
  await loadRecent();
  showWho();
  document.body.dataset.status = "ready";
}

start();
