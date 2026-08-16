"""Make a dive CSV in the documented 25 column format.

THIS IS NOT A REAL LOGGER FILE.

No WQL logger has posted to this station. This generator writes a file that
matches `writeMetaHeader()` in firmware/src/main.cpp, column for column, so the
parser can be exercised. It proves the parser reads the FORMAT. It does not
prove the parser reads a REAL DIVE, because no real dive file exists here yet.

Say that plainly in any report that uses this file.

The generator is deterministic. The same seed makes the same dive.
"""

from __future__ import annotations

import argparse
import hashlib
import math
import sys
from datetime import UTC, datetime, timedelta

from .dive import DIVE_COLUMNS, DIVE_HEADER


def unit_float(seed: int, channel: str, index: int) -> float:
    digest = hashlib.sha256(f"{seed}:{channel}:{index}".encode("utf-8")).digest()
    return int.from_bytes(digest[:8], "big") / float(1 << 64)


def depth_profile(index: int, rows: int) -> float:
    """A descent, a while on the bottom, then an ascent."""
    fraction = index / max(rows - 1, 1)
    if fraction < 0.2:
        return 12.0 * (fraction / 0.2)
    if fraction < 0.75:
        return 12.0 + 1.5 * math.sin((fraction - 0.2) * 12.0)
    return max(0.0, 12.0 * (1.0 - (fraction - 0.75) / 0.25))


def build_dive(
    seed: int,
    rows: int,
    start: datetime,
    interval_seconds: int,
    cast: int,
    site: str,
    unsynced_rows: tuple[int, ...] = (),
    bad_clock_rows: tuple[int, ...] = (),
    bad_clock_stamp: str = "1970-01-01T00:00:09Z",
    drop_column: str | None = None,
) -> str:
    columns = list(DIVE_COLUMNS)
    if drop_column:
        if drop_column not in columns:
            raise SystemExit(f"{drop_column} is not a column in the dive header.")
        columns.remove(drop_column)

    meta = [
        f"# file: /dive{cast:04d}.csv",
        f"# utc_start: {start.isoformat().replace('+00:00', 'Z')}",
        "# time_source: PHONE",
        f"# cast: {cast}",
        "# mission: Mobile lab demo",
        "# operator: A. Student",
        f"# site: {site}",
        "# water_type: brackish",
        "# gps: 27.990000,-80.620000",
        "# weather: Sunny  air_C: 31.0",
        "# notes: Generated dive. NOT a real logger file.",
        "# cal_ph: Y  cal_ec: Y  cal_orp: Y  cal_cyc: N",
        "# sensors: POET=on BAR30=on CELS=on CYC=on GPS=on",
        "# cyclops_units: ppb",
        "# gps_source: live",
        "# gps_columns: gps_lat,gps_lon stamped every sample from the best source; "
        "gps_src=live|held|manual|none (held=last fix, no live signal -> stale, see gps_age_s); "
        "gps_fix 1=live",
    ]

    lines = list(meta)
    lines.append(",".join(columns))

    for index in range(rows):
        stamp = start + timedelta(seconds=index * interval_seconds)
        depth = depth_profile(index, rows)
        wobble = unit_float(seed, "wobble", index) - 0.5

        temperature = 26.4 - depth * 0.12 + wobble * 0.06
        salinity = 29.5 + depth * 0.05 + wobble * 0.08
        conductivity = 45.2 + depth * 0.07 + wobble * 0.10
        ph = 8.08 - depth * 0.004 + wobble * 0.02
        orp = 205.0 + wobble * 6.0
        cyclops = 2.4 + max(0.0, 12.0 - depth) * 0.05 + wobble * 0.15
        pressure = 1013.0 + depth * 100.7

        cells = {
            "ms": str(index * interval_seconds * 1000),
            "utc": stamp.isoformat().replace("+00:00", "Z"),
            "submerged": "1" if depth > 0.3 else "0",
            "poi": "1" if index == rows // 2 else "0",
            "P_mbar": f"{pressure:.1f}",
            "depth_m": f"{depth:.3f}",
            "bar30T_C": f"{temperature + 0.05:.3f}",
            "poetT_mC": f"{(temperature - 0.02) * 1000:.0f}",
            "ugs_uV": f"{-412.0 + wobble * 8:.1f}",
            "orp_uV": f"{orp * 1000:.0f}",
            "ec_nA": f"{1180.0 + wobble * 20:.1f}",
            "ec_uV": f"{2260.0 + wobble * 25:.1f}",
            "pH": f"{ph:.3f}",
            "EC_mScm": f"{conductivity:.3f}",
            "sal_PSU": f"{salinity:.3f}",
            "ORP_Eh_mV": f"{orp:.1f}",
            "cyc_V": f"{0.42 + wobble * 0.02:.4f}",
            "cyc_conc": f"{cyclops:.3f}",
            "cels_T_C": f"{temperature:.3f}",
            "gps_lat": "27.990000",
            "gps_lon": "-80.620000",
            "gps_fix": "1",
            "gps_sats": "9",
            "gps_age_s": "0",
            "gps_src": "live",
        }

        if index in unsynced_rows:
            cells["utc"] = "unsynced"
        if index in bad_clock_rows:
            cells["utc"] = bad_clock_stamp

        lines.append(",".join(cells[name] for name in columns))

    return "\n".join(lines) + "\n"


def parse_int_list(text: str) -> tuple[int, ...]:
    if not text:
        return ()
    return tuple(int(part) for part in text.split(",") if part.strip() != "")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="python -m mobilelab.divefixture",
        description="Write a dive CSV in the documented 25 column format. NOT a real logger file.",
    )
    parser.add_argument("--seed", type=int, default=4242)
    parser.add_argument("--rows", type=int, default=600)
    parser.add_argument("--interval-seconds", type=int, default=1)
    parser.add_argument("--cast", type=int, default=7)
    parser.add_argument("--site", default="Creek bridge")
    parser.add_argument("--start", default=None, help="ISO start time. Default is 3 hours ago.")
    parser.add_argument("--unsynced-rows", default="", help="Row indexes to mark unsynced.")
    parser.add_argument("--bad-clock-rows", default="", help="Row indexes to stamp 1970.")
    parser.add_argument("--drop-column", default=None, help="Remove a column, to test the guard.")
    args = parser.parse_args(argv)

    if args.start:
        start = datetime.fromisoformat(args.start.replace("Z", "+00:00")).astimezone(UTC)
    else:
        start = (datetime.now(UTC) - timedelta(hours=3)).replace(microsecond=0)

    sys.stdout.write(
        build_dive(
            seed=args.seed,
            rows=args.rows,
            start=start,
            interval_seconds=args.interval_seconds,
            cast=args.cast,
            site=args.site,
            unsynced_rows=parse_int_list(args.unsynced_rows),
            bad_clock_rows=parse_int_list(args.bad_clock_rows),
            drop_column=args.drop_column,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())


HEADER_FOR_REFERENCE = DIVE_HEADER
