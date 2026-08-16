"""The seeded cell-average rainfall fixture.

It stands in for the public record while the real figure does not exist yet.
Architecture section 6 puts the real lookup in V2, so this generator fills the
rehearsal rig and nothing else.

WHAT A CELL AVERAGE IS, AND WHY THIS SERIES LOOKS DIFFERENT.

A gridded product reports one number for a whole cell, several kilometres
across, for a whole bucket. Florida convection does not work at that scale. A
storm pours on one block and stays dry three streets over. Averaged across the
cell, that storm becomes a small rise, and the sharp peak disappears.

So this series is SMOOTH ON PURPOSE. It carries no spike.

IT MUST NOT REPRODUCE THE GAUGE SPIKE. That is not a limitation to work around.
The gap between this series and the local gauge IS the lesson. Section 6 states
the framing: the claim is never that the public record is wrong. The public
record is doing its job at its scale. Gridded data cannot see local convection,
and that is the opportunity.

HOW THE SHAPE IS BUILT.

Three slow waves, with periods far longer than a storm. A storm lasts two to
five hours. These waves turn over across one to four days. A slow wave cannot
line up with a short storm, so this series correlates WEAKLY with the salinity
that the storms drive, while the gauge correlates strongly. That difference is
structural, not a seed that happened to work.

The waves are clipped at zero to make dry spells, then smoothed, because the
clip leaves a corner and a cell average has no corners.

DETERMINISM. SHA-256, not the random module, exactly as mobilelab.fixture does.
The same seed and start always make the same series.

SAFETY. It reads public.sources before publishing and stops unless is_real is
false. A generator can never publish under the real public record source.
"""

from __future__ import annotations

import argparse
import json
import logging
import math
import sys
from datetime import UTC, datetime, timedelta

import paho.mqtt.client as mqtt

from .config import load_settings
from .db import Database, DatabaseUnavailable
from .fixture import (
    DEFAULT_HOURS,
    DEFAULT_SEED,
    DEFAULT_START,
    build_rainfall,
    build_salinity,
    check_source_is_not_real,
    expand_to_steps,
    parse_start,
    unit_float,
)

log = logging.getLogger("mobilelab.cellfixture")

CELL_VERSION = "1"
DEFAULT_SOURCE = "public_synthetic"

RAIN_SENSOR = "rain"
RAIN_METRIC = "rainfall"
RAIN_UNIT = "mm"

WAVE_PERIODS_HOURS = (41.0, 67.0, 97.0)
WAVE_MIN_AMPLITUDE = 0.15
WAVE_AMPLITUDE_SPAN = 0.35
DRY_OFFSET = 0.10
SMOOTH_HALF_WIDTH_HOURS = 3
CELL_CEILING_MM = 2.5

MAX_PLAUSIBLE_STEP_MM = 0.35


def build_cell_rainfall(seed: int, hours: int) -> list[float]:
    """Make an hourly cell-average rainfall series in millimetres.

    The result is smooth and it never spikes. A caller can assert that with
    largest_step.
    """
    phases = []
    amplitudes = []
    for index, _period in enumerate(WAVE_PERIODS_HOURS):
        phases.append(unit_float(seed, "cell_phase", index) * 2.0 * math.pi)
        amplitudes.append(
            WAVE_MIN_AMPLITUDE + unit_float(seed, "cell_amplitude", index) * WAVE_AMPLITUDE_SPAN
        )

    raw = []
    for hour in range(hours):
        total = 0.0
        for index, period in enumerate(WAVE_PERIODS_HOURS):
            total += amplitudes[index] * math.sin(2.0 * math.pi * hour / period + phases[index])
        raw.append(total + DRY_OFFSET)

    clipped = [value if value > 0.0 else 0.0 for value in raw]

    smoothed = []
    for hour in range(hours):
        low = max(0, hour - SMOOTH_HALF_WIDTH_HOURS)
        high = min(hours, hour + SMOOTH_HALF_WIDTH_HOURS + 1)
        window = clipped[low:high]
        smoothed.append(sum(window) / len(window))

    return [round(min(value, CELL_CEILING_MM), 3) for value in smoothed]


def largest_step(values: list[float]) -> float:
    """The biggest change between one hour and the next.

    A cell average must not jump. This is the number that proves it.
    """
    if len(values) < 2:
        return 0.0
    return max(abs(values[i] - values[i - 1]) for i in range(1, len(values)))


def pearson(xs: list[float], ys: list[float]) -> float:
    """Plain correlation, so the generator can report its own numbers."""
    pairs = [
        (x, y)
        for x, y in zip(xs, ys)
        if x is not None and y is not None and math.isfinite(x) and math.isfinite(y)
    ]
    if len(pairs) < 3:
        return 0.0
    n = len(pairs)
    mx = sum(p[0] for p in pairs) / n
    my = sum(p[1] for p in pairs) / n
    sxy = sum((p[0] - mx) * (p[1] - my) for p in pairs)
    sxx = sum((p[0] - mx) ** 2 for p in pairs)
    syy = sum((p[1] - my) ** 2 for p in pairs)
    if sxx <= 0 or syy <= 0:
        return 0.0
    return sxy / math.sqrt(sxx * syy)


def best_absolute_correlation(driver: list[float], response: list[float], max_lag: int) -> dict:
    """Sweep the lag and keep the strongest correlation.

    This matches the sweep the chart uses. Architecture section 7 locks the
    sweep and forbids comparing peaks, so the generator must report the same
    measure the screen reports. A weak claim measured a different way would not
    be a claim about the screen.
    """
    best = {"lag": 0, "r": 0.0}
    for lag in range(0, max_lag + 1):
        a = driver[: len(driver) - lag] if lag else driver[:]
        b = response[lag:] if lag else response[:]
        size = min(len(a), len(b))
        r = pearson(a[:size], b[:size])
        if abs(r) > abs(best["r"]):
            best = {"lag": lag, "r": r}
    return best


def build_series(
    seed: int,
    hours: int,
    start: datetime,
    station_id: str,
    source: str,
    interval_minutes: int = 60,
) -> dict:
    if 60 % interval_minutes != 0 or not 1 <= interval_minutes <= 60:
        raise SystemExit(
            "--interval-minutes must divide 60. Use 1, 2, 3, 4, 5, 6, 10, 12, 15, 20, 30, or 60."
        )
    steps_per_hour = 60 // interval_minutes

    hourly = build_cell_rainfall(seed, hours)
    cell = expand_to_steps(hourly, steps_per_hour)

    provenance = {
        "generator": "mobilelab.cellfixture",
        "version": CELL_VERSION,
        "seed": seed,
        "hours": hours,
        "interval_minutes": interval_minutes,
        "start": start.isoformat().replace("+00:00", "Z"),
        "wave_periods_hours": list(WAVE_PERIODS_HOURS),
        "represents": "a cell average across a grid cell, not a point measurement",
    }

    timestamps = [
        (start + timedelta(minutes=step * interval_minutes)).isoformat().replace("+00:00", "Z")
        for step in range(len(cell))
    ]

    return {
        "provenance": provenance,
        "station_id": station_id,
        "source": source,
        "timestamps": timestamps,
        "rainfall_mm": cell,
    }


def series_to_records(series: dict) -> list[dict]:
    records = []
    for index, stamp in enumerate(series["timestamps"]):
        records.append(
            {
                "station_id": series["station_id"],
                "ts": stamp,
                "source": series["source"],
                "provenance": series["provenance"],
                "sensor": RAIN_SENSOR,
                "metric": RAIN_METRIC,
                "value": series["rainfall_mm"][index],
                "unit": RAIN_UNIT,
            }
        )
    return records


def compare_with_gauge(seed: int, hours: int, lag_hours: int, cell: list[float]) -> dict:
    """Measure both rainfall series against the same salinity series.

    The claim this task makes is comparative: the gauge is strong and the cell
    average is weak. One number alone does not carry that claim, so both are
    measured here, the same way, against the same salinity.
    """
    gauge = build_rainfall(seed, hours)
    salinity = build_salinity(seed, gauge, lag_hours, 1)

    gauge_best = best_absolute_correlation(gauge, salinity, 24)
    cell_best = best_absolute_correlation(cell, salinity, 24)

    return {
        "gauge_r": round(gauge_best["r"], 3),
        "gauge_lag_hours": gauge_best["lag"],
        "cell_r": round(cell_best["r"], 3),
        "cell_lag_hours": cell_best["lag"],
        "gauge_peak_mm": round(max(gauge), 2),
        "cell_peak_mm": round(max(cell), 2),
        "cell_largest_hourly_step_mm": round(largest_step(cell), 3),
    }


def publish(series: dict, host: str, port: int) -> int:
    records = series_to_records(series)

    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id="mobilelab-cellfixture")
    client.connect(host, port, keepalive=30)
    client.loop_start()

    sent = 0
    for record in records:
        topic = f"station/{record['station_id']}/{record['sensor']}/{record['metric']}"
        info = client.publish(topic, json.dumps(record), qos=1)
        info.wait_for_publish(timeout=10)
        sent += 1

    client.loop_stop()
    client.disconnect()
    return sent


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m mobilelab.cellfixture",
        description="Publish a seeded cell-average rainfall series for the rehearsal rig.",
    )
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED)
    parser.add_argument("--hours", type=int, default=DEFAULT_HOURS)
    parser.add_argument("--lag-hours", type=int, default=6)
    parser.add_argument("--interval-minutes", type=int, default=60)
    parser.add_argument("--start", default=DEFAULT_START)
    parser.add_argument("--source", default=DEFAULT_SOURCE)
    parser.add_argument("--station-id", default=None)
    parser.add_argument("--dry-run", action="store_true", help="Build the series. Publish nothing.")
    parser.add_argument("--json", action="store_true", help="Print the series as JSON.")
    parser.add_argument(
        "--report",
        action="store_true",
        help="Print both correlations against salinity, and the smoothness check.",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
        stream=sys.stderr,
    )
    args = build_parser().parse_args(argv)
    settings = load_settings()
    station_id = args.station_id or settings.mobilelab_station_id

    series = build_series(
        seed=args.seed,
        hours=args.hours,
        start=parse_start(args.start),
        station_id=station_id,
        source=args.source,
        interval_minutes=args.interval_minutes,
    )

    hourly = build_cell_rainfall(args.seed, args.hours)
    comparison = compare_with_gauge(args.seed, args.hours, args.lag_hours, hourly)

    if args.json:
        print(json.dumps(series, indent=2, sort_keys=True))

    if args.report:
        print(json.dumps(comparison, indent=2, sort_keys=True))

    step = comparison["cell_largest_hourly_step_mm"]
    if step > MAX_PLAUSIBLE_STEP_MM:
        raise SystemExit(
            f"REFUSING TO PUBLISH: the cell average jumps {step} mm in one hour.\n"
            f"A cell average is smooth. Anything above {MAX_PLAUSIBLE_STEP_MM} mm is a spike,\n"
            f"and a spike would reproduce the local gauge instead of contrasting with it."
        )

    if args.dry_run:
        log.info("dry run, nothing was published")
        return 0

    database = Database(settings.dsn())
    try:
        check_source_is_not_real(database, args.source)
    except DatabaseUnavailable as exc:
        raise SystemExit(
            f"REFUSING TO PUBLISH: the database did not answer, so the source "
            f"check could not run.\n{exc}"
        ) from exc
    finally:
        database.close()

    sent = publish(series, settings.mobilelab_mqtt_host, settings.mobilelab_mqtt_port)

    log.info("published %d cell average records with source %r", sent, args.source)
    log.info(
        "the local gauge peaks at %.2f mm, the cell average peaks at %.2f mm",
        comparison["gauge_peak_mm"],
        comparison["cell_peak_mm"],
    )
    log.info(
        "against the same salinity: gauge r = %.3f at %d h, cell average r = %.3f at %d h",
        comparison["gauge_r"],
        comparison["gauge_lag_hours"],
        comparison["cell_r"],
        comparison["cell_lag_hours"],
    )
    log.info("the cell average never jumps more than %.3f mm in one hour", step)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
