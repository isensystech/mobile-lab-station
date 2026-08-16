"""The common record shape.

Architecture section 2 locks this shape. Every driver publishes it. The manual
entry form publishes it. The synthetic fixture publishes it. The writer accepts
nothing else.

The model refuses an unknown field on purpose. A driver that invents a field has
a defect, and a silent drop hides it.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from typing import Any, Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, field_validator

QualityFlag = Literal["plausible", "implausible", "verified"]

TOPIC_PREFIX = "station"
TOPIC_PART_COUNT = 4

# The clock sanity window. HARD RULE, added 2026-08-15 by Scott.
#
# The Pi 5 has no RTC battery fitted. A power cut sets the clock to
# 1970-01-01. NTP fixes it, but only when a network is present. In a field
# session there is no network, so every reading taken after a power cut carries
# a 1970 timestamp and lands 56 years in the past. It falls outside every chart
# window and outside every continuous aggregate refresh window.
#
# A missing reading beats a corrupt one. Reject the row and say so loudly.
CLOCK_FLOOR = datetime(2026, 1, 1, tzinfo=UTC)
CLOCK_FUTURE_LIMIT = timedelta(hours=24)


class Reading(BaseModel):
    """One measured value at one moment."""

    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)

    station_id: str = Field(min_length=1)
    sensor: str = Field(min_length=1)
    metric: str = Field(min_length=1)
    value: float | None = None
    unit: str | None = None
    ts: datetime
    lat: float | None = None
    lon: float | None = None
    source: str = Field(min_length=1)

    observation_id: UUID | None = None
    dive_id: UUID | None = None
    value_raw: float | None = None
    unit_raw: str | None = None
    ref_distance_m: float | None = None
    quality_flag: QualityFlag | None = None
    provenance: dict[str, Any] | None = None

    @field_validator("ts")
    @classmethod
    def ts_must_carry_a_timezone(cls, value: datetime) -> datetime:
        if value.tzinfo is None:
            raise ValueError(
                "ts has no timezone. Send UTC with a Z suffix, "
                "for example 2026-08-15T14:22:00Z."
            )
        return value

    @field_validator("lat")
    @classmethod
    def lat_must_be_on_the_earth(cls, value: float | None) -> float | None:
        if value is not None and not -90.0 <= value <= 90.0:
            raise ValueError("lat must be between -90 and 90.")
        return value

    @field_validator("lon")
    @classmethod
    def lon_must_be_on_the_earth(cls, value: float | None) -> float | None:
        if value is not None and not -180.0 <= value <= 180.0:
            raise ValueError("lon must be between -180 and 180.")
        return value


class TopicMismatch(ValueError):
    """The topic and the payload disagree about what this row is."""


class ImplausibleClock(ValueError):
    """The timestamp cannot be right, so the reading cannot be trusted."""


def check_clock(reading: Reading, now: datetime | None = None) -> None:
    """Refuse a reading whose timestamp cannot be right.

    A reading from before 2026 comes from a Pi that lost its clock. A reading
    from more than a day ahead comes from a clock that ran forward. Neither can
    be placed on a time axis, so neither is worth keeping.
    """
    now = now or datetime.now(UTC)

    if reading.ts < CLOCK_FLOOR:
        raise ImplausibleClock(
            f"ts {reading.ts.isoformat()} is before {CLOCK_FLOOR.date()}. "
            f"The station clock is wrong. Check the RTC battery."
        )

    ahead = reading.ts - now
    if ahead > CLOCK_FUTURE_LIMIT:
        raise ImplausibleClock(
            f"ts {reading.ts.isoformat()} is {ahead.total_seconds() / 3600:.1f} hours "
            f"ahead of now. The limit is {CLOCK_FUTURE_LIMIT.total_seconds() / 3600:.0f} hours."
        )


def parse_topic(topic: str) -> dict[str, str] | None:
    """Read station_id, sensor, and metric out of a topic.

    The topic shape is station/<station_id>/<sensor>/<metric>. Return None if
    the topic does not have that shape.
    """
    parts = topic.split("/")
    if len(parts) != TOPIC_PART_COUNT or parts[0] != TOPIC_PREFIX:
        return None
    if not all(parts[1:]):
        return None
    return {"station_id": parts[1], "sensor": parts[2], "metric": parts[3]}


def reading_from_message(topic: str, payload: dict[str, Any]) -> Reading:
    """Build a Reading from a topic and a decoded payload.

    The topic fills in station_id, sensor, and metric when the payload omits
    them. A disagreement between the two is an error, never a silent choice.
    """
    from_topic = parse_topic(topic)

    if from_topic is not None:
        for key, topic_value in from_topic.items():
            payload_value = payload.get(key)
            if payload_value is None:
                payload[key] = topic_value
            elif str(payload_value) != topic_value:
                raise TopicMismatch(
                    f"topic says {key}={topic_value!r} "
                    f"but the payload says {key}={payload_value!r}"
                )

    return Reading.model_validate(payload)
