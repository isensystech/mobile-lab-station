"""A plain text plot for a terminal.

This exists so a person can see the data with no user interface.

It reads from one of two places.

  --api-url   the local API, the same path the kiosk chart will use
  default     the database directly

The API path matters more. It shows the real route, so a fault in the API shows
up here instead of hiding until the chart exists.

It obeys two locked rules.

Section 5. A series whose source has is_real false draws with a different
character, and a SIMULATED banner stays on the screen. It is not a footnote.

Section 15 rule 10. "Correlation is not causation" prints every time. It is
permanent text, not a tooltip.
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timedelta
from urllib.parse import urlencode
from urllib.request import urlopen

from .config import load_settings
from .db import Database

SOLID_FILL = "█"
DASHED_FILL = "▒"
ASCII_SOLID = "#"
ASCII_DASHED = ":"

PANEL_HEIGHT = 9
LABEL_WIDTH = 7

# render_panel writes a LABEL_WIDTH number, then " |", before the first bar.
# The hour axis and the lag ruler must start at that same column, or the R and S
# marks point at the wrong time.
GUTTER_WIDTH = LABEL_WIDTH + 2

# A 48 hour query at one minute buckets returns 2880 points. A terminal has
# nowhere to put them. Every series is averaged down to this many columns.
DISPLAY_COLUMNS = 60

SERIES_SQL = """
select r.ts, r.value, r.unit, s.is_real, s.render_hint, r.provenance
from public.readings r
join public.sources s on s.source = r.source
where r.station_id = %(station_id)s
  and r.sensor = %(sensor)s
  and r.metric = %(metric)s
  and r.source = %(source)s
order by r.ts
"""


def fetch_series_from_db(
    database: Database, station_id: str, sensor: str, metric: str, source: str
) -> dict:
    conn = database.connect()
    with conn.cursor() as cur:
        cur.execute(
            SERIES_SQL,
            {"station_id": station_id, "sensor": sensor, "metric": metric, "source": source},
        )
        rows = cur.fetchall()

    return {
        "timestamps": [row[0] for row in rows],
        "values": [None if row[1] is None else float(row[1]) for row in rows],
        "unit": rows[0][2] if rows else "",
        "is_real": bool(rows[0][3]) if rows else True,
        "render_hint": rows[0][4] if rows else "solid",
        "provenance": rows[0][5] if rows else None,
    }


def fetch_pair_from_api(
    base_url: str,
    station_id: str,
    a: tuple[str, str, str],
    b: tuple[str, str, str],
    hours: int,
) -> tuple[dict, dict, dict]:
    """Ask the local API for two series on one axis."""
    end = datetime.now().astimezone()
    start = end - timedelta(hours=hours)
    query = urlencode(
        {
            "station_id": station_id,
            "a_sensor": a[0], "a_metric": a[1], "a_source": a[2],
            "b_sensor": b[0], "b_metric": b[1], "b_source": b[2],
            "from": start.astimezone().isoformat(),
            "to": end.astimezone().isoformat(),
        }
    )
    url = f"{base_url.rstrip('/')}/api/series/pair?{query}"
    with urlopen(url, timeout=20) as response:
        payload = json.load(response)

    axis = [datetime.fromisoformat(stamp) for stamp in payload["axis"]]
    built = []
    for entry in payload["series"]:
        built.append(
            {
                "timestamps": axis,
                "values": entry["values"],
                "unit": entry["unit"] or "",
                "is_real": entry["is_real"],
                "render_hint": entry["render_hint"],
                "provenance": entry.get("provenance"),
            }
        )
    return built[0], built[1], payload


def downsample(values: list[float | None], columns: int) -> tuple[list[float | None], list[int]]:
    """Average a series down to a fixed number of columns.

    Return the new values and, for each column, the index of the first source
    point in it. The caller uses those indices to label the time axis.
    """
    count = len(values)
    if count == 0:
        return [], []
    if count <= columns:
        return list(values), list(range(count))

    reduced: list[float | None] = []
    origins: list[int] = []
    for column in range(columns):
        low = column * count // columns
        high = max((column + 1) * count // columns, low + 1)
        present = [value for value in values[low:high] if value is not None]
        reduced.append(sum(present) / len(present) if present else None)
        origins.append(low)
    return reduced, origins


def render_panel(
    values: list[float | None],
    fill: str,
    baseline_zero: bool,
    height: int = PANEL_HEIGHT,
) -> list[str]:
    """Draw one bar panel. A missing point leaves its column blank."""
    present = [value for value in values if value is not None]
    if not present:
        return ["  (no data)"]

    top = max(present)
    bottom = 0.0 if baseline_zero else min(present)
    if top <= bottom:
        top = bottom + 1.0

    margin = (top - bottom) * 0.08
    top += margin
    if not baseline_zero:
        bottom -= margin

    span = top - bottom
    lines = []
    for row in range(height, 0, -1):
        level = bottom + span * row / height
        bar = "".join(
            fill if (value is not None and value >= level) else " " for value in values
        )
        lines.append(f"{level:{LABEL_WIDTH}.1f} |{bar}")

    lines.append(f"{bottom:{LABEL_WIDTH}.1f} +{'-' * len(values)}")
    return lines


def render_time_axis(
    axis: list[datetime], origins: list[int], columns: int, step: int = 10
) -> list[str]:
    ticks = [" "] * columns
    labels = [" "] * columns
    for column in range(0, columns, step):
        if column >= len(origins) or origins[column] >= len(axis):
            continue
        ticks[column] = "^"
        stamp = axis[origins[column]]
        text = stamp.strftime("%H:%M")
        for offset, char in enumerate(text):
            if column + offset < columns:
                labels[column + offset] = char
    pad = " " * GUTTER_WIDTH
    return [pad + "".join(ticks), pad + "".join(labels) + "   local time"]


def render_lag_ruler(columns: int, peak: int, low: int) -> list[str]:
    if peak >= columns or low >= columns or low <= peak:
        return []
    line = [" "] * columns
    line[peak] = "R"
    line[low] = "S"
    for column in range(peak + 1, low):
        line[column] = "-"
    return [" " * GUTTER_WIDTH + "".join(line)]


def build_report(rain: dict, salinity: dict, use_ascii: bool, origin: str) -> list[str]:
    solid = ASCII_SOLID if use_ascii else SOLID_FILL
    dashed = ASCII_DASHED if use_ascii else DASHED_FILL

    rain_fill = dashed if rain["render_hint"] == "dashed" else solid
    salinity_fill = dashed if salinity["render_hint"] == "dashed" else solid

    out: list[str] = []
    if (not rain["is_real"]) or (not salinity["is_real"]):
        out.append("+" + "-" * 62 + "+")
        out.append("|" + "SIMULATED DATA. NOT A MEASUREMENT.".center(62) + "|")
        out.append("|" + "A generator made these numbers. Do not use them as".center(62) + "|")
        out.append("|" + "evidence about any real place.".center(62) + "|")
        out.append("+" + "-" * 62 + "+")
        out.append("")

    count = min(len(rain["values"]), len(salinity["values"]))
    if count == 0:
        out.append(f"No rows came back from {origin}.")
        out.append("Publish the fixture first, then run this again.")
        return out

    axis = rain["timestamps"][:count]
    rain_values, origins = downsample(rain["values"][:count], DISPLAY_COLUMNS)
    salinity_values, _ = downsample(salinity["values"][:count], DISPLAY_COLUMNS)
    columns = len(rain_values)

    minutes_per_column = 0
    if len(axis) > 1 and columns > 0:
        total = (axis[-1] - axis[0]).total_seconds() / 60.0
        minutes_per_column = round(total / columns)

    out.append(f"source of these numbers: {origin}")
    out.append(
        f"{count} points per series, drawn in {columns} columns, "
        f"about {minutes_per_column} minutes per column"
    )
    out.append("")
    out.append(f"RAINFALL  ({rain['unit']})   fill = {rain_fill!r}   more rain draws taller")
    out.extend(render_panel(rain_values, rain_fill, baseline_zero=True))
    out.append("")
    out.append(
        f"SALINITY  ({salinity['unit']})   fill = {salinity_fill!r}   less salt draws shorter"
    )
    out.extend(render_panel(salinity_values, salinity_fill, baseline_zero=False))

    rain_present = [i for i, v in enumerate(rain_values) if v is not None]
    salinity_present = [i for i, v in enumerate(salinity_values) if v is not None]
    if not rain_present or not salinity_present:
        out.append("")
        out.append("One series has no points, so no lag can be measured.")
        return out

    peak = max(rain_present, key=lambda i: rain_values[i])
    tail = [i for i in salinity_present if i >= peak]
    low = min(tail, key=lambda i: salinity_values[i]) if tail else peak

    out.extend(render_lag_ruler(columns, peak, low))
    out.extend(render_time_axis(axis, origins, columns))
    out.append("")

    peak_time = axis[origins[peak]]
    low_time = axis[origins[low]]
    gap_hours = (low_time - peak_time).total_seconds() / 3600.0

    out.append(
        f"R marks the biggest rain peak.  {peak_time:%d %b %H:%M}, "
        f"{rain_values[peak]:.2f} {rain['unit']}"
    )
    out.append(
        f"S marks the lowest salinity.    {low_time:%d %b %H:%M}, "
        f"{salinity_values[low]:.2f} {salinity['unit']}"
    )
    out.append(f"The gap between R and S is {gap_hours:.1f} hours.")

    provenance = rain.get("provenance") or salinity.get("provenance")
    if provenance and "lag_hours" in provenance:
        configured = provenance["lag_hours"]
        out.append(f"The generator was told to use a lag of {configured} hours.")
        out.append("")
        out.append(f"The gap on the screen is a little larger than {configured} hours. That is")
        out.append("correct. The rain keeps falling after the peak, so the water keeps")
        out.append("getting fresher for a few more hours. The lowest salinity therefore")
        out.append("comes after the delay, not exactly at it.")

    out.append("")
    out.append("The rain goes up first. The salinity goes down after it.")
    out.append("Fresh water needs time to reach the water body. That delay is the lag.")
    out.append("")
    out.append("CORRELATION IS NOT CAUSATION.")
    out.append("Two lines that move together do not prove that one causes the other.")
    return out


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m mobilelab.plot",
        description="Draw the rainfall and salinity pair in the terminal.",
    )
    parser.add_argument("--source", default="synthetic")
    parser.add_argument("--station-id", default=None)
    parser.add_argument("--ascii", action="store_true", help="Use plain ASCII characters.")
    parser.add_argument(
        "--api-url",
        default=None,
        help="Read from the local API instead of the database, for example http://127.0.0.1:8000",
    )
    parser.add_argument("--hours", type=int, default=48, help="How far back to ask the API.")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    settings = load_settings()
    station_id = args.station_id or settings.mobilelab_station_id

    if args.api_url:
        try:
            rain, salinity, payload = fetch_pair_from_api(
                args.api_url,
                station_id,
                ("rain", "rainfall", args.source),
                ("water", "salinity", args.source),
                args.hours,
            )
        except Exception as exc:
            print(f"Could not reach the API at {args.api_url}: {exc}", file=sys.stderr)
            return 2
        origin = f"the local API, {args.api_url}, served from {payload['served_from']}"
    else:
        database = Database(settings.dsn())
        try:
            rain = fetch_series_from_db(database, station_id, "rain", "rainfall", args.source)
            salinity = fetch_series_from_db(
                database, station_id, "water", "salinity", args.source
            )
        finally:
            database.close()
        origin = "the database directly, table public.readings"

    for line in build_report(rain, salinity, args.ascii, origin):
        print(line)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
