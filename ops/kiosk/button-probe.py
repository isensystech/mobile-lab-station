"""Watch every input the Pi has, and report what a button press produces.

The question this answers: does the Pi see the screen's physical buttons at all?

A monitor button can reach the Pi in three ways, and this watches all three.

  1. A USB HID device, which appears in /dev/input.
  2. HDMI CEC, which the Pi presents as the vc4-hdmi keyboard devices.
  3. The Pi's own GPIO power button, which is not the monitor at all.

If nothing arrives when a button is pressed, the button is wired to the
monitor's own board. No software on the Pi can bind it, and saying otherwise
would be a guess dressed as a feature.
"""

from __future__ import annotations

import os
import select
import struct
import sys
import time
from pathlib import Path

EVENT_FORMAT = "llHHi"
EVENT_SIZE = struct.calcsize(EVENT_FORMAT)

EV_SYN = 0x00
EV_KEY = 0x01
EV_REL = 0x02
EV_ABS = 0x03
EV_MSC = 0x04
EV_SW = 0x05

TYPE_NAMES = {
    EV_SYN: "SYN",
    EV_KEY: "KEY",
    EV_REL: "REL",
    EV_ABS: "ABS",
    EV_MSC: "MSC",
    EV_SW: "SW",
}


def device_name(path: Path) -> str:
    sysfs = Path("/sys/class/input") / path.name / "device" / "name"
    try:
        return sysfs.read_text(encoding="utf-8").strip()
    except OSError:
        return "unknown"


def main() -> int:
    seconds = int(sys.argv[1]) if len(sys.argv) > 1 else 30

    devices: dict[int, tuple[str, str]] = {}
    handles = []
    for path in sorted(Path("/dev/input").glob("event*")):
        try:
            handle = open(path, "rb", buffering=0)
        except OSError as exc:
            print(f"  cannot open {path}: {exc}")
            continue
        os.set_blocking(handle.fileno(), False)
        handles.append(handle)
        devices[handle.fileno()] = (path.name, device_name(path))

    print(f"watching {len(handles)} input devices for {seconds} seconds")
    for name, label in sorted(devices.values()):
        print(f"  {name:<10} {label}")
    print()
    print("PRESS THE SCREEN BUTTONS NOW. Press each one, and wait a second between.")
    print()

    seen: dict[str, int] = {}
    deadline = time.monotonic() + seconds

    while time.monotonic() < deadline:
        remaining = deadline - time.monotonic()
        ready, _, _ = select.select(handles, [], [], min(0.5, max(remaining, 0)))
        for handle in ready:
            try:
                data = handle.read(EVENT_SIZE * 64)
            except OSError:
                continue
            if not data:
                continue
            node, label = devices[handle.fileno()]
            for offset in range(0, len(data) - EVENT_SIZE + 1, EVENT_SIZE):
                _, _, etype, code, value = struct.unpack(
                    EVENT_FORMAT, data[offset : offset + EVENT_SIZE]
                )
                if etype == EV_SYN:
                    continue
                kind = TYPE_NAMES.get(etype, str(etype))
                key = f"{node} {label}"
                seen[key] = seen.get(key, 0) + 1
                print(f"  EVENT  {node:<9} {label:<32} {kind} code={code} value={value}")

    print()
    print("================ RESULT ================")
    if not seen:
        print("NOTHING ARRIVED. The Pi saw no event from any device.")
    else:
        for key, count in sorted(seen.items(), key=lambda item: -item[1]):
            print(f"  {count:>5} events from {key}")
    print("========================================")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
