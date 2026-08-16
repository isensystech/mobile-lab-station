"""Draw the boot splash.

It writes a full screen image for Plymouth, and a small bar image for the
progress indicator.

The station follows the same idea as the water quality logger. The logger plays
one pass of a branded animation, then hands off to its self test. This machine
shows one branded still, from the first moment the firmware allows, until the
kiosk paints.

The logger keeps a rule that matters more than the picture. Its fallback looks
DIFFERENT on purpose, so a missing asset is visible instead of hidden. The same
rule applies here. This script never invents a placeholder. If the lockup is
missing it stops and says so, and the boot then shows the plain Debian text.
Plain text at boot means the splash did not install.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

INK = (5, 42, 48)
TEAL = (8, 130, 140)
WHITE = (255, 255, 255)

FONT_CANDIDATES = [
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf",
]


def load_font(size: int) -> ImageFont.FreeTypeFont:
    for path in FONT_CANDIDATES:
        if Path(path).exists():
            return ImageFont.truetype(path, size)
    raise SystemExit(
        "STOP. No font was found. Looked for:\n  " + "\n  ".join(FONT_CANDIDATES)
    )


def build(lockup_path: Path, out_dir: Path, width: int, height: int) -> None:
    if not lockup_path.is_file():
        raise SystemExit(
            f"STOP. The brand lockup is missing at {lockup_path}.\n"
            "This script does not draw a substitute. A substitute would hide the\n"
            "fault. Install the lockup, then run this again."
        )

    canvas = Image.new("RGB", (width, height), INK)
    draw = ImageDraw.Draw(canvas)

    lockup = Image.open(lockup_path).convert("RGBA")
    target_w = int(width * 0.52)
    scale = target_w / lockup.width
    lockup = lockup.resize((target_w, max(1, int(lockup.height * scale))), Image.LANCZOS)

    lock_x = (width - lockup.width) // 2
    lock_y = int(height * 0.34) - lockup.height // 2
    canvas.paste(lockup, (lock_x, lock_y), lockup)

    product = "MOBILE LAB STATION"
    font = load_font(max(14, int(height * 0.047)))
    spaced = " ".join(product)
    box = draw.textbbox((0, 0), spaced, font=font)
    draw.text(
        ((width - (box[2] - box[0])) // 2, int(height * 0.50)),
        spaced,
        font=font,
        fill=WHITE,
    )

    rule_w = int(width * 0.30)
    rule_y = int(height * 0.60)
    draw.rectangle(
        [(width - rule_w) // 2, rule_y, (width + rule_w) // 2, rule_y + 2],
        fill=TEAL,
    )

    out_dir.mkdir(parents=True, exist_ok=True)
    splash = out_dir / "splash.png"
    canvas.save(splash, "PNG", optimize=True)

    bar = Image.new("RGB", (8, 6), TEAL)
    bar.save(out_dir / "bar.png", "PNG", optimize=True)

    track = Image.new("RGB", (8, 6), (18, 66, 74))
    track.save(out_dir / "track.png", "PNG", optimize=True)

    print(f"wrote {splash} at {width} by {height}")
    print(f"wrote {out_dir / 'bar.png'} and {out_dir / 'track.png'}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Draw the boot splash.")
    parser.add_argument("--lockup", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--width", type=int, default=1024)
    parser.add_argument("--height", type=int, default=600)
    args = parser.parse_args()
    build(args.lockup, args.out, args.width, args.height)
    return 0


if __name__ == "__main__":
    sys.exit(main())
