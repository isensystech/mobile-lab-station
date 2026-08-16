/*
 * The chart self test.
 *
 * It loads the SAME chart-core.js the live page loads, and feeds it series that
 * are broken in the ways a real fault would break them.
 *
 * The rule under test is architecture section 5. A series the chart cannot
 * confirm as real must draw dashed and must raise the SIMULATED banner. A
 * synthetic row that renders as real is a defect.
 *
 * One case is a control. A properly labelled real series MUST come back as
 * real. Without it, a function that always answered "not real" would pass.
 */

import { buildDatasets, classifyProvenance, needsSimulatedBanner } from "/static/chart-core.js";

const base = { sensor: "water", metric: "salinity", unit: "PSU", values: [1, 2, 3] };

const CASES = [
  {
    name: "CONTROL, a properly labelled real series draws solid",
    series: { ...base, source: "manual", is_real: true, render_hint: "solid" },
    wantReal: true,
    wantDashed: false,
  },
  {
    name: "a properly labelled synthetic series draws dashed",
    series: { ...base, source: "synthetic", is_real: false, render_hint: "dashed" },
    wantReal: false,
    wantDashed: true,
  },
  {
    name: "render_hint absent",
    series: { ...base, source: "synthetic", is_real: false },
    wantReal: false,
    wantDashed: true,
  },
  {
    name: "render_hint null",
    series: { ...base, source: "synthetic", is_real: false, render_hint: null },
    wantReal: false,
    wantDashed: true,
  },
  {
    name: "render_hint empty string",
    series: { ...base, source: "synthetic", is_real: false, render_hint: "" },
    wantReal: false,
    wantDashed: true,
  },
  {
    name: "render_hint wrong case, SOLID",
    series: { ...base, source: "synthetic", is_real: false, render_hint: "SOLID" },
    wantReal: false,
    wantDashed: true,
  },
  {
    name: "render_hint a number",
    series: { ...base, source: "synthetic", is_real: false, render_hint: 1 },
    wantReal: false,
    wantDashed: true,
  },
  {
    name: "THE DANGEROUS ONE, synthetic claims is_real true with a broken hint",
    series: { ...base, source: "synthetic", is_real: true, render_hint: "SOLID" },
    wantReal: false,
    wantDashed: true,
  },
  {
    name: "is_real absent, hint solid",
    series: { ...base, source: "synthetic", render_hint: "solid" },
    wantReal: false,
    wantDashed: true,
  },
  {
    name: "is_real is the string false",
    series: { ...base, source: "synthetic", is_real: "false", render_hint: "solid" },
    wantReal: false,
    wantDashed: true,
  },
  {
    name: "is_real is the string true",
    series: { ...base, source: "synthetic", is_real: "true", render_hint: "solid" },
    wantReal: false,
    wantDashed: true,
  },
  {
    name: "the whole series object is null",
    series: null,
    wantReal: false,
    wantDashed: true,
  },
];

const lines = [];
let pass = 0;
let fail = 0;

function check(name, ok, detail) {
  if (ok) {
    pass += 1;
    lines.push(`PASS: ${name}`);
  } else {
    fail += 1;
    lines.push(`FAIL: ${name} -- ${detail}`);
  }
}

for (const testCase of CASES) {
  const verdict = classifyProvenance(testCase.series);
  check(
    `${testCase.name} [isReal]`,
    verdict.isReal === testCase.wantReal,
    `wanted isReal=${testCase.wantReal} got ${verdict.isReal}`
  );
  check(
    `${testCase.name} [dashed]`,
    verdict.dashed === testCase.wantDashed,
    `wanted dashed=${testCase.wantDashed} got ${verdict.dashed}`
  );
}

/* The banner must rise whenever any series is not provably real. */
const bannerCases = [
  {
    name: "banner stays down when both series are properly real",
    series: [
      { ...base, source: "manual", is_real: true, render_hint: "solid" },
      { ...base, source: "gps", is_real: true, render_hint: "solid" },
    ],
    want: false,
  },
  {
    name: "banner rises when one series is synthetic",
    series: [
      { ...base, source: "manual", is_real: true, render_hint: "solid" },
      { ...base, source: "synthetic", is_real: false, render_hint: "dashed" },
    ],
    want: true,
  },
  {
    name: "banner rises when one series has a broken hint",
    series: [
      { ...base, source: "manual", is_real: true, render_hint: "solid" },
      { ...base, source: "synthetic", is_real: true, render_hint: "SOLID" },
    ],
    want: true,
  },
];

for (const testCase of bannerCases) {
  check(testCase.name, needsSimulatedBanner(testCase.series) === testCase.want, "banner wrong");
}

/* The real render path must put a dash pattern on an untrusted series. */
const payload = {
  axis: ["2026-08-15T00:00:00Z", "2026-08-15T01:00:00Z", "2026-08-15T02:00:00Z"],
  series: [
    { ...base, sensor: "rain", metric: "rainfall", unit: "mm", source: "manual", is_real: true, render_hint: "solid" },
    { ...base, source: "synthetic", is_real: true, render_hint: "MALFORMED" },
  ],
};
const built = buildDatasets(payload, {});
check(
  "buildDatasets draws a trusted real series solid",
  built.datasets[0].borderDash.length === 0,
  `borderDash was ${JSON.stringify(built.datasets[0].borderDash)}`
);
check(
  "buildDatasets draws an untrusted series dashed",
  built.datasets[1].borderDash.length > 0,
  `borderDash was ${JSON.stringify(built.datasets[1].borderDash)}`
);
check(
  "buildDatasets marks an untrusted series as not real",
  built.datasets[1].mobilelab.isReal === false,
  `isReal was ${built.datasets[1].mobilelab.isReal}`
);

document.getElementById("results").textContent = lines.join("\n");
document.getElementById("summary").textContent =
  fail === 0
    ? `All ${pass} checks passed. The chart fails closed.`
    : `${fail} checks FAILED. The chart does not fail closed.`;
document.body.dataset.status = "done";
document.body.dataset.selftest = `SELFTEST_SUMMARY pass=${pass} fail=${fail}`;
