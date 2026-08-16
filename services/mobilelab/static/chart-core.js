/*
 * The chart logic, with no page and no network in it.
 *
 * The live page and the self test page both load this file. A test therefore
 * runs the same code the demo screen runs. A test of a copy proves nothing.
 */

/*
 * The hints a series may carry.
 *
 * "stepped" arrived with the public record. A cell average is one number for a
 * whole grid cell across a whole bucket, so it draws flat across the bucket. A
 * sloping line would claim the value moved smoothly between two readings, and
 * a cell average makes no such claim.
 *
 * Adding a hint does NOT loosen the fail closed rule. Anything outside this set
 * is still unknown provenance, and unknown still means not real.
 */
const VALID_HINTS = new Set(["solid", "dashed", "stepped"]);

export const STRONG = 0.7;
export const MODERATE = 0.4;

/*
 * Decide whether a series may be drawn as real.
 *
 * THIS FUNCTION FAILS CLOSED. Architecture section 5 is a locked rule, and the
 * failure it guards against is fake data that looks real.
 *
 * A series is drawn as real ONLY when the API states so in the exact shape we
 * expect: is_real is a true boolean, and render_hint is one of "solid",
 * "dashed", or "stepped". Anything else, including a missing field, a null, a
 * number, or the string "SOLID" in the wrong case, means we do not know.
 * Unknown provenance is treated as NOT real and draws dashed with the banner up.
 */
export function classifyProvenance(series) {
  const source = series && series.source ? String(series.source) : "unknown";
  const hint = series ? series.render_hint : undefined;
  const isRealRaw = series ? series.is_real : undefined;

  const hintValid = typeof hint === "string" && VALID_HINTS.has(hint);
  const isRealValid = typeof isRealRaw === "boolean";
  const trusted = hintValid && isRealValid;

  if (!trusted) {
    return {
      source,
      trusted: false,
      isReal: false,
      dashed: true,
      stepped: false,
      reason: "The provenance is missing or malformed. This is treated as not real.",
    };
  }

  return {
    source,
    trusted: true,
    isReal: isRealRaw === true,
    dashed: hint === "dashed" || isRealRaw !== true,
    stepped: hint === "stepped",
    reason: isRealRaw === true ? "The API states this is real." : "The API states this is not real.",
  };
}

/* The banner shows when ANY series is not provably real. */
export function needsSimulatedBanner(seriesList) {
  return (seriesList || []).some((series) => !classifyProvenance(series).isReal);
}

export function pearson(xs, ys) {
  const pairs = [];
  for (let i = 0; i < Math.min(xs.length, ys.length); i += 1) {
    if (Number.isFinite(xs[i]) && Number.isFinite(ys[i])) pairs.push([xs[i], ys[i]]);
  }
  if (pairs.length < 3) return { r: 0, samples: pairs.length };

  const n = pairs.length;
  const mx = pairs.reduce((sum, p) => sum + p[0], 0) / n;
  const my = pairs.reduce((sum, p) => sum + p[1], 0) / n;
  let sxy = 0;
  let sxx = 0;
  let syy = 0;
  for (const [x, y] of pairs) {
    sxy += (x - mx) * (y - my);
    sxx += (x - mx) ** 2;
    syy += (y - my) ** 2;
  }
  if (sxx <= 0 || syy <= 0) return { r: 0, samples: n };
  return { r: sxy / Math.sqrt(sxx * syy), samples: n };
}

/* The spacing between axis points, in milliseconds. The median resists a gap. */
export function stepMillis(axisMillis) {
  if (!axisMillis || axisMillis.length < 2) return 0;
  const gaps = [];
  for (let i = 1; i < axisMillis.length; i += 1) gaps.push(axisMillis[i] - axisMillis[i - 1]);
  gaps.sort((a, b) => a - b);
  return gaps[Math.floor(gaps.length / 2)];
}

/* Correlate a against b shifted by whole steps. */
export function correlationAtStep(aValues, bValues, step) {
  const a = [];
  const b = [];
  for (let i = 0; i + step < bValues.length && i < aValues.length; i += 1) {
    a.push(aValues[i]);
    b.push(bValues[i + step]);
  }
  return pearson(a, b);
}

/*
 * Estimate the lag by sweeping for the strongest correlation.
 *
 * DO NOT compare peaks. Peak to peak reports about 7 hours on the seeded
 * fixture where the mechanism uses 6, because rain keeps falling after its own
 * peak and the water keeps getting fresher.
 *
 * The result is an estimate, so the caption says "about".
 */
export function estimateLag(axisMillis, aValues, bValues, maxLagHours = 24) {
  const step = stepMillis(axisMillis);
  if (!step) return { lagHours: 0, r: 0, samples: 0, stepMinutes: 0, usable: false, curve: [] };

  const maxStep = Math.max(1, Math.floor((maxLagHours * 3600000) / step));
  const curve = [];
  let best = { step: 0, r: 0, samples: 0 };

  for (let k = 0; k <= maxStep; k += 1) {
    const { r, samples } = correlationAtStep(aValues, bValues, k);
    curve.push({ step: k, hours: (k * step) / 3600000, r, samples });
    if (samples >= 3 && Math.abs(r) > Math.abs(best.r)) best = { step: k, r, samples };
  }

  /* Fit a parabola through the peak and its neighbours for a sub step estimate. */
  let refined = best.step;
  const left = curve[best.step - 1];
  const right = curve[best.step + 1];
  if (left && right) {
    const y0 = Math.abs(left.r);
    const y1 = Math.abs(best.r);
    const y2 = Math.abs(right.r);
    const denominator = y0 - 2 * y1 + y2;
    if (denominator !== 0) {
      const adjust = (0.5 * (y0 - y2)) / denominator;
      if (Math.abs(adjust) <= 1) refined = best.step + adjust;
    }
  }

  return {
    lagHours: (refined * step) / 3600000,
    lagSteps: best.step,
    r: best.r,
    samples: best.samples,
    stepMinutes: step / 60000,
    usable: best.samples >= 3 && Math.abs(best.r) > 0,
    curve,
  };
}

export function strengthWord(r) {
  const magnitude = Math.abs(r);
  if (magnitude >= STRONG) return "strong";
  if (magnitude >= MODERATE) return "moderate";
  return "weak";
}

/*
 * Round the delay for a student to read.
 *
 * A delay of an hour or more reads as whole hours. "About 6 hours" is what a
 * person says. A short delay keeps a half hour step, because rounding 0.4 to
 * zero would hide a real delay.
 */
function roundForReading(value) {
  if (value < 1.5) return Math.round(value * 2) / 2;
  return Math.round(value);
}

/*
 * Write the caption a student reads.
 *
 * Short sentences. Active voice. No jargon in the first sentence.
 */
export function buildCaption(aName, bName, estimate) {
  if (!estimate.usable) {
    return {
      headline: "There is not enough data to compare these two measurements.",
      detail: "Collect more readings, then look again.",
    };
  }

  const direction = estimate.r < 0 ? "falls" : "rises";
  const strength = strengthWord(estimate.r);
  const hours = roundForReading(estimate.lagHours);
  const hourWord = hours === 1 ? "hour" : "hours";

  let timing;
  if (hours <= 0.25) {
    timing = "at the same time";
  } else {
    timing = `about ${hours} ${hourWord} later`;
  }

  return {
    headline: `When ${aName} rises, ${bName} ${direction} ${timing}.`,
    detail: `The relationship is ${strength}. r = ${estimate.r.toFixed(2)}.`,
  };
}

/* Describe the shift the person chose with the slider. */
export function buildShiftNote(bName, shiftHours, r, samples) {
  if (samples < 3) {
    return `You moved ${bName} by ${shiftHours} hours. There are too few matching points to measure.`;
  }
  const hourWord = Math.abs(shiftHours) === 1 ? "hour" : "hours";
  const where = shiftHours === 0 ? "no shift" : `a shift of ${shiftHours} ${hourWord}`;
  return `You are looking at ${where}. At this shift the relationship is ${strengthWord(r)}. r = ${r.toFixed(2)}.`;
}

/* Scale a series to run from 0 to 1, so two different units share one axis. */
export function normalize(values) {
  const present = values.filter((value) => Number.isFinite(value));
  if (present.length === 0) return values.slice();
  const low = Math.min(...present);
  const high = Math.max(...present);
  if (high === low) return values.map((value) => (Number.isFinite(value) ? 0.5 : null));
  return values.map((value) => (Number.isFinite(value) ? (value - low) / (high - low) : null));
}

/*
 * Move a series along the time axis by whole steps.
 *
 * A POSITIVE shift moves the series LATER, to the right.
 *
 * This has to agree with correlationAtStep, which reads a positive step as
 * "the response follows the driver by this many steps". So a measured delay of
 * six hours means the salinity dip arrives six hours after the rain, and
 * lining them up means carrying the rain forward onto the dip.
 *
 * It used to read values[i + steps], which carried the rain BACKWARD instead.
 * Pressing "Measured delay" then set +6 and moved the lines further apart, so
 * the chart contradicted its own caption.
 */
export function shiftValues(values, steps) {
  if (!steps) return values.slice();
  const out = new Array(values.length).fill(null);
  for (let i = 0; i < values.length; i += 1) {
    const from = i - steps;
    if (from >= 0 && from < values.length) out[i] = values[from];
  }
  return out;
}

/*
 * Give every series an axis, chosen by its unit.
 *
 * Two rainfall series share one axis because they are both millimetres.
 * Comparing them on two different scales would be a lie, and the whole point of
 * the comparison lane is that the two numbers are directly comparable.
 *
 * A third unit would get no axis of its own. That is a deliberate limit: the
 * screen is 1024 by 600 and a third axis leaves no room for the chart.
 */
export function assignAxes(seriesList) {
  const units = [];
  return (seriesList || []).map((series) => {
    const unit = series.unit || "";
    let position = units.indexOf(unit);
    if (position === -1) {
      units.push(unit);
      position = units.length - 1;
    }
    return position === 0 ? "y" : "y1";
  });
}

/*
 * Work out the fixed bounds for each axis, across EVERY series.
 *
 * This is what makes a toggle safe. Chart.js scales an axis to the data it can
 * see, so hiding one series would rescale the axis and MOVE the lines that
 * stayed. The salinity line would shift under the person's hand while they
 * revealed another series, and the lesson would look like a bug.
 *
 * The bounds are computed once from all the data, hidden or not, so hiding a
 * series cannot change where any other series is drawn.
 */
export function axisBounds(seriesList, axisIds, options) {
  const settings = options || {};
  const bounds = {};
  (seriesList || []).forEach((series, index) => {
    const axis = axisIds[index];
    const values = settings.normalize
      ? normalize(series.values.map((value) => (value === null ? null : Number(value))))
      : series.values.map((value) => (value === null ? null : Number(value)));
    for (const value of values) {
      if (!Number.isFinite(value)) continue;
      if (!bounds[axis]) bounds[axis] = { min: value, max: value };
      if (value < bounds[axis].min) bounds[axis].min = value;
      if (value > bounds[axis].max) bounds[axis].max = value;
    }
  });

  for (const axis of Object.keys(bounds)) {
    const span = bounds[axis].max - bounds[axis].min;
    const pad = span > 0 ? span * 0.05 : 1;
    /*
     * Padding never takes the axis below zero when the data never goes below
     * zero. Rainfall cannot be negative, and an axis that offers a reading of
     * minus 0.2 mm teaches the wrong thing on a screen built to teach.
     */
    const floor = bounds[axis].min >= 0 ? 0 : bounds[axis].min - pad;
    bounds[axis] = { min: Math.max(floor, bounds[axis].min - pad), max: bounds[axis].max + pad };
  }
  return bounds;
}

/*
 * Build the Chart.js datasets.
 *
 * The dash pattern comes from classifyProvenance, never straight from the
 * payload. That keeps one decision in one place.
 */
export function buildDatasets(payload, options) {
  const settings = options || {};
  const axisMillis = payload.axis.map((stamp) => new Date(stamp).getTime());
  /*
 * These colours now fill a button as well as draw a line, so each one must
 * carry white text. Measured against white: #08828c 4.6 to 1, #b3521d 5.1 to 1,
 * #6b3fa0 7.4 to 1. The orange was #d1622b, which reached only 3.8 to 1.
 */
  const colours = ["#08828c", "#b3521d", "#6b3fa0", "#7a5f14"];
  const axisIds = settings.axisIds || assignAxes(payload.series);
  const shiftKeys = settings.shiftKeys || [1];
  const hidden = settings.hidden || {};

  const datasets = payload.series.map((series, index) => {
    const verdict = classifyProvenance(series);
    let values = series.values.map((value) => (value === null ? null : Number(value)));

    if (settings.shiftSteps && shiftKeys.includes(index)) {
      values = shiftValues(values, settings.shiftSteps);
    }
    if (settings.normalize) values = normalize(values);

    const name = series.name || `${series.sensor} ${series.metric}`;

    return {
      label: `${name} (${series.unit || "no unit"})`,
      data: axisMillis.map((time, i) => ({ x: time, y: values[i] ?? null })),
      borderColor: colours[index % colours.length],
      backgroundColor: colours[index % colours.length],
      borderDash: verdict.dashed ? [6, 4] : [],
      borderWidth: 2,
      pointRadius: 0,
      spanGaps: true,
      /*
       * A cell average holds its value for the whole bucket, so it steps at the
       * start of the bucket and stays flat until the next one.
       */
      stepped: verdict.stepped ? "after" : false,
      hidden: Boolean(hidden[series.key || index]),
      yAxisID: settings.normalize ? "y" : axisIds[index],
      mobilelab: verdict,
    };
  });

  return { axisMillis, datasets, axisIds };
}
