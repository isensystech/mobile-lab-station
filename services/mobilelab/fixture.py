"""The seeded synthetic fixture.

It makes a rainfall series and a salinity series. Rain falls. Fresh water then
reaches the water body, and the salinity goes down. The drop follows the rain by
a known number of hours.

That lag is the point. Architecture section 7 says a zero lag view teaches a
student nothing, because the correlations they will find are lagged. This
fixture gives the correlation user interface a known answer to find, before any
real sensor exists.

DETERMINISM. The generator uses SHA-256, not the random module. The same seed
and the same start time always make the same series, on any machine and any
Python version.

SAFETY. The fixture reads public.sources before it publishes. It stops if the
source is unknown, and it stops if the source has is_real true. Synthetic data
cannot go out under a real source name.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import logging
import math
import sys
from datetime import UTC, datetime, timedelta

import paho.mqtt.client as mqtt

from .config import load_settings
from .db import Database, DatabaseUnavailable

log = logging.getLogger("mobilelab.fixture")

FIXTURE_VERSION = "1"
DEFAULT_SEED = 1337
DEFAULT_HOURS = 48
DEFAULT_LAG_HOURS = 6
DEFAULT_SOURCE = "synthetic"
DEFAULT_START = "2026-08-01T00:00:00Z"

SALINITY_BASE_PSU = 25.0
SALINITY_FLOOR_PSU = 0.5
FRESHENING_GAIN = 0.30

# The washout constant. It sets how long fresh water keeps arriving after the
# rain that carried it.
#
# CHANGED from 3.0 to 1.5 on 2026-08-15. Report this to Scott.
#
# The fixture exists to give the correlation user interface a known answer to
# find. At 3.0 the answer was not findable. The response smeared so far past the
# delay that a cross correlation sweep returned 7 hours, not the 6 hours the
# generator was told to use. Peak to peak also returned 7. Both estimators
# agreed, and both were wrong about the mechanism.
#
# Measured over 48, 168, and 336 hour series:
#
#   tau = 3.0   sweep says 7 h   every duration
#   tau = 2.0   sweep says 6 or 7 h, it changes with duration
#   tau = 1.5   sweep says 6 h   every duration, r = -0.86
#
# At 1.5 the sweep recovers the mechanism and peak to peak still reports 7.
# That difference is the teaching point, so the fixture now shows it.
FRESHENING_TAU_HOURS = 1.5
FRESHENING_WINDOW_HOURS = 14
NOISE_SPAN_PSU = 0.30

RAIN_SENSOR = "rain"
RAIN_METRIC = "rainfall"
RAIN_UNIT = "mm"
SALINITY_SENSOR = "water"
SALINITY_METRIC = "salinity"
SALINITY_UNIT = "PSU"


def unit_float(seed: int, channel: str, index: int) -> float:
    """Return a repeatable float in [0, 1) for this seed, channel, and index."""
    digest = hashlib.sha256(f"{seed}:{channel}:{index}".encode("utf-8")).digest()
    return int.from_bytes(digest[:8], "big") / float(1 << 64)


def build_rainfall(seed: int, hours: int) -> list[float]:
    """Make an hourly rainfall series in millimetres.

    Most hours are dry. Two or three storms arrive. Each storm rises to a peak
    and then stops.
    """
    rain = [0.0] * hours
    storm_count = 2 + int(unit_float(seed, "storm_count", 0) * 2)

    for k in range(storm_count):
        span = max(hours - 16, 1)
        onset = 4 + int(unit_float(seed, "onset", k) * span)
        duration = 2 + int(unit_float(seed, "duration", k) * 3)
        peak_mm = 4.0 + unit_float(seed, "peak", k) * 10.0

        for step in range(duration):
            hour = onset + step
            if hour >= hours:
                break
            shape = 1.0 - abs((step - (duration - 1) / 2.0) / ((duration + 1) / 2.0))
            rain[hour] += peak_mm * max(shape, 0.0)

    return [round(value, 2) for value in rain]


def expand_to_steps(hourly: list[float], steps_per_hour: int) -> list[float]:
    """Hold each hourly value across the steps inside that hour."""
    if steps_per_hour == 1:
        return list(hourly)
    fine: list[float] = []
    for value in hourly:
        fine.extend([value] * steps_per_hour)
    return fine


def build_salinity(
    seed: int, rain: list[float], lag_hours: int, steps_per_hour: int = 1
) -> list[float]:
    """Make a salinity series in PSU, at the same rate as the rain series.

    Fresh water reaches the water body lag_hours after the rain. The salinity
    then falls, and it recovers as the fresh water leaves.

    The freshening sum is divided by steps_per_hour. Without that, a finer
    sample rate would add more terms to the same sum and deepen every dip.
    """
    steps = len(rain)
    lag_steps = lag_hours * steps_per_hour
    tau_steps = FRESHENING_TAU_HOURS * steps_per_hour
    window_steps = FRESHENING_WINDOW_HOURS * steps_per_hour
    salinity = []

    for step in range(steps):
        freshening = 0.0
        for back in range(window_steps):
            source_step = step - lag_steps - back
            if source_step < 0:
                break
            freshening += rain[source_step] * math.exp(-back / tau_steps)
        freshening /= steps_per_hour

        noise = (unit_float(seed, "noise", step) - 0.5) * NOISE_SPAN_PSU
        value = SALINITY_BASE_PSU - FRESHENING_GAIN * freshening + noise
        salinity.append(round(max(value, SALINITY_FLOOR_PSU), 2))

    return salinity


def build_series(
    seed: int,
    hours: int,
    lag_hours: int,
    start: datetime,
    station_id: str,
    source: str,
    interval_minutes: int = 60,
) -> dict:
    """Build the whole fixture. The result is a plain dictionary, so a caller
    can print it as JSON and compare two runs byte for byte."""
    if 60 % interval_minutes != 0 or not 1 <= interval_minutes <= 60:
        raise SystemExit(
            "--interval-minutes must divide 60. Use 1, 2, 3, 4, 5, 6, 10, 12, 15, 20, 30, or 60."
        )
    steps_per_hour = 60 // interval_minutes

    hourly_rain = build_rainfall(seed, hours)
    rain = expand_to_steps(hourly_rain, steps_per_hour)
    salinity = build_salinity(seed, rain, lag_hours, steps_per_hour)

    provenance = {
        "generator": "mobilelab.fixture",
        "version": FIXTURE_VERSION,
        "seed": seed,
        "lag_hours": lag_hours,
        "hours": hours,
        "interval_minutes": interval_minutes,
        "start": start.isoformat().replace("+00:00", "Z"),
    }

    timestamps = [
        (start + timedelta(minutes=step * interval_minutes)).isoformat().replace("+00:00", "Z")
        for step in range(len(rain))
    ]

    return {
        "provenance": provenance,
        "station_id": station_id,
        "source": source,
        "timestamps": timestamps,
        "rainfall_mm": rain,
        "salinity_psu": salinity,
    }


def series_to_records(series: dict) -> list[dict]:
    """Turn the series into the common record shape, one record per point."""
    records = []
    for index, stamp in enumerate(series["timestamps"]):
        common = {
            "station_id": series["station_id"],
            "ts": stamp,
            "source": series["source"],
            "provenance": series["provenance"],
        }
        records.append(
            {
                **common,
                "sensor": RAIN_SENSOR,
                "metric": RAIN_METRIC,
                "value": series["rainfall_mm"][index],
                "unit": RAIN_UNIT,
            }
        )
        records.append(
            {
                **common,
                "sensor": SALINITY_SENSOR,
                "metric": SALINITY_METRIC,
                "value": series["salinity_psu"][index],
                "unit": SALINITY_UNIT,
            }
        )
    return records


def measure_lag(series: dict) -> dict:
    """Find the biggest rain peak and the lowest salinity after it.

    This is the PEAK TO PEAK method, and it is reported here only to show that
    it is wrong. It returns about 7 hours where the generator used 6, because
    rain keeps falling after its own peak and the water keeps freshening.

    The chart does not use this. It sweeps for the strongest correlation. See
    estimateLag in the static chart code.
    """
    rain = series["rainfall_mm"]
    salinity = series["salinity_psu"]
    step_hours = series["provenance"].get("interval_minutes", 60) / 60.0

    rain_peak = max(range(len(rain)), key=lambda step: rain[step])
    tail = range(rain_peak, len(salinity))
    salinity_low = min(tail, key=lambda step: salinity[step])

    return {
        "rain_peak_hour": round(rain_peak * step_hours, 2),
        "rain_peak_mm": rain[rain_peak],
        "salinity_low_hour": round(salinity_low * step_hours, 2),
        "salinity_low_psu": salinity[salinity_low],
        "peak_to_peak_lag_hours": round((salinity_low - rain_peak) * step_hours, 2),
        "configured_lag_hours": series["provenance"]["lag_hours"],
    }


def check_source_is_not_real(database: Database, source: str) -> None:
    """Stop unless the source exists and is marked not real.

    Architecture section 5 locks the source labelling rule. This check makes it
    impossible for the fixture to publish under a real source name.
    """
    is_real = database.source_is_real(source)

    if is_real is None:
        raise SystemExit(
            f"REFUSING TO PUBLISH: the source {source!r} is not in public.sources.\n"
            f"Add it with a numbered migration first."
        )

    if is_real:
        raise SystemExit(
            f"REFUSING TO PUBLISH: the source {source!r} has is_real true.\n"
            f"The fixture makes synthetic data. Synthetic data must never carry a\n"
            f"real source name. Architecture section 5 locks this rule."
        )

    log.info("the source %r has is_real false, publishing is permitted", source)


def publish(series: dict, host: str, port: int) -> int:
    records = series_to_records(series)

    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id="mobilelab-fixture")
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


def parse_start(text: str) -> datetime:
    stamp = datetime.fromisoformat(text.replace("Z", "+00:00"))
    if stamp.tzinfo is None:
        raise SystemExit("--start needs a timezone. Use a Z suffix.")
    return stamp.astimezone(UTC)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m mobilelab.fixture",
        description="Publish a seeded synthetic rainfall and salinity pair.",
    )
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED)
    parser.add_argument("--hours", type=int, default=DEFAULT_HOURS)
    parser.add_argument("--lag-hours", type=int, default=DEFAULT_LAG_HOURS)
    parser.add_argument(
        "--interval-minutes",
        type=int,
        default=60,
        help="Minutes between samples. It must divide 60. Use a small value for a scale test.",
    )
    parser.add_argument("--start", default=DEFAULT_START)
    parser.add_argument("--source", default=DEFAULT_SOURCE)
    parser.add_argument("--station-id", default=None)
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Build the series. Publish nothing.",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Print the series as JSON. Use this to compare two runs.",
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
        lag_hours=args.lag_hours,
        start=parse_start(args.start),
        station_id=station_id,
        source=args.source,
        interval_minutes=args.interval_minutes,
    )

    if args.json:
        print(json.dumps(series, indent=2, sort_keys=True))

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

    lag = measure_lag(series)
    log.info("published %d records with source %r", sent, args.source)
    log.info("seed %d, configured lag %d hours", args.seed, args.lag_hours)
    log.info(
        "the biggest rain peak is %.2f mm at hour %d",
        lag["rain_peak_mm"],
        lag["rain_peak_hour"],
    )
    log.info(
        "the lowest salinity is %.2f PSU at hour %d",
        lag["salinity_low_psu"],
        lag["salinity_low_hour"],
    )
    log.info(
        "peak to peak would report %.1f hours, and it is wrong",
        lag["peak_to_peak_lag_hours"],
    )
    log.info(
        "the chart sweeps for the strongest correlation instead, and reports about %d hours",
        lag["configured_lag_hours"],
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
