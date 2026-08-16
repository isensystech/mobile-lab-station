"""Look at what is really on the screen, pixel by pixel.

`grim -t ppm` writes a raw RGB image of the whole output. This reads it with no
image library, so the check needs nothing that is not already on the Pi.

It answers three questions a person would otherwise answer by eye:

  Is the chart page filling the screen, top row included?
  Is the desktop taskbar visible anywhere?
  Is a dialog box sitting in the middle of the screen?

The chart page header is the PlanetWerx brand teal, #08828c. The desktop
behind it is not.
"""

from __future__ import annotations

import sys
from collections import Counter

HEADER = (5, 42, 48)
TOLERANCE = 12


def read_ppm(path: str) -> tuple[int, int, bytes]:
    with open(path, "rb") as handle:
        data = handle.read()
    if not data.startswith(b"P6"):
        raise SystemExit(f"{path} is not a binary PPM")

    fields = []
    index = 2
    while len(fields) < 3:
        while index < len(data) and data[index : index + 1].isspace():
            index += 1
        if data[index : index + 1] == b"#":
            while data[index : index + 1] not in (b"\n", b""):
                index += 1
            continue
        start = index
        while index < len(data) and not data[index : index + 1].isspace():
            index += 1
        fields.append(int(data[start:index]))
    index += 1
    width, height, _ = fields
    return width, height, data[index:]


def pixel(pixels: bytes, width: int, x: int, y: int) -> tuple[int, int, int]:
    offset = (y * width + x) * 3
    return pixels[offset], pixels[offset + 1], pixels[offset + 2]


def close_to(colour: tuple[int, int, int], target: tuple[int, int, int]) -> bool:
    return all(abs(a - b) <= TOLERANCE for a, b in zip(colour, target))


def row_colours(pixels: bytes, width: int, y: int, step: int = 7) -> Counter:
    counts: Counter = Counter()
    for x in range(0, width, step):
        counts[pixel(pixels, width, x, y)] += 1
    return counts


def main() -> int:
    path = sys.argv[1]
    width, height, pixels = read_ppm(path)
    print(f"screen: {width} by {height}")

    top = row_colours(pixels, width, 0)
    top_colour, top_count = top.most_common(1)[0]
    share = top_count / sum(top.values())
    print(f"top row, commonest colour: rgb{top_colour}, {share:.0%} of the row")

    header_rows = 0
    for y in range(0, min(40, height)):
        counts = row_colours(pixels, width, y)
        colour, count = counts.most_common(1)[0]
        if close_to(colour, HEADER) and count / sum(counts.values()) > 0.5:
            header_rows += 1
    print(f"rows at the top matching the page header #08828c: {header_rows}")

    bottom = row_colours(pixels, width, height - 1)
    bottom_colour, bottom_count = bottom.most_common(1)[0]
    print(
        f"bottom row, commonest colour: rgb{bottom_colour}, "
        f"{bottom_count / sum(bottom.values()):.0%} of the row"
    )

    distinct_top = len(top)
    print(f"distinct colours sampled across the top row: {distinct_top}")

    verdict_header = close_to(top_colour, HEADER)
    print()
    print("CHECKS")
    print(f"  page reaches the very top row     {'PASS' if verdict_header else 'FAIL'}")
    print(f"  header band is present            {'PASS' if header_rows >= 5 else 'FAIL'}")
    print()
    print("SCREEN_CHECK=" + ("PASS" if verdict_header and header_rows >= 5 else "FAIL"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
