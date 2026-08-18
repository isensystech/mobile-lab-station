"""Count valid, invalid, and undecodable NMEA sentences on stdin.

IT READS BYTES, NOT TEXT, AND THAT IS THE WHOLE POINT.

The first version decoded stdin as UTF-8 and crashed with a UnicodeDecodeError
the moment the receiver produced a corrupt byte. Corrupt bytes are exactly what
this receiver produces when it decays, so the check died on the one condition it
exists to measure, and took the gate down with it instead of reporting a number.

A verification tool must survive the fault it is looking for.
"""

import re
import sys

SENTENCE = re.compile(rb"\$(G[PNLA][A-Z]{3},[ -~]*?)\*([0-9A-Fa-f]{2})")

raw = sys.stdin.buffer.read()

ok = bad = 0
for match in SENTENCE.finditer(raw):
    body, want = match.group(1), match.group(2)
    got = 0
    for byte in body:
        got ^= byte
    if got == int(want, 16):
        ok += 1
    else:
        bad += 1

# Bytes that are not printable ASCII cannot be part of a valid sentence. They
# are the signature of this dongle's decay, so they are counted and reported
# rather than silently dropped.
noise = sum(1 for byte in raw if byte not in (10, 13) and not 32 <= byte <= 126)

print(f"{ok} {bad} {noise} {len(raw)}")
