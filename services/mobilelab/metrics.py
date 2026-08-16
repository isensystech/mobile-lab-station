"""The metric catalogue, unit conversion, and the plausible range.

Three rules live here.

1. Store what the person typed. `value_raw` and `unit_raw` keep the number and
   the unit exactly as entered. A student who works in degrees Fahrenheit must
   see their own number again.

2. Store the canonical conversion beside it. `value` and `unit` hold the
   converted number, so every chart and every query works in one unit.

3. Flag, never reject. A value outside the plausible range still saves. It
   saves with quality_flag='implausible'. Hard rules 1 and 12 both say so.
"""

from __future__ import annotations

from dataclasses import dataclass, field

PLAUSIBLE = "plausible"
IMPLAUSIBLE = "implausible"


@dataclass(frozen=True)
class Metric:
    sensor: str
    metric: str
    label: str
    canonical_unit: str
    units: tuple[str, ...]
    low: float
    high: float
    hint: str
    step: str = "any"

    @property
    def key(self) -> str:
        return f"{self.sensor}/{self.metric}"


CATALOGUE: tuple[Metric, ...] = (
    Metric(
        sensor="rain", metric="rainfall", label="Rainfall",
        canonical_unit="mm", units=("mm", "in"), low=0.0, high=500.0,
        hint="How much rain fell since the last reading.", step="0.1",
    ),
    Metric(
        sensor="air", metric="temperature", label="Air temperature",
        canonical_unit="degC", units=("degC", "degF"), low=-20.0, high=60.0,
        hint="The air temperature at the site.", step="0.1",
    ),
    Metric(
        sensor="water", metric="temperature", label="Water temperature",
        canonical_unit="degC", units=("degC", "degF"), low=-5.0, high=45.0,
        hint="The water temperature at the site.", step="0.1",
    ),
    Metric(
        sensor="water", metric="ph", label="pH",
        canonical_unit="ph", units=("ph",), low=0.0, high=14.0,
        hint="Acid or alkaline. Pure water is 7.", step="0.01",
    ),
    Metric(
        sensor="water", metric="salinity", label="Salinity",
        canonical_unit="PSU", units=("PSU", "ppt"), low=0.0, high=45.0,
        hint="How much salt is in the water.", step="0.01",
    ),
    Metric(
        sensor="water", metric="ec", label="Conductivity",
        canonical_unit="mScm", units=("mScm", "uScm"), low=0.0, high=200.0,
        hint="How well the water carries electricity.", step="0.01",
    ),
    Metric(
        sensor="water", metric="orp", label="ORP",
        canonical_unit="mV", units=("mV",), low=-1000.0, high=1000.0,
        hint="Oxidation and reduction potential.", step="1",
    ),
    Metric(
        sensor="soil", metric="moisture", label="Soil moisture",
        canonical_unit="pct", units=("pct",), low=0.0, high=100.0,
        hint="How wet the soil is, from 0 to 100.", step="0.1",
    ),
)

BY_KEY: dict[str, Metric] = {m.key: m for m in CATALOGUE}


def _fahrenheit_to_celsius(value: float) -> float:
    return (value - 32.0) * 5.0 / 9.0


def _inches_to_millimetres(value: float) -> float:
    return value * 25.4


def _micro_to_milli(value: float) -> float:
    return value / 1000.0


def _same(value: float) -> float:
    return value


CONVERSIONS = {
    ("degF", "degC"): _fahrenheit_to_celsius,
    ("degC", "degC"): _same,
    ("in", "mm"): _inches_to_millimetres,
    ("mm", "mm"): _same,
    ("uScm", "mScm"): _micro_to_milli,
    ("mScm", "mScm"): _same,
    ("ppt", "PSU"): _same,
    ("PSU", "PSU"): _same,
    ("ph", "ph"): _same,
    ("mV", "mV"): _same,
    ("pct", "pct"): _same,
}


class UnknownMetric(ValueError):
    """The catalogue has no such sensor and metric."""


class UnknownUnit(ValueError):
    """The catalogue does not accept that unit for that metric."""


def find(sensor: str, metric: str) -> Metric:
    key = f"{sensor}/{metric}"
    if key not in BY_KEY:
        raise UnknownMetric(f"{key} is not in the metric catalogue.")
    return BY_KEY[key]


def to_canonical(sensor: str, metric: str, value_raw: float, unit_raw: str) -> tuple[float, str]:
    """Return the canonical value and unit for what the person typed."""
    entry = find(sensor, metric)
    if unit_raw not in entry.units:
        raise UnknownUnit(
            f"{unit_raw} is not a unit for {entry.label}. Use one of {', '.join(entry.units)}."
        )
    convert = CONVERSIONS.get((unit_raw, entry.canonical_unit))
    if convert is None:
        raise UnknownUnit(f"There is no conversion from {unit_raw} to {entry.canonical_unit}.")
    return round(convert(float(value_raw)), 6), entry.canonical_unit


def quality_flag(sensor: str, metric: str, canonical_value: float) -> str:
    """Judge the canonical value. This never blocks a save."""
    entry = find(sensor, metric)
    if canonical_value < entry.low or canonical_value > entry.high:
        return IMPLAUSIBLE
    return PLAUSIBLE


def plausible_range_text(sensor: str, metric: str) -> str:
    entry = find(sensor, metric)
    return f"{entry.low} to {entry.high} {entry.canonical_unit}"


def catalogue_payload() -> list[dict]:
    return [
        {
            "sensor": m.sensor,
            "metric": m.metric,
            "key": m.key,
            "label": m.label,
            "canonical_unit": m.canonical_unit,
            "units": list(m.units),
            "low": m.low,
            "high": m.high,
            "hint": m.hint,
            "step": m.step,
            "plausible_range": plausible_range_text(m.sensor, m.metric),
        }
        for m in CATALOGUE
    ]
