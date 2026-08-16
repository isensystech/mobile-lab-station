"""The WQL dive CSV contract, and the parser.

THE COLUMN CONTRACT IS POSITIONAL AND APPEND-ONLY.

The header below is copied from the firmware, `writeMetaHeader()` in
`firmware/src/main.cpp`. That line is the authority. If the firmware changes it,
this file must change with it, and a numbered note must record why.

    NOTE, REPORT TO SCOTT. Architecture section 3 calls this a 24-field CSV and
    lists 19 names "plus GPS columns". The firmware writes 25 columns. The arch
    document is one short. The list below is the firmware's, counted.

The parser refuses a file whose column count is not exactly 25. It does not
guess, it does not pad, and it does not shift. A firmware change must break
loudly here, on the first upload, rather than silently move every value one
column to the left and poison a season of data.

FILE SHAPE, from parse-dive/index.ts and writeMetaHeader():

    # file: /dive0007.csv          <- meta lines, any number, '#' prefixed
    # utc_start: 2026-06-28T10:02:00Z
    # time_source: PHONE
    ...
    ms,utc,submerged,...,gps_src   <- exactly one column header line
    0,2026-06-28T10:02:00Z,1,0,... <- data rows

    An empty cell means no reading for that column.
    The utc cell is ISO-8601 UTC, or the literal string 'unsynced'.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import UTC, datetime

# Copied verbatim from firmware/src/main.cpp writeMetaHeader().
DIVE_HEADER = (
    "ms,utc,submerged,poi,P_mbar,depth_m,bar30T_C,poetT_mC,ugs_uV,orp_uV,"
    "ec_nA,ec_uV,pH,EC_mScm,sal_PSU,ORP_Eh_mV,cyc_V,cyc_conc,cels_T_C,"
    "gps_lat,gps_lon,gps_fix,gps_sats,gps_age_s,gps_src"
)
DIVE_COLUMNS: tuple[str, ...] = tuple(DIVE_HEADER.split(","))
DIVE_COLUMN_COUNT = len(DIVE_COLUMNS)

COL = {name: index for index, name in enumerate(DIVE_COLUMNS)}

DIVE_SOURCE = "wql"
DIVE_SENSOR = "water"

UNSYNCED = "unsynced"


@dataclass(frozen=True)
class MetricColumn:
    """One CSV column that becomes a reading."""

    column: str
    metric: str
    unit: str
    scale: float = 1.0


# The science channels only.
#
# This mirrors the cloud's own decision in cloud/supabase/migrations/0007_samples.sql:
# "Raw channels (P_mbar,*_uV,ec_nA,cyc_V,bar30T_C,poetT_mC) live in the blob only."
# The station keeps one mental model with Supabase, so it keeps the same list.
METRIC_COLUMNS: tuple[MetricColumn, ...] = (
    MetricColumn("depth_m", "depth", "m"),
    MetricColumn("pH", "ph", "ph"),
    MetricColumn("ORP_Eh_mV", "orp", "mV"),
    MetricColumn("EC_mScm", "ec", "mScm"),
    MetricColumn("sal_PSU", "salinity", "PSU"),
    MetricColumn("cyc_conc", "cyclops", "ppb"),
)

# Temperature has three possible sources. The cloud resolves them in this order
# at parse time, so the station does too.
TEMPERATURE_ORDER = (
    ("cels_T_C", 1.0),
    ("bar30T_C", 1.0),
    ("poetT_mC", 0.001),
)


class DiveFormatError(ValueError):
    """The file is not a dive CSV this station can read. Nothing is ingested."""


@dataclass
class DiveMeta:
    lines: list[str]
    fields: dict[str, str]

    def get(self, key: str) -> str | None:
        return self.fields.get(key)


@dataclass
class ParsedDive:
    meta: DiveMeta
    rows: list[list[str]]
    header: list[str]


def _number(cell: str | None) -> float | None:
    if cell is None:
        return None
    text = cell.strip()
    if text == "":
        return None
    try:
        value = float(text)
    except ValueError:
        return None
    return value if value == value and value not in (float("inf"), float("-inf")) else None


def parse_meta(lines: list[str]) -> DiveMeta:
    fields: dict[str, str] = {}
    for line in lines:
        match = re.match(r"^([A-Za-z0-9_]+):\s*(.*)$", line)
        if match:
            fields[match.group(1)] = match.group(2).strip()
    return DiveMeta(lines=lines, fields=fields)


def parse_dive_csv(text: str) -> ParsedDive:
    """Split a dive file into meta, header, and rows.

    Raise DiveFormatError on anything unexpected. The caller must ingest
    nothing when this raises.
    """
    meta_lines: list[str] = []
    header: list[str] | None = None
    rows: list[list[str]] = []

    for number, raw in enumerate(text.splitlines(), start=1):
        line = raw.strip("\r")
        if line == "":
            continue
        if line.startswith("#"):
            if header is not None:
                raise DiveFormatError(
                    f"line {number}: a meta line starting with '#' appears after the column "
                    f"header. The file is not in the documented order."
                )
            meta_lines.append(re.sub(r"^#\s?", "", line))
            continue
        cells = line.split(",")
        if header is None:
            header = cells
            if len(header) != DIVE_COLUMN_COUNT:
                raise DiveFormatError(
                    f"line {number}: the column header has {len(header)} columns. "
                    f"This station reads exactly {DIVE_COLUMN_COUNT}. "
                    f"Expected: {DIVE_HEADER}. Got: {','.join(header)}. "
                    f"Nothing was ingested. A firmware change must be reviewed before "
                    f"this station accepts the new format."
                )
            if header != list(DIVE_COLUMNS):
                differences = [
                    f"position {i}: expected {want!r}, got {got!r}"
                    for i, (want, got) in enumerate(zip(DIVE_COLUMNS, header))
                    if want != got
                ]
                raise DiveFormatError(
                    "the column header does not match the documented header. "
                    + "; ".join(differences[:5])
                    + ". Nothing was ingested."
                )
            continue
        if len(cells) != DIVE_COLUMN_COUNT:
            raise DiveFormatError(
                f"line {number}: this data row has {len(cells)} columns and the header has "
                f"{DIVE_COLUMN_COUNT}. Parsing by position is no longer safe, so nothing "
                f"was ingested."
            )
        rows.append(cells)

    if header is None:
        raise DiveFormatError(
            "the file has no column header line. "
            f"Expected a line reading: {DIVE_HEADER}. Nothing was ingested."
        )

    return ParsedDive(meta=parse_meta(meta_lines), rows=rows, header=header)


def row_timestamp(cells: list[str]) -> tuple[datetime | None, str | None]:
    """Read the utc cell. Return the time, or a reason it cannot be used."""
    raw = cells[COL["utc"]].strip()
    if raw == "" or raw == UNSYNCED:
        return None, "unsynced_clock"
    try:
        stamp = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return None, "unparsable_timestamp"
    if stamp.tzinfo is None:
        stamp = stamp.replace(tzinfo=UTC)
    return stamp.astimezone(UTC), None


def row_position(cells: list[str]) -> tuple[float | None, float | None]:
    lat = _number(cells[COL["gps_lat"]])
    lon = _number(cells[COL["gps_lon"]])
    if lat is None or lon is None:
        return None, None
    if lat == 0.0 and lon == 0.0:
        return None, None
    return lat, lon


def row_temperature(cells: list[str]) -> float | None:
    for column, scale in TEMPERATURE_ORDER:
        value = _number(cells[COL[column]])
        if value is not None:
            return value * scale
    return None


def row_readings(cells: list[str], cyclops_unit: str) -> list[dict]:
    """Turn one CSV row into the readings it carries.

    An empty cell is not a reading. It is skipped, not stored as zero.
    """
    out: list[dict] = []

    temperature = row_temperature(cells)
    if temperature is not None:
        out.append({"metric": "temperature", "value": temperature, "unit": "degC"})

    for spec in METRIC_COLUMNS:
        value = _number(cells[COL[spec.column]])
        if value is None:
            continue
        unit = cyclops_unit if spec.metric == "cyclops" else spec.unit
        out.append({"metric": spec.metric, "value": value * spec.scale, "unit": unit})

    return out


def dive_metadata(meta: DiveMeta) -> dict:
    """Pull the fields the manifest keeps out of the meta header."""
    utc_start = meta.get("utc_start")
    if utc_start in (None, "", UNSYNCED):
        start = None
    else:
        try:
            start = datetime.fromisoformat(utc_start.replace("Z", "+00:00"))
        except ValueError:
            start = None

    cast = meta.get("cast")
    try:
        cast_num = int(cast) if cast not in (None, "") else None
    except ValueError:
        cast_num = None

    return {
        "utc_start": start,
        "time_source": meta.get("time_source"),
        "cast_num": cast_num,
        "mission": meta.get("mission"),
        "operator": meta.get("operator"),
        "site": meta.get("site"),
        "water_type": meta.get("water_type"),
        "cyclops_unit": meta.get("cyclops_units") or "ppb",
        "meta_lines": meta.lines,
    }
