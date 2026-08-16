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
  /*
   * The public record, added with the cell average.
   *
   * A new hint must not become a hole in the rule. "stepped" is now valid, so
   * the control below must still come back REAL, and every near miss around it
   * must still come back NOT real.
   */
  {
    name: "CONTROL, a real public record with a stepped hint draws real",
    series: { ...base, source: "public_record", is_real: true, render_hint: "stepped" },
    wantReal: true,
    wantDashed: false,
  },
  {
    name: "a synthetic public record with a stepped hint is not real",
    series: { ...base, source: "public_synthetic", is_real: false, render_hint: "stepped" },
    wantReal: false,
    wantDashed: true,
  },
  {
    name: "public record, render_hint STEPPED in the wrong case",
    series: { ...base, source: "public_record", is_real: true, render_hint: "STEPPED" },
    wantReal: false,
    wantDashed: true,
  },
  {
    name: "public record, render_hint step, a near miss",
    series: { ...base, source: "public_record", is_real: true, render_hint: "step" },
    wantReal: false,
    wantDashed: true,
  },
  {
    name: "public record, render_hint stepped with a trailing space",
    series: { ...base, source: "public_record", is_real: true, render_hint: "stepped " },
    wantReal: false,
    wantDashed: true,
  },
  {
    name: "public record, render_hint null",
    series: { ...base, source: "public_record", is_real: true, render_hint: null },
    wantReal: false,
    wantDashed: true,
  },
  {
    name: "public record, is_real is the string true",
    series: { ...base, source: "public_record", is_real: "true", render_hint: "stepped" },
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

/* A stepped series must be marked stepped, and only when the hint says so. */
const steppedPayload = {
  axis: ["2026-08-15T00:00:00Z", "2026-08-15T01:00:00Z", "2026-08-15T02:00:00Z"],
  series: [
    { ...base, key: "s0", source: "manual", is_real: true, render_hint: "solid" },
    { ...base, key: "s1", sensor: "rain", metric: "rainfall", unit: "mm", source: "public_record", is_real: true, render_hint: "stepped" },
    { ...base, key: "s2", sensor: "rain", metric: "rainfall", unit: "mm", source: "public_record", is_real: true, render_hint: "STEPPED" },
  ],
};
const steppedBuilt = buildDatasets(steppedPayload, {});
check(
  "buildDatasets steps a cell average",
  steppedBuilt.datasets[1].stepped === "after",
  `stepped was ${JSON.stringify(steppedBuilt.datasets[1].stepped)}`
);
check(
  "buildDatasets does not step an ordinary series",
  steppedBuilt.datasets[0].stepped === false,
  `stepped was ${JSON.stringify(steppedBuilt.datasets[0].stepped)}`
);
check(
  "a malformed stepped hint is not stepped and not real",
  steppedBuilt.datasets[2].stepped === false && steppedBuilt.datasets[2].mobilelab.isReal === false,
  `stepped was ${JSON.stringify(steppedBuilt.datasets[2].stepped)}, isReal ${steppedBuilt.datasets[2].mobilelab.isReal}`
);
check(
  "two rainfall series in the same unit share one axis",
  steppedBuilt.axisIds[1] === steppedBuilt.axisIds[2],
  `axes were ${steppedBuilt.axisIds.join(",")}`
);

document.getElementById("results").textContent = lines.join("\n");
document.getElementById("summary").textContent =
  fail === 0
    ? `All ${pass} checks passed. The chart fails closed.`
    : `${fail} checks FAILED. The chart does not fail closed.`;
document.body.dataset.status = "done";
document.body.dataset.selftest = `SELFTEST_SUMMARY pass=${pass} fail=${fail}`;
