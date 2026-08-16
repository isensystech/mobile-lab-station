"""The sensor suite, and the rule that a planned sensor shows no number.

Architecture section 13 lists the full eventual suite. Most of it is not built.

HARD RULE, the same rule as source labelling.

    A PLANNED sensor tile must not display a value, a placeholder, or example
    data.

A planned entry carries no `reading` key at all. The key is absent, not null
and not zero, so a renderer cannot read a number that was never there. The API
asserts this before it answers.

The reason is the same as architecture section 5. The failure that matters is a
screenshot where a sensor that does not exist appears to have measured
something. A number beside "Soil probe" is a lie that survives in a slide deck
long after the demo ends.

A LIVE or MANUAL tile reads the newest real reading from the database. If there
is none, the tile says so. It must never fall back to the example number in the
shell file.

AN EMPTY MANUAL TILE IS STILL MANUAL.

Absence of data is not absence of capability. The rain gauge is read by hand
every day. It is a working part of the station whether or not a reading arrived
today, so it carries the manual chip and not the planned chip.

Each tile names the sources it may read. A manual tile reads `manual` only. The
query also demands `is_real`. A synthetic fixture number therefore cannot reach
a tile through either door, which matters most for rainfall, because the fixture
publishes rainfall every time it runs.
"""

from __future__ import annotations

from dataclasses import dataclass, field

LIVE = "live"
MANUAL = "manual"
PLANNED = "planned"


@dataclass(frozen=True)
class Sensor:
    number: int
    name: str
    parameters: str
    interface: str
    tier: str
    status: str
    note: str
    # Only a live or manual sensor names a reading to look up.
    sensor: str | None = None
    metric: str | None = None
    sources: tuple[str, ...] = field(default_factory=tuple)


# Copied from architecture section 13, in the same order.
SUITE: tuple[Sensor, ...] = (
    Sensor(
        number=1, name="WQL Logger", parameters="Full dive suite",
        interface="HTTP to the bridge, then MQTT", tier="V1", status=LIVE,
        note="The logger records a dive. It uploads the file when it comes to the surface.",
        sensor="water", metric="temperature", sources=("wql",),
    ),
    Sensor(
        number=2, name="GPS", parameters="Latitude, longitude, time",
        interface="USB or UART, through gpsd", tier="V1", status=PLANNED,
        note="The gpsd driver is not built. The station takes position from the dive file today.",
    ),
    Sensor(
        number=3, name="Apera PC60", parameters="ORP, pH, EC, temperature",
        interface="Manual entry card", tier="V1", status=MANUAL,
        note="A person reads the meter and types the number into the entry form.",
        sensor="water", metric="ph", sources=("manual",),
    ),
    Sensor(
        number=4, name="Soil probe",
        parameters="pH, temperature, moisture, air humidity, light, fertility",
        interface="RS485, Modbus", tier="V2", status=PLANNED,
        note="No Modbus driver is built. The bus is a V2 decision.",
    ),
    Sensor(
        number=5, name="Air probe",
        parameters="PPM, wind speed, wind direction, temperature, humidity, UV",
        interface="RS485, Modbus", tier="V2", status=PLANNED,
        note="Shares one RS485 pair with the other Modbus sensors.",
    ),
    Sensor(
        number=6, name="Rain gauge", parameters="Tipping bucket rainfall",
        interface="Manual entry card today. GPIO pulse in V2.", tier="V1", status=MANUAL,
        note=(
            "A person reads the gauge and types the number, three times a day. "
            "A tipping bucket on GPIO replaces the typing in V2."
        ),
        sensor="rain", metric="rainfall", sources=("manual",),
    ),
    Sensor(
        number=7, name="Noise", parameters="dB SPL",
        interface="RS485 or I2S", tier="V3", status=PLANNED,
        note="A Modbus variant must be sourced first.",
    ),
    Sensor(
        number=8, name="Creek current", parameters="Flow and velocity",
        interface="RS485 or SDI-12", tier="V3", status=PLANNED,
        note="Shares the same RS485 pair.",
    ),
    Sensor(
        number=9, name="Buoy current", parameters="Speed and velocity",
        interface="LoRa, US915, point to point", tier="V3", status=PLANNED,
        note="One buoy to one base. No network server is needed.",
    ),
)

NEWEST_READING = """
select r.value, r.unit, r.ts, r.source, s.is_real
from public.readings r
join public.sources s on s.source = r.source
where r.station_id = %(station_id)s
  and r.sensor = %(sensor)s
  and r.metric = %(metric)s
  and r.source = any(%(sources)s)
  and s.is_real = true
order by r.ts desc
limit 1
"""


class PlannedSensorHasValue(AssertionError):
    """A planned sensor carried a reading. That is the defect this rule exists to stop."""


def assert_no_planned_values(payload: list[dict]) -> None:
    """Refuse to answer if a planned tile carries anything a renderer could draw."""
    for entry in payload:
        if entry["status"] != PLANNED:
            continue
        if "reading" in entry:
            raise PlannedSensorHasValue(
                f"sensor {entry['number']} {entry['name']} is planned and carries a reading key"
            )
