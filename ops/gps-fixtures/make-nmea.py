"""Write the NMEA logs the GPS gates replay.

WHY THIS EXISTS

A GPS receiver indoors never gets a fix. Ours sees eight satellites through the
roof and uses none of them, every time. So the GREEN path cannot be exercised on
the bench with real sky, and a gate that cannot run is not a gate.

gpsfake replays a recorded NMEA log into gpsd through a pseudo-terminal. These
are those logs. They are written here rather than committed as opaque text so
that the checksums are always right and a reader can see exactly what claim each
sentence makes.

WHAT THE DRIVER DOES WITH THEM, AND WHY IT IS SAFE

gpsfake feeds gpsd through /dev/pts. The driver treats that path as proof that a
program is producing the data, refuses to publish it under the source `gps`, and
publishes under `gps_simulated` instead. That source has is_real false and draws
dashed. Hard rule 3 is therefore enforced by the device path, not by whoever
typed the command. See services/mobilelab/gps.py and migration 0015.

THE TWO LOGS

fix.nmea      A solved 3D fix on nine satellites. This is the GREEN case.
nofix.nmea    Valid sentences, eight satellites seen, none used, fix quality 0.
              This is the AMBER case and the negative test: a receiver that is
              talking perfectly and does not know where it is. The real receiver
              produces this state indoors on its own, so the gate prefers the
              real one. This file exists so the case can be reproduced on a
              bench with no receiver at all.
"""

from __future__ import annotations

import pathlib

# Palm Bay, Florida. The same corner of the map the architecture document uses
# for its example record. A test position must not look like a real deployment,
# and it must not be 0,0 either, because 0,0 is what a broken parser produces.
LAT_DEG = 27.9944
LON_DEG = -80.6234
ALTITUDE_M = 6.4
GEOID_M = -25.7

DATE_DDMMYY = "170826"
START_HHMMSS = 143000
SECONDS = 120


def checksum(body: str) -> str:
    value = 0
    for char in body:
        value ^= ord(char)
    return f"{value:02X}"


def sentence(body: str) -> str:
    return f"${body}*{checksum(body)}"


def to_nmea_lat(degrees: float) -> tuple[str, str]:
    hemisphere = "N" if degrees >= 0 else "S"
    degrees = abs(degrees)
    whole = int(degrees)
    minutes = (degrees - whole) * 60.0
    return f"{whole:02d}{minutes:07.4f}", hemisphere


def to_nmea_lon(degrees: float) -> tuple[str, str]:
    hemisphere = "E" if degrees >= 0 else "W"
    degrees = abs(degrees)
    whole = int(degrees)
    minutes = (degrees - whole) * 60.0
    return f"{whole:03d}{minutes:07.4f}", hemisphere


def clock(index: int) -> str:
    base = START_HHMMSS
    hours, rest = divmod(base, 10000)
    minutes, seconds = divmod(rest, 100)
    total = hours * 3600 + minutes * 60 + seconds + index
    hours, rest = divmod(total, 3600)
    minutes, seconds = divmod(rest, 60)
    return f"{hours:02d}{minutes:02d}{seconds:02d}.00"


def fix_log() -> list[str]:
    """A solved 3D fix. Nine satellites used, HDOP 0.9."""
    lat, lat_h = to_nmea_lat(LAT_DEG)
    lon, lon_h = to_nmea_lon(LON_DEG)
    # TWELVE PRN slots, always. Nine used and three empty.
    #
    # The first version of this file wrote nine PRNs and FOUR empty fields,
    # which is thirteen slots. gpsd read the extra comma as a shifted field,
    # decided the sentence described a 2D fix, and reported mode 2. The gate
    # then failed asking for green while gpsd was correctly refusing to give
    # one. NMEA is positional. A spare comma is a different sentence.
    used = "01,03,06,11,14,17,19,22,28,,,"
    lines: list[str] = []

    for index in range(SECONDS):
        now = clock(index)
        lines.append(
            sentence(
                f"GPGGA,{now},{lat},{lat_h},{lon},{lon_h},1,09,0.9,"
                f"{ALTITUDE_M:.1f},M,{GEOID_M:.1f},M,,"
            )
        )
        lines.append(sentence(f"GPGSA,A,3,{used},1.7,0.9,1.4"))
        lines.append(
            sentence(
                "GPGSV,3,1,09,01,74,042,44,03,58,301,41,06,45,118,39,11,39,225,38"
            )
        )
        lines.append(
            sentence(
                "GPGSV,3,2,09,14,31,072,37,17,26,289,35,19,21,155,34,22,18,331,33"
            )
        )
        lines.append(sentence("GPGSV,3,3,09,28,12,201,31"))
        lines.append(
            sentence(
                f"GPRMC,{now},A,{lat},{lat_h},{lon},{lon_h},0.03,0.00,"
                f"{DATE_DDMMYY},,,A"
            )
        )
    return lines


def nofix_log() -> list[str]:
    """Talking perfectly, and lost. Eight satellites seen, none used.

    This is the shape the real receiver produces indoors. Fix quality 0 in GGA,
    mode 1 in GSA, status V in RMC, and an SNR on every satellite in GSV so that
    nobody can claim the receiver was not hearing anything.
    """
    lines: list[str] = []
    for index in range(SECONDS):
        now = clock(index)
        lines.append(sentence(f"GPGGA,{now},,,,,0,00,,,M,,M,,"))
        lines.append(sentence("GPGSA,A,1,,,,,,,,,,,,,,,"))
        lines.append(
            sentence("GPGSV,2,1,08,26,,,31,08,,,28,31,,,34,28,,,21")
        )
        lines.append(
            sentence("GPGSV,2,2,08,04,,,24,16,,,26,03,,,33,27,,,29")
        )
        lines.append(sentence(f"GPRMC,{now},V,,,,,0.00,0.00,{DATE_DDMMYY},,,N"))
    return lines


def main() -> int:
    here = pathlib.Path(__file__).resolve().parent
    for name, lines in (("fix.nmea", fix_log()), ("nofix.nmea", nofix_log())):
        path = here / name
        path.write_text("\r\n".join(lines) + "\r\n", encoding="ascii")
        print(f"{path}  {len(lines)} sentences")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
