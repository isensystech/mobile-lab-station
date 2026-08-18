#!/usr/bin/env python3
"""The GPS bridge soak. One shot. Diagnostic only.

WHAT THIS MEASURES, AND WHY IT IS NOT THE SAME AS verify-gps.sh

The PL2303 bridge on this station shows a drifting byte clock. Measured indoors
on 2026-08-17: the receiver is clean for about twenty seconds after a USB power
cycle, then decays to unreadable, while the BYTE RATE stays constant. Read at
9600 the yield collapses. Read at 10000 and 10400 valid sentences still arrive.
That is a transmit clock near six percent fast. UART tolerance is about two
percent.

That indoor run had a confound. weather-collector.service was writing Modbus
frames into the same port every two seconds. It is disabled now. This soak
measures the decay again with the confound gone, outdoors, where the bridge runs
warmer.

THE TEMPERATURE COLUMN IS THE POINT OF DOING THIS OUTSIDE.

A crystal that drifts as it warms is the leading hypothesis. This script records
a board temperature beside every bucket so the two can be looked at together.
It does NOT declare a correlation. One run cannot support that claim.

WHAT THIS SCRIPT DOES NOT DO

It does not unbind the USB port. It does not power cycle the dongle. A power
cycle resets the decay, and the decay is the thing under measurement.

It does not change the relay, the driver, the indicator, or any application
code. It reads the port and it writes a text file.

It never sets the parity bit. gpsd's parity hunt is what bricked this dongle
once already. This script writes PARENB to zero on the first configuration and
every later configuration keeps it at zero. Only the speed changes.

HOW A BUCKET IS SPENT

Each bucket is sixty seconds of wall clock:

    40.0 s   at 9600, the production speed. This is the primary window.
     9.5 s   at 10000.
     9.5 s   at 10400.
     back to 9600, then wait for the minute boundary.

The rates are reported per second, so the different window lengths compare. The
speed change costs a fraction of a second of bytes at each boundary. The input
queue is flushed after every change to drop the bytes that were sampled across
it.
"""

from __future__ import annotations

import argparse
import errno
import fcntl
import json
import os
import platform
import re
import select
import socket
import struct
import subprocess
import sys
import termios
import time
from datetime import datetime

DEFAULT_DEVICE = "/dev/mobilelab-gps"
DEFAULT_OUTDIR = "/var/log/mobilelab/gps-soak"
DEFAULT_BUCKETS = 25
DEFAULT_BUCKET_SECONDS = 60

PRIMARY_BAUD = 9600
PROBE_BAUDS = (10000, 10400)

READ_SIZE = 4096
SETTLE_SECONDS = 0.25

NCCS2 = 19
TERMIOS2_FMT = "4I" + "B" + str(NCCS2) + "B" + "2I"
TERMIOS2_SIZE = struct.calcsize(TERMIOS2_FMT)

IOC_READ = 2
IOC_WRITE = 1

CBAUD = 0o010017
BOTHER = 0o010000
STANDARD_SPEEDS = {4800: 0o14, 9600: 0o15, 19200: 0o16, 38400: 0o17}
CLASSIC_SPEEDS = {
    4800: termios.B4800, 9600: termios.B9600,
    19200: termios.B19200, 38400: termios.B38400,
}

TABLE_COLUMNS = (
    ("MIN", 3), ("CLOCK", 5), ("TEMPC", 5), ("CPU%", 5), ("BYTE/S", 6),
    ("SENT/S", 6), ("BADMN", 5), ("FIX", 3), ("SAT", 3),
    ("9600", 5), ("10000", 5), ("10400", 5), ("BEST", 5), ("USB", 3),
)

USB_PATTERN = re.compile(
    r"usb|xhci|pl2303|ttyUSB|EPROTO|ENODEV|-71|-32|-110|"
    r"device descriptor|disconnect|over-?current|reset (?:high|full|low)-speed",
    re.IGNORECASE,
)


def ioc(direction: int, letter: str, number: int, size: int) -> int:
    """Build a Linux ioctl request number the asm-generic way."""
    return (direction << 30) | (size << 16) | (ord(letter) << 8) | number


TCGETS2 = ioc(IOC_READ, "T", 0x2A, TERMIOS2_SIZE)
TCSETS2 = ioc(IOC_WRITE, "T", 0x2B, TERMIOS2_SIZE)


def do_ioctl(fd: int, request: int, buf: bytearray) -> None:
    """Call ioctl, and retry with the signed form if the request overflows."""
    try:
        fcntl.ioctl(fd, request, buf, True)
    except OverflowError:
        fcntl.ioctl(fd, request - (1 << 32), buf, True)


def now_iso() -> str:
    return datetime.now().astimezone().strftime("%Y-%m-%dT%H:%M:%S%z")


def uptime_seconds() -> float:
    try:
        with open("/proc/uptime", "r", encoding="ascii") as handle:
            return float(handle.read().split()[0])
    except OSError:
        return -1.0


class Port:
    """The serial port, held open for the whole run, speed changed in place."""

    def __init__(self, device: str) -> None:
        self.device = device
        self.fd = -1
        self.speed_supported: dict[int, bool] = {}
        self.speed_actual: dict[int, int] = {}
        self.speed_method: dict[int, str] = {}
        self.open_error = ""

    def open(self) -> bool:
        self.close()
        try:
            self.fd = os.open(self.device, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        except OSError as exc:
            self.fd = -1
            self.open_error = f"{errno.errorcode.get(exc.errno, exc.errno)} {exc.strerror}"
            return False
        self.open_error = ""
        return self.set_speed(PRIMARY_BAUD) >= 0

    def close(self) -> None:
        if self.fd >= 0:
            try:
                os.close(self.fd)
            except OSError:
                pass
        self.fd = -1

    def set_speed(self, baud: int) -> int:
        """Set raw 8N1 at the given speed. Return the speed the kernel reports.

        It tries the termios2 path first. That is the only path that can carry
        a speed the standard table does not name, so 10000 and 10400 need it.

        IF THE DRIVER REFUSES termios2 IT FALLS BACK TO PLAIN tcsetattr for the
        speeds the standard table does name. THAT FALLBACK IS NOT DECORATION.
        Without it, one refused ioctl costs the whole run, including the 9600
        window the soak exists to measure, and the one shot is spent. With it,
        only the probe columns are lost, and the report says they were lost.

        Return -1 when both paths fail. The parity bit is written to zero here
        and it is never written to anything else.
        """
        if self.fd < 0:
            return -1
        actual = self.set_termios2(baud)
        method = "termios2"
        if actual < 0 and baud in STANDARD_SPEEDS:
            actual = self.set_classic(baud)
            method = "termios"
        if actual < 0:
            self.speed_supported[baud] = False
            self.speed_actual[baud] = -1
            self.speed_method[baud] = "refused"
            return -1
        self.speed_supported[baud] = True
        self.speed_actual[baud] = actual
        self.speed_method[baud] = method
        try:
            termios.tcflush(self.fd, termios.TCIFLUSH)
        except termios.error:
            pass
        return actual

    @staticmethod
    def raw_flags(iflag: int, oflag: int, cflag: int, lflag: int) -> tuple:
        """The same line discipline the relay sets. Nothing is left to chance."""
        iflag &= ~(
            termios.IGNBRK | termios.BRKINT | termios.PARMRK | termios.ISTRIP
            | termios.INLCR | termios.IGNCR | termios.ICRNL | termios.IXON
            | termios.IXOFF | termios.IXANY
        )
        oflag &= ~termios.OPOST
        lflag &= ~(
            termios.ECHO | termios.ECHONL | termios.ICANON
            | termios.ISIG | termios.IEXTEN
        )
        cflag &= ~termios.CSIZE
        cflag |= termios.CS8
        cflag &= ~termios.PARENB
        cflag &= ~termios.CSTOPB
        cflag &= ~termios.CRTSCTS
        cflag |= termios.CREAD | termios.CLOCAL
        return iflag, oflag, cflag, lflag

    def set_termios2(self, baud: int) -> int:
        buf = bytearray(TERMIOS2_SIZE)
        try:
            do_ioctl(self.fd, TCGETS2, buf)
        except OSError:
            return -1

        values = list(struct.unpack(TERMIOS2_FMT, bytes(buf)))
        iflag, oflag, cflag, lflag = self.raw_flags(
            values[0], values[1], values[2], values[3]
        )
        cflag &= ~CBAUD
        cflag |= STANDARD_SPEEDS.get(baud, BOTHER)

        values[0], values[1], values[2], values[3] = iflag, oflag, cflag, lflag
        values[5 + termios.VMIN] = 0
        values[5 + termios.VTIME] = 5
        values[24] = baud
        values[25] = baud

        try:
            do_ioctl(self.fd, TCSETS2, bytearray(struct.pack(TERMIOS2_FMT, *values)))
        except (OSError, struct.error):
            return -1

        check = bytearray(TERMIOS2_SIZE)
        try:
            do_ioctl(self.fd, TCGETS2, check)
            return struct.unpack(TERMIOS2_FMT, bytes(check))[25]
        except OSError:
            return baud

    def set_classic(self, baud: int) -> int:
        """The ordinary tcsetattr path. Standard speeds only."""
        constant = CLASSIC_SPEEDS.get(baud)
        if constant is None:
            return -1
        try:
            iflag, oflag, cflag, lflag, _, _, cc = termios.tcgetattr(self.fd)
        except termios.error:
            return -1
        iflag, oflag, cflag, lflag = self.raw_flags(iflag, oflag, cflag, lflag)
        cc[termios.VMIN] = 0
        cc[termios.VTIME] = 5
        try:
            termios.tcsetattr(
                self.fd, termios.TCSANOW,
                [iflag, oflag, cflag, lflag, constant, constant, cc],
            )
        except termios.error:
            return -1
        return baud

    def read_window(self, seconds: float) -> tuple[bytes, str]:
        """Read for the given time. Return the bytes and any device error."""
        if self.fd < 0:
            time.sleep(seconds)
            return b"", "the port is not open"
        chunks: list[bytes] = []
        error = ""
        end = time.monotonic() + seconds
        while True:
            remaining = end - time.monotonic()
            if remaining <= 0:
                break
            try:
                ready, _, _ = select.select([self.fd], [], [], min(remaining, 0.5))
            except OSError as exc:
                error = f"select failed: {exc.strerror}"
                break
            if not ready:
                continue
            try:
                data = os.read(self.fd, READ_SIZE)
            except OSError as exc:
                if exc.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                    continue
                error = f"{errno.errorcode.get(exc.errno, exc.errno)} {exc.strerror}"
                break
            if data:
                chunks.append(data)
        if error:
            left = end - time.monotonic()
            if left > 0:
                time.sleep(left)
        return b"".join(chunks), error


def parse_stream(raw: bytes) -> dict:
    """Count sentences and read the fix out of the ones that validate.

    A START is any run of bytes on a line from the last dollar sign onward. A
    start that does not validate is counted as BAD, whether its checksum
    disagreed or the sentence never formed at all. Under a drifting byte clock
    most corrupt sentences never form, so counting only checksum disagreements
    would under-report the damage.
    """
    starts = valid = mismatch = malformed = 0
    gsa_mode = 0
    gga_quality = 0
    gga_sats = -1
    gsa_sats = -1

    for line in raw.split(b"\n"):
        dollar = line.rfind(b"$")
        if dollar < 0:
            continue
        line = line[dollar:].rstrip(b"\r\x00 \t")
        starts += 1
        star = line.rfind(b"*")
        if star < 1 or len(line) - star < 3:
            malformed += 1
            continue
        body = line[1:star]
        try:
            want = int(line[star + 1:star + 3], 16)
        except ValueError:
            malformed += 1
            continue
        got = 0
        for byte in body:
            got ^= byte
        if got != want:
            mismatch += 1
            continue
        valid += 1

        try:
            text = body.decode("ascii")
        except UnicodeDecodeError:
            continue
        fields = text.split(",")
        head = fields[0]
        kind = head[2:5] if len(head) >= 5 else head

        if kind == "GGA" and len(fields) > 7:
            if fields[6].isdigit():
                gga_quality = max(gga_quality, int(fields[6]))
            if fields[7].isdigit():
                gga_sats = max(gga_sats, int(fields[7]))
        elif kind == "GSA" and len(fields) > 2:
            if fields[2].isdigit():
                gsa_mode = max(gsa_mode, int(fields[2]))
            used = [prn for prn in fields[3:15] if prn.strip()]
            gsa_sats = max(gsa_sats, len(used))

    if gsa_mode == 3:
        fix = "3D"
    elif gsa_mode == 2:
        fix = "2D"
    elif gga_quality > 0:
        fix = "FX"
    else:
        fix = "--"

    sats = gga_sats if gga_sats >= 0 else gsa_sats
    return {
        "bytes": len(raw),
        "starts": starts,
        "valid": valid,
        "mismatch": mismatch,
        "malformed": malformed,
        "bad": mismatch + malformed,
        "fix": fix,
        "gsa_mode": gsa_mode,
        "gga_quality": gga_quality,
        "sats": sats if sats >= 0 else 0,
        "sats_known": sats >= 0,
    }


def read_temperatures() -> dict:
    """Read every kernel thermal zone. There is no sensor on the dongle."""
    zones = {}
    try:
        names = sorted(os.listdir("/sys/class/thermal"))
    except OSError:
        return zones
    for name in names:
        if not name.startswith("thermal_zone"):
            continue
        base = os.path.join("/sys/class/thermal", name)
        try:
            with open(os.path.join(base, "temp"), "r", encoding="ascii") as handle:
                milli = int(handle.read().strip())
            with open(os.path.join(base, "type"), "r", encoding="ascii") as handle:
                kind = handle.read().strip()
        except (OSError, ValueError):
            continue
        zones[f"{name}:{kind}"] = round(milli / 1000.0, 1)
    return zones


def cpu_snapshot() -> tuple[int, int]:
    try:
        with open("/proc/stat", "r", encoding="ascii") as handle:
            parts = handle.readline().split()
    except OSError:
        return 0, 0
    numbers = [int(value) for value in parts[1:] if value.isdigit()]
    if len(numbers) < 4:
        return 0, 0
    total = sum(numbers)
    idle = numbers[3] + (numbers[4] if len(numbers) > 4 else 0)
    return total - idle, total


def load_average() -> float:
    try:
        with open("/proc/loadavg", "r", encoding="ascii") as handle:
            return float(handle.read().split()[0])
    except (OSError, ValueError):
        return -1.0


def throttled_flag() -> str:
    if not os.path.exists("/usr/bin/vcgencmd"):
        return ""
    try:
        out = subprocess.run(
            ["/usr/bin/vcgencmd", "get_throttled"],
            capture_output=True, text=True, timeout=5, check=False,
        )
        return out.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


class DmesgWatcher:
    """Take the whole kernel ring each minute and keep only the new lines."""

    def __init__(self) -> None:
        self.seen: set[str] = set()
        self.form = ""
        self.error = ""

    def dump(self) -> list[str]:
        forms = [
            ["dmesg", "--time-format=iso"],
            ["dmesg", "-T"],
            ["dmesg"],
        ]
        if self.form:
            forms = [self.form.split(" ")]
        for command in forms:
            try:
                out = subprocess.run(
                    command, capture_output=True, text=True, timeout=20, check=False
                )
            except (OSError, subprocess.SubprocessError) as exc:
                self.error = str(exc)
                continue
            if out.returncode == 0:
                self.form = " ".join(command)
                self.error = ""
                return out.stdout.splitlines()
            self.error = out.stderr.strip() or f"dmesg exit {out.returncode}"
        return []

    def prime(self) -> None:
        self.seen = set(self.dump())

    def new_usb_lines(self) -> list[str]:
        found = []
        for line in self.dump():
            if line in self.seen:
                continue
            self.seen.add(line)
            if USB_PATTERN.search(line):
                found.append(line)
        return found


def run_soak(args: argparse.Namespace) -> int:
    os.makedirs(args.outdir, exist_ok=True)
    buckets_path = os.path.join(args.outdir, "buckets.jsonl")
    session_path = os.path.join(args.outdir, "session.json")

    primary_seconds = args.bucket_seconds * 2.0 / 3.0
    probe_seconds = (args.bucket_seconds - primary_seconds - 3 * SETTLE_SECONDS) / 2.0
    if probe_seconds < 2.0:
        primary_seconds = max(2.0, args.bucket_seconds - 3 * SETTLE_SECONDS - 4.0)
        probe_seconds = max(
            1.0, (args.bucket_seconds - primary_seconds - 3 * SETTLE_SECONDS) / 2.0
        )

    port = Port(args.device)
    opened = port.open()
    watcher = DmesgWatcher()
    watcher.prime()

    session = {
        "started": now_iso(),
        "started_epoch": time.time(),
        "uptime_at_start": round(uptime_seconds(), 1),
        "hostname": socket.gethostname(),
        "device": args.device,
        "device_real": os.path.realpath(args.device),
        "device_opened": opened,
        "device_open_error": port.open_error,
        "planned_buckets": args.buckets,
        "bucket_seconds": args.bucket_seconds,
        "primary_seconds": round(primary_seconds, 2),
        "probe_seconds": round(probe_seconds, 2),
        "primary_baud": PRIMARY_BAUD,
        "probe_bauds": list(PROBE_BAUDS),
        "kernel": platform.release(),
        "arch": platform.machine(),
        "python": platform.python_version(),
        "dmesg_form": watcher.form,
        "dmesg_error": watcher.error,
        "throttled_at_start": throttled_flag(),
        "temps_at_start": read_temperatures(),
        "speed_actual": {},
        "finished": "",
        "completed_buckets": 0,
    }
    with open(session_path, "w", encoding="utf-8") as handle:
        json.dump(session, handle, indent=2)

    with open(buckets_path, "w", encoding="utf-8") as handle:
        handle.write("")

    print(f"soak: reading {args.device} for {args.buckets} buckets", flush=True)
    if not opened:
        print(f"soak: WARNING the port did not open: {port.open_error}", flush=True)

    completed = 0
    run_start = time.monotonic()
    for index in range(1, args.buckets + 1):
        record = {
            "minute": index,
            "start": now_iso(),
            "start_epoch": round(time.time(), 3),
            "uptime": round(uptime_seconds(), 1),
            "temps_start": read_temperatures(),
            "windows": {},
            "device_error": "",
            "reopened": False,
        }
        cpu_busy_start, cpu_total_start = cpu_snapshot()

        if port.fd < 0 and args.reopen:
            record["reopened"] = port.open()

        plan = [(PRIMARY_BAUD, primary_seconds)]
        plan += [(baud, probe_seconds) for baud in PROBE_BAUDS]

        for baud, seconds in plan:
            actual = port.set_speed(baud)
            if actual < 0:
                record["windows"][str(baud)] = {
                    "supported": False, "seconds": 0.0, "actual_baud": -1,
                }
                time.sleep(seconds)
                continue
            time.sleep(SETTLE_SECONDS)
            try:
                if port.fd >= 0:
                    termios.tcflush(port.fd, termios.TCIFLUSH)
            except termios.error:
                pass
            raw, error = port.read_window(seconds)
            counts = parse_stream(raw)
            counts["supported"] = True
            counts["seconds"] = round(seconds, 2)
            counts["actual_baud"] = actual
            counts["bytes_per_second"] = round(counts["bytes"] / seconds, 1)
            counts["valid_per_second"] = round(counts["valid"] / seconds, 2)
            counts["bad_per_minute"] = round(counts["bad"] / seconds * 60.0, 1)
            record["windows"][str(baud)] = counts
            if error:
                record["device_error"] = error

        port.set_speed(PRIMARY_BAUD)

        if record["device_error"] and args.reopen:
            record["reopened"] = port.open()

        cpu_busy_end, cpu_total_end = cpu_snapshot()
        total_delta = cpu_total_end - cpu_total_start
        record["cpu_percent"] = (
            round((cpu_busy_end - cpu_busy_start) / total_delta * 100.0, 1)
            if total_delta > 0 else -1.0
        )
        record["load1"] = load_average()
        record["temps_end"] = read_temperatures()
        record["temp_max"] = max(record["temps_end"].values()) if record["temps_end"] else -1.0
        record["throttled"] = throttled_flag()
        record["dmesg"] = watcher.new_usb_lines()

        with open(buckets_path, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(record) + "\n")
        completed = index

        best = pick_best(record)
        print(
            f"soak: minute {index:2d}/{args.buckets}  "
            f"temp {record['temp_max']}C  "
            f"9600 {value_of(record, PRIMARY_BAUD, 'valid_per_second')}/s  "
            f"best {best}",
            flush=True,
        )

        remaining = (run_start + index * args.bucket_seconds) - time.monotonic()
        if remaining > 0 and index < args.buckets:
            time.sleep(remaining)

    port.close()
    session["finished"] = now_iso()
    session["completed_buckets"] = completed
    session["speed_actual"] = {str(k): v for k, v in port.speed_actual.items()}
    session["speed_supported"] = {str(k): v for k, v in port.speed_supported.items()}
    session["speed_method"] = {str(k): v for k, v in port.speed_method.items()}
    session["temps_at_end"] = read_temperatures()
    session["throttled_at_end"] = throttled_flag()
    with open(session_path, "w", encoding="utf-8") as handle:
        json.dump(session, handle, indent=2)

    print(f"soak: finished {completed} buckets", flush=True)
    return 0


def value_of(record: dict, baud: int, key: str, default="n/a"):
    window = record.get("windows", {}).get(str(baud), {})
    if not window.get("supported"):
        return default
    return window.get(key, default)


def pick_best(record: dict) -> str:
    """Name the speed with the most valid sentences per second this minute."""
    best_baud = ""
    best_rate = -1.0
    for baud in (PRIMARY_BAUD,) + PROBE_BAUDS:
        window = record.get("windows", {}).get(str(baud), {})
        if not window.get("supported"):
            continue
        rate = float(window.get("valid_per_second", 0.0))
        if rate > best_rate:
            best_rate = rate
            best_baud = str(baud)
    if best_rate <= 0.0:
        return "none"
    return best_baud


def read_buckets(outdir: str) -> list[dict]:
    path = os.path.join(outdir, "buckets.jsonl")
    records = []
    try:
        with open(path, "r", encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    records.append(json.loads(line))
                except ValueError:
                    continue
    except OSError:
        return []
    return records


def read_session(outdir: str) -> dict:
    try:
        with open(os.path.join(outdir, "session.json"), "r", encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return {}


def read_runlog(outdir: str) -> tuple[list[str], dict]:
    path = os.path.join(outdir, "run.log")
    lines: list[str] = []
    facts: dict[str, str] = {}
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            lines = handle.read().splitlines()
    except OSError:
        return [], {}
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("FACT ") and "=" in stripped:
            key, _, value = stripped[5:].partition("=")
            facts[key.strip()] = value.strip()
    return lines, facts


def indoor_note(repo_root: str) -> tuple[str, list[str]]:
    """Quote the indoor numbers from the box. Never reconstruct them."""
    path = os.path.join(repo_root, "ops", "verify-gps.sh")
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            source = handle.read().splitlines()
    except OSError:
        return "", []

    quoted: list[str] = []
    capturing = False
    for line in source:
        if "HARDWARE NOTE:" in line:
            capturing = True
        if capturing and "CONSEQUENCE." in line:
            break
        if not capturing:
            continue
        text = line.strip()
        if text.startswith('echo "') and text.endswith('"'):
            quoted.append(text[6:-1])
        elif text == "echo":
            quoted.append("")
    if not quoted:
        return "", []
    return path, quoted


def fmt(value, spec: str, blank: str = "n/a") -> str:
    if value is None or value == "n/a" or value == -1 or value == -1.0:
        return blank
    try:
        return format(value, spec)
    except (TypeError, ValueError):
        return blank


def render(args: argparse.Namespace) -> int:
    session = read_session(args.outdir)
    records = read_buckets(args.outdir)
    log_lines, facts = read_runlog(args.outdir)
    out: list[str] = []
    add = out.append

    planned = int(session.get("planned_buckets", DEFAULT_BUCKETS) or DEFAULT_BUCKETS)
    primary_seconds = float(session.get("primary_seconds", 40.0) or 40.0)
    probe_seconds = float(session.get("probe_seconds", 9.5) or 9.5)

    add("=" * 78)
    add("GPS BRIDGE SOAK. ONE SHOT. DIAGNOSTIC ONLY.")
    add("=" * 78)
    add("")
    add(f"  station          {session.get('hostname', 'unknown')}")
    add(f"  receiver         {session.get('device', DEFAULT_DEVICE)} -> "
        f"{session.get('device_real', 'unknown')}")
    add(f"  started          {session.get('started', 'unknown')}")
    add(f"  finished         {session.get('finished') or 'the run did not report an end'}")
    add(f"  boot to start    {fmt(session.get('uptime_at_start'), '.0f')} s")
    add(f"  buckets          {len(records)} written, {planned} planned")
    add(f"  bucket plan      {primary_seconds:.1f} s at 9600, "
        f"{probe_seconds:.1f} s at 10000, {probe_seconds:.1f} s at 10400")
    add(f"  kernel           {session.get('kernel', 'unknown')} "
        f"{session.get('arch', '')}")
    add(f"  rendered         {now_iso()}")
    add("")
    add("  THIS RUN CHANGED NOTHING. It did not unbind the USB port. It did not")
    add("  power cycle the dongle. A power cycle resets the decay, and the decay")
    add("  is the thing under measurement. It did not change the relay, the")
    add("  driver, the indicator, or any application code.")
    add("")
    add("  IT NEVER SET THE PARITY BIT. The parity bit went to zero at the first")
    add("  configuration and stayed at zero. Only the speed changed.")
    add("")

    add("-" * 78)
    add("CONDITIONS")
    add("-" * 78)
    add("")
    if facts:
        order = [
            ("fired_by", "how it started"),
            ("boot_id", "boot id"),
            ("weather_collector_active", "weather-collector running"),
            ("weather_collector_enabled", "weather-collector enabled"),
            ("relay_before", "mobilelab-gpsrelay before"),
            ("relay_stopped", "mobilelab-gpsrelay during"),
            ("other_holders", "other programs on the port"),
            ("gpsd_state", "gpsd during"),
            ("relay_after", "mobilelab-gpsrelay after"),
            ("driver_after", "mobilelab-gps after"),
            ("armed_after", "soak unit after"),
            ("marker", "one shot marker"),
        ]
        for key, label in order:
            if key in facts:
                add(f"  {label:<32} {facts[key]}")
    else:
        add("  The run log is missing. The wrapper did not record the conditions.")
    add("")
    if facts.get("weather_collector_active", "no") != "no":
        add("  WARNING. weather-collector was RUNNING during this soak. It writes")
        add("  Modbus frames into the same port. This run is confounded. The")
        add("  numbers below do not answer the question this soak was built for.")
        add("")

    supported = session.get("speed_supported", {})
    actual = session.get("speed_actual", {})
    method = session.get("speed_method", {})
    add("  SPEEDS THE KERNEL ACCEPTED")
    for baud in (PRIMARY_BAUD,) + PROBE_BAUDS:
        key = str(baud)
        if supported.get(key) is True:
            add(f"    {baud:<6} accepted, the driver reports {actual.get(key, '?')} baud, "
                f"set by {method.get(key, '?')}")
        elif supported.get(key) is False:
            add(f"    {baud:<6} REFUSED by the driver. That column reads n/a.")
        else:
            add(f"    {baud:<6} not recorded")
    add("")

    add("-" * 78)
    add("PER MINUTE")
    add("-" * 78)
    add("")
    caption_at = sum(width + 1 for _, width in TABLE_COLUMNS[:9])
    add(" " * caption_at + "valid sentences per second")
    add(" ".join(f"{label:>{width}}" for label, width in TABLE_COLUMNS))
    add("-" * (sum(width for _, width in TABLE_COLUMNS) + len(TABLE_COLUMNS) - 1))

    for record in records:
        clock = record.get("start", "")[11:16] or "--:--"
        primary = record.get("windows", {}).get(str(PRIMARY_BAUD), {})
        cells = (
            record.get("minute", "?"),
            clock,
            fmt(record.get("temp_max"), ".1f", "--"),
            fmt(record.get("cpu_percent"), ".1f", "--"),
            fmt(primary.get("bytes_per_second"), ".0f", "--") if primary.get("supported") else "n/a",
            fmt(primary.get("valid_per_second"), ".2f", "--") if primary.get("supported") else "n/a",
            fmt(primary.get("bad_per_minute"), ".0f", "--") if primary.get("supported") else "n/a",
            primary.get("fix", "--") if primary.get("supported") else "n/a",
            primary.get("sats", 0) if primary.get("supported") else "n/a",
            fmt(value_of(record, PRIMARY_BAUD, "valid_per_second"), ".2f", "n/a"),
            fmt(value_of(record, 10000, "valid_per_second"), ".2f", "n/a"),
            fmt(value_of(record, 10400, "valid_per_second"), ".2f", "n/a"),
            pick_best(record),
            len(record.get("dmesg", [])),
        )
        add(" ".join(
            f"{str(cell):>{width}}"
            for cell, (_, width) in zip(cells, TABLE_COLUMNS)
        ))
    if not records:
        add("  no buckets were written")
    add("")

    add("  HOW TO READ THE COLUMNS")
    add(f"    TEMPC   the hottest kernel thermal zone, in Celsius. This is the")
    add(f"            BOARD, not the dongle. No sensor exists on the dongle.")
    add(f"    CPU%    busy time across all cores for the whole minute.")
    add(f"    BYTE/S  bytes arriving per second in the {primary_seconds:.0f} s window at 9600.")
    add(f"    SENT/S  sentences that passed their checksum, per second, at 9600.")
    add(f"    BADMN   sentence starts that did NOT validate, scaled to a minute")
    add(f"            from the {primary_seconds:.0f} s window at 9600. A start is any dollar")
    add(f"            sign on a line. It counts a wrong checksum and a sentence")
    add(f"            that never formed, because a drifting byte clock mostly")
    add(f"            produces the second kind.")
    add( "    FIX     the best fix seen in the minute at 9600. 3D, 2D, FX, --.")
    add( "            FX means GGA claimed a fix and GSA never said which kind.")
    add( "    SAT     the most satellites USED in the minute, from GGA field 7.")
    add(f"    9600    valid sentences per second in each speed window. The 9600")
    add(f"    10000   figure is the same number as SENT/S. The probes each get")
    add(f"    10400   {probe_seconds:.1f} s, so they are noisier. Compare the shape, not one row.")
    add( "    BEST    the speed with the most valid sentences that minute.")
    add( "    USB     kernel USB lines in that minute. They are listed below.")
    add("")

    return finish_report(args, out, session, records, facts, log_lines, planned)


def mean(values: list[float]) -> float:
    return sum(values) / len(values) if values else 0.0


def pearson(xs: list[float], ys: list[float]) -> float:
    """Plain Pearson r. It describes one run. It establishes nothing."""
    if len(xs) < 5 or len(xs) != len(ys):
        return 2.0
    mx, my = mean(xs), mean(ys)
    top = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    left = sum((x - mx) ** 2 for x in xs)
    right = sum((y - my) ** 2 for y in ys)
    if left <= 0 or right <= 0:
        return 2.0
    return top / (left * right) ** 0.5


def finish_report(args, out, session, records, facts, log_lines, planned) -> int:
    add = out.append

    usable = [
        record for record in records
        if record.get("windows", {}).get(str(PRIMARY_BAUD), {}).get("supported")
    ]
    rates = [
        float(record["windows"][str(PRIMARY_BAUD)]["valid_per_second"])
        for record in usable
    ]
    temps = [
        float(record.get("temp_max", -1.0)) for record in usable
    ]

    first_unreadable = None
    for record in usable:
        if float(record["windows"][str(PRIMARY_BAUD)]["valid_per_second"]) <= 0.0:
            first_unreadable = record
            break

    stayed_dead = False
    if first_unreadable is not None:
        tail = [
            record for record in usable
            if record["minute"] >= first_unreadable["minute"]
        ]
        stayed_dead = all(
            float(record["windows"][str(PRIMARY_BAUD)]["valid_per_second"]) <= 0.0
            for record in tail
        )

    add("-" * 78)
    add("THE MINUTE THE STREAM BECAME UNREADABLE")
    add("-" * 78)
    add("")
    add("  UNREADABLE means zero sentences passed a checksum in that minute's")
    add("  9600 window. Scott can disagree with that definition. The raw counts")
    add(f"  are in {os.path.join(args.outdir, 'buckets.jsonl')}.")
    add("")
    if not usable:
        add("  NO ANSWER. No minute produced a usable 9600 window.")
    elif first_unreadable is None:
        add("  IT NEVER BECAME UNREADABLE.")
        add(f"  Every one of the {len(usable)} minutes carried valid sentences at 9600.")
        add(f"  The lowest minute held {min(rates):.2f} sentences per second.")
        add(f"  The highest minute held {max(rates):.2f} sentences per second.")
    else:
        add(f"  MINUTE {first_unreadable['minute']}, clock "
            f"{first_unreadable.get('start', '')[11:19]}.")
        add(f"  Board temperature at that minute: {first_unreadable.get('temp_max')} C.")
        add(f"  Bytes still arriving at that minute: "
            f"{first_unreadable['windows'][str(PRIMARY_BAUD)].get('bytes_per_second')} per second.")
        if stayed_dead:
            add("  It stayed unreadable for the rest of the run.")
        else:
            add("  It RECOVERED later. The stream came back without any help.")
            add("  That is new. The indoor run needed a USB rebind to recover.")
    add("")

    add("-" * 78)
    add("THE DRIFT MEASUREMENT")
    add("-" * 78)
    add("")
    add("  A transmitter whose clock is fast puts more bits per second on the")
    add("  wire than the receiver expects. A receiver set faster then samples")
    add("  the bits closer to their centre and reads more of them correctly.")
    add("  So a run where 10000 or 10400 beats 9600 is a fast transmit clock.")
    add("  10000 is 4.2 percent above 9600. 10400 is 8.3 percent above.")
    add("")
    probes_ran = any(
        record.get("windows", {}).get(str(baud), {}).get("supported")
        for record in records for baud in PROBE_BAUDS
    )
    if not probes_ran:
        add("  NO DRIFT MEASUREMENT WAS MADE. The kernel refused the custom")
        add("  speeds on this driver, so 10000 and 10400 were never read. Every")
        add("  probe column reads n/a. This gap is not a result. It is a hole.")
    else:
        wins = [record for record in records if pick_best(record) in ("10000", "10400")]
        ties = [record for record in records if pick_best(record) == "9600"]
        dead = [record for record in records if pick_best(record) == "none"]
        add(f"  minutes where 9600 read best                 {len(ties)}")
        add(f"  minutes where a faster speed won             {len(wins)}")
        add(f"  minutes with no valid sentence at any speed  {len(dead)}")
        add("")
        if wins:
            add(f"  A faster speed first won at minute {wins[0]['minute']}, "
                f"clock {wins[0].get('start','')[11:19]},")
            add(f"  board temperature {wins[0].get('temp_max')} C.")
            add("  THE BYTE CLOCK IS FAST. That is the same failure the indoor run")
            add("  found, and weather-collector was not running for this one.")
        else:
            add("  9600 read best in every minute that read at all. This run did")
            add("  NOT reproduce the fast byte clock. Either the fault needs the")
            add("  confound that is now removed, or it did not appear today.")
    add("")

    add("-" * 78)
    add("TEMPERATURE")
    add("-" * 78)
    add("")
    add("  THERE IS NO SENSOR ON THE DONGLE. Every temperature here is the Pi")
    add("  board. The dongle sits in the same air and shares no heat path with")
    add("  the SoC. Treat the column as ambient warm-up, not as crystal")
    add("  temperature.")
    add("")
    good_temps = [(t, r) for t, r in zip(temps, rates) if t > 0]
    if len(good_temps) >= 2:
        add(f"  first minute       {good_temps[0][0]:.1f} C")
        add(f"  last minute        {good_temps[-1][0]:.1f} C")
        add(f"  coldest            {min(t for t, _ in good_temps):.1f} C")
        add(f"  hottest            {max(t for t, _ in good_temps):.1f} C")
        add(f"  rise over the run  {good_temps[-1][0] - good_temps[0][0]:+.1f} C")
        add("")
        r = pearson([t for t, _ in good_temps], [v for _, v in good_temps])
        if r > 1.5:
            add("  Too few minutes carried both numbers to describe a relation.")
        else:
            add(f"  Pearson r between board temperature and valid sentences per")
            add(f"  second at 9600: {r:+.2f}, over {len(good_temps)} minutes.")
            add("")
            if r <= -0.6:
                add("  THE YIELD FELL AS THE BOARD WARMED, in this run. That is")
                add("  consistent with a crystal that drifts with warm-up.")
            elif r >= 0.6:
                add("  THE YIELD ROSE AS THE BOARD WARMED, in this run. That")
                add("  points AWAY from warm-up drift.")
            else:
                add("  NO STRONG RELATION APPEARS in this run. The yield did not")
                add("  track the board temperature either way.")
            add("")
            add("  READ THAT NUMBER NARROWLY. This is ONE run. Temperature rose")
            add("  monotonically and time also passed, so anything that decays")
            add("  with time correlates with it. This number cannot separate the")
            add("  two, and it is not evidence of a mechanism. To separate them,")
            add("  run the soak again from cold at a different ambient, or cool")
            add("  the dongle mid-run and watch for a step change.")
    else:
        add("  No usable temperatures were recorded.")
    add("")

    add("-" * 78)
    add("USB ERRORS FROM THE KERNEL")
    add("-" * 78)
    add("")
    total_usb = sum(len(record.get("dmesg", [])) for record in records)
    if session.get("dmesg_error"):
        add(f"  dmesg did not run cleanly: {session['dmesg_error']}")
        add("")
    if total_usb == 0:
        add("  NONE. The kernel logged no USB line during the window.")
        add("  The indoor run also found none. A transport that loses packets")
        add("  logs them. A byte clock that drifts does not.")
    else:
        plural = "line" if total_usb == 1 else "lines"
        add(f"  {total_usb} {plural}. The kernel timestamp is on each one.")
        add("")
        for record in records:
            for line in record.get("dmesg", []):
                add(f"  min {record['minute']:>2}  {line}")
    add("")

    add("-" * 78)
    add("RESTORE PROOF")
    add("-" * 78)
    add("")
    add("  The soak stopped mobilelab-gpsrelay to take the port. It must give")
    add("  the port back. This is that proof, taken after the last bucket.")
    add("")
    restore_path = os.path.join(args.outdir, "restore.txt")
    try:
        with open(restore_path, "r", encoding="utf-8", errors="replace") as handle:
            for line in handle.read().splitlines():
                add(f"  {line}")
    except OSError:
        add("  THE RESTORE PROOF IS MISSING. Check the relay by hand:")
        add("    systemctl status mobilelab-gpsrelay.service")
    add("")

    add("-" * 78)
    add("AGAINST THE EARLIER INDOOR RUN")
    add("-" * 78)
    add("")
    path, note = indoor_note(args.repo_root)
    if not note:
        add("  THE INDOOR NUMBERS ARE NOT ON THIS BOX.")
        add("  ops/verify-gps.sh does not carry the hardware note, and no other")
        add("  record of that run was found. Nothing is reconstructed from")
        add("  memory here. Compare by hand if you have the numbers elsewhere.")
    else:
        add(f"  Quoted from {path}. These are the numbers as written, not from")
        add("  memory.")
        add("")
        for line in note:
            add(f"  | {line}")
        add("")
        add("  WHAT IS COMPARABLE, AND WHAT IS NOT")
        add("")
        add("  The indoor run used five second buckets over about thirty seconds.")
        add("  This run uses sixty second buckets over twenty five minutes. The")
        add("  sentence counts do not line up. The BYTE RATE and the SHAPE of the")
        add("  decay do.")
        add("")
        add("  The indoor note records near 1100 bytes per 5 seconds. That is 220")
        add("  bytes per second. The arithmetic is mine. The 1100 is theirs.")
        if usable:
            first = usable[0]["windows"][str(PRIMARY_BAUD)]
            add(f"  This run, minute 1: {first.get('bytes_per_second')} bytes per second, "
                f"{first.get('valid')} valid")
            add(f"  sentences in the {first.get('seconds')} s window.")
            if len(usable) > 1:
                last = usable[-1]["windows"][str(PRIMARY_BAUD)]
                add(f"  This run, minute {usable[-1]['minute']}: "
                    f"{last.get('bytes_per_second')} bytes per second, "
                    f"{last.get('valid')} valid.")
        add("")
        add("  The indoor run reached zero valid sentences by about 25 seconds.")
        if first_unreadable is not None:
            add(f"  This run reached zero at minute {first_unreadable['minute']}.")
        elif usable:
            add("  This run never reached zero in 25 minutes.")
    add("")

    add("=" * 78)
    add("VERDICT: DOES THE DECAY STILL HAPPEN WITH weather-collector DISABLED?")
    add("=" * 78)
    add("")
    wc_active = facts.get("weather_collector_active", "unknown")
    if wc_active not in ("no", "unknown"):
        add("  THIS RUN CANNOT ANSWER IT. weather-collector was running. The")
        add("  confound the soak exists to remove was present. Stop that unit and")
        add("  run the soak again.")
    elif wc_active == "unknown":
        add("  THE ANSWER IS WEAK. The wrapper did not record whether")
        add("  weather-collector was running, so the confound is not ruled out.")
    elif not usable:
        add("  NO ANSWER. The port gave nothing to measure.")
    elif first_unreadable is not None:
        add("  YES. THE DECAY STILL HAPPENS.")
        add("")
        add(f"  weather-collector was not running. The stream still fell to zero")
        add(f"  valid sentences at minute {first_unreadable['minute']}. The other")
        add("  program on the port was never the cause of this. The bridge is.")
        add("")
        add("  SWAP THE BRIDGE. A CP2102 or an FT232R costs a few dollars and")
        add("  does not have this failure. Keep the relay either way, because")
        add("  gpsd's parity hunt is a separate fault that the relay prevents.")
    else:
        opening = mean(rates[:max(1, len(rates) // 3)])
        closing = mean(rates[-max(1, len(rates) // 3):])
        add(f"  NO. NOT IN THIS RUN.")
        add("")
        add(f"  The stream never fell to zero across {len(usable)} minutes.")
        add(f"  First third of the run: {opening:.2f} valid sentences per second.")
        add(f"  Last third of the run:  {closing:.2f} valid sentences per second.")
        add("")
        if closing < opening * 0.5:
            add("  IT STILL DEGRADED. The yield more than halved. The decay is")
            add("  slower without weather-collector, and it did not stop.")
        elif closing < opening * 0.9:
            add("  It fell a little. That is within what a changing sky can do to")
            add("  a receiver. It is not the indoor collapse.")
        else:
            add("  IT HELD. Twenty five minutes with no collapse is a different")
            add("  machine from the one measured indoors.")
        add("")
        add("  DO NOT CLEAR THE BRIDGE ON THIS ALONE. One run outdoors with one")
        add("  sky is not proof that the bridge is well. Run it a second time")
        add("  before the swap is cancelled.")
    add("")

    add("-" * 78)
    add("GATES")
    add("-" * 78)
    add("")
    fired = facts.get("fired_by", "")
    uptime = session.get("uptime_at_start", -1)
    gate1 = "PASS" if fired == "systemd-boot" else "CHECK"
    add(f"  1 fires on boot with no typing          {gate1}")
    add(f"      the wrapper reports fired_by={fired or 'nothing'}, and the soak")
    add(f"      began {fmt(uptime, '.0f')} seconds after boot.")
    add( "      BLIND SPOT: this proves the unit ran on THIS boot. It does not")
    add( "      prove the unit would run on a boot where the USB device is slow")
    add( "      to enumerate. The unit waits on the device unit, and that wait")
    add( "      was never tested against a slow enumeration.")
    add("")
    gate2 = "PASS" if facts.get("marker") == "present" and facts.get("armed_after") in ("disabled", "static") else "CHECK"
    add(f"  2 disables itself after one run         {gate2}")
    add(f"      marker={facts.get('marker', 'unknown')}, "
        f"unit is {facts.get('armed_after', 'unknown')} after the run.")
    add( "      BLIND SPOT: only a second reboot proves this. This line reports")
    add( "      the state the wrapper left behind. Scott must reboot again and")
    add( "      confirm the unit stayed quiet.")
    add("")
    gate3 = "PASS" if facts.get("relay_after") == "active" else "FAIL"
    add(f"  3 mobilelab-gpsrelay is running at the end  {gate3}")
    add(f"      relay_before={facts.get('relay_before', '?')}, "
        f"relay_after={facts.get('relay_after', '?')}")
    add( "      BLIND SPOT: an active unit is not a working indicator. systemd")
    add( "      reports the process, not the fix. Only Scott's eyes on the badge")
    add( "      close this one.")
    add("")
    gate4 = "PASS" if len(records) >= planned else "FAIL"
    add(f"  4 the report covers {planned} buckets           {gate4}")
    add(f"      {len(records)} buckets written of {planned} planned.")
    add( "      BLIND SPOT: a full count is not a full measurement. A bucket")
    add( "      whose port was shut still counts as a bucket. Read the n/a cells")
    add( "      in the table before trusting the count.")
    add("")

    if log_lines:
        add("-" * 78)
        add("THE WRAPPER LOG, IN FULL")
        add("-" * 78)
        add("")
        for line in log_lines:
            add(f"  {line}")
        add("")

    text = "\n".join(out) + "\n"
    if args.out:
        with open(args.out, "w", encoding="utf-8") as handle:
            handle.write(text)
        try:
            os.chmod(args.out, 0o644)
        except OSError:
            pass
    if args.print_report or not args.out:
        sys.stdout.write(text)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="gps-soak.py",
        description="Measure the GPS bridge for 25 minutes. Diagnostic only.",
    )
    parser.add_argument("mode", choices=["run", "render"])
    parser.add_argument("--device", default=DEFAULT_DEVICE)
    parser.add_argument("--outdir", default=DEFAULT_OUTDIR)
    parser.add_argument("--buckets", type=int, default=DEFAULT_BUCKETS)
    parser.add_argument("--bucket-seconds", type=int, default=DEFAULT_BUCKET_SECONDS)
    parser.add_argument("--no-reopen", dest="reopen", action="store_false")
    parser.add_argument("--out", default="")
    parser.add_argument("--print-report", action="store_true")
    parser.add_argument(
        "--repo-root",
        default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.mode == "run":
        return run_soak(args)
    return render(args)


if __name__ == "__main__":
    raise SystemExit(main())
