"""The GPS serial relay.

It owns the serial port, opens it once at a fixed 9600 8N1, and serves the bytes
to gpsd over a loopback TCP socket. gpsd is then configured with
`tcp://127.0.0.1:2948` instead of a device path.

WHY THIS EXISTS. IT IS NOT ARCHITECTURE FOR ITS OWN SAKE.

The receiver is a Prolific PL2303 dongle. Measured on this station, 2026-08-17:

    after a USB power cycle          26 valid NMEA sentences in 8 seconds
    after ONE 8N1 -> 8O1 -> 8N1      the port delivers nothing at all, and
    parity toggle                    pyserial raises "device reports readiness
                                     to read but returned no data"

    Recovery needs a USB unbind and rebind. Closing and reopening the port does
    not fix it. Restarting gpsd does not fix it.

That parity toggle is not a fault in anybody's code. It is what gpsd's packet
sniffer does to identify an unknown device: it hunts through speed, parity, and
stop-bit combinations until a packet parses. `-s 9600` pins the speed. It does
not stop the parity hunt, and `-b` only stops gpsd WRITING to the receiver,
which is a different thing again. gpsd sometimes syncs on the first 8N1 attempt
and works perfectly. Sometimes it toggles to 8O1 first, and then the receiver is
dead until the USB port is power cycled. That is the flapping this station
showed: clean for thirty seconds, then `packet sniffer failed sync` forever.

THE RELAY REMOVES THE HUNT BY REMOVING THE THING IT HUNTS ON.

A TCP socket has no baud rate, no parity, and no stop bits, so gpsd has nothing
to cycle. It reads bytes. The relay holds the only handle on the real device and
sets the line discipline exactly once, to the settings that were measured to
work, and never touches it again.

THE HONEST COST. This does not repair the dongle.

The dongle is still marginal, and a `-71 EPROTO` on the USB bus can still lose
bytes. What this buys is that nothing in the software will BREAK the receiver
any more. A corrupt sentence now fails its checksum and is dropped, the way a
corrupt sentence should be. Before this, the software itself was the thing
putting the receiver into a state it could not leave.

Replacing the PL2303 with a CP2102 or an FT232R remains the real fix. See
docs/MobileLab-Arch.md section 9.

=============================================================================
ACTIVE WORKAROUND FOR FAULTY HARDWARE. IT IS NOT A DESIGN. IT MUST BE REMOVED.
=============================================================================

This relay can hold the port at a NON-STANDARD speed. That ability exists for
exactly one reason, and the reason is a broken part.

    Measured on this station, 2026-08-17 and 2026-08-18. The PL2303 transmits
    about 8.5 percent fast. Read at the correct 9600 the station decodes
    NOTHING. Read at 10416 the same bytes decode cleanly, with a 3D fix on 8
    satellites.

    9600 is the CORRECT value. It is what a sound bridge uses and what the
    receiver is specified to send. Any other value is a workaround.

HOW IT IS SET. `MOBILELAB_GPS_BAUD` in .env. Nothing here is hardcoded.

    MOBILELAB_GPS_BAUD=9600     correct, and what a healthy bridge needs
    MOBILELAB_GPS_BAUD=10416    the workaround for THIS faulty dongle

WHEN THE CP2102 OR FT232R ARRIVES, set the value back to 9600 and restart the
relay. That is the whole removal. No code changes. If the value is not 9600,
this file logs a loud warning at every single start, so the workaround cannot
quietly become the permanent state of the station.

Tracked as an ACTIVE EXCEPTION in docs/MobileLab-Arch.md section 16.
"""

from __future__ import annotations

import argparse
import errno
import logging
import os
import selectors
import fcntl
import signal
import socket
import struct
import sys
import termios
import threading
import time
from types import FrameType

log = logging.getLogger("mobilelab.gpsrelay")

DEFAULT_DEVICE = "/dev/mobilelab-gps"

STANDARD_BAUD = 9600
"""What a NMEA 0183 receiver is supposed to use, and what a healthy bridge uses."""

BAUD_ENV = "MOBILELAB_GPS_BAUD"


def configured_baud() -> int:
    """Read the port speed from the environment. 9600 unless overridden.

    THE OVERRIDE EXISTS FOR ONE REASON AND IT IS A FAULT, NOT A FEATURE. See
    the WORKAROUND note at the top of this file. Swapping in a sound bridge is
    a change to .env, never a change to this file.
    """
    raw = os.environ.get(BAUD_ENV, "").strip()
    if not raw:
        return STANDARD_BAUD
    try:
        value = int(raw)
    except ValueError:
        log.error("%s is %r, which is not a number. Falling back to %d.",
                  BAUD_ENV, raw, STANDARD_BAUD)
        return STANDARD_BAUD
    if value <= 0:
        log.error("%s is %d, which is not a speed. Falling back to %d.",
                  BAUD_ENV, value, STANDARD_BAUD)
        return STANDARD_BAUD
    return value
DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 2948

READ_SIZE = 512
STALL_WARN_SECONDS = 30.0

BAUD_CONSTANTS = {
    4800: termios.B4800,
    9600: termios.B9600,
    19200: termios.B19200,
    38400: termios.B38400,
    57600: termios.B57600,
    115200: termios.B115200,
}

NCCS2 = 19
TERMIOS2_FMT = "4I" + "B" + str(NCCS2) + "B" + "2I"
TERMIOS2_SIZE = struct.calcsize(TERMIOS2_FMT)
CBAUD = 0o010017
BOTHER = 0o010000
STANDARD_SPEEDS = {4800: 0o14, 9600: 0o15, 19200: 0o16, 38400: 0o17}


def ioc(direction: int, letter: str, number: int, size: int) -> int:
    return (direction << 30) | (size << 16) | (ord(letter) << 8) | number


TCGETS2 = ioc(2, "T", 0x2A, TERMIOS2_SIZE)
TCSETS2 = ioc(1, "T", 0x2B, TERMIOS2_SIZE)


def do_ioctl(fd: int, request: int, buf: bytearray) -> None:
    try:
        fcntl.ioctl(fd, request, buf, True)
    except OverflowError:
        fcntl.ioctl(fd, request - (1 << 32), buf, True)


def configure_port_custom(fd: int, baud: int) -> int:
    """Set raw 8N1 at ANY speed, including one the standard table cannot name.

    It returns the speed the kernel reports back, which is not always the speed
    asked for. The PL2303 picks the nearest divisor it can make, so a request
    for 10400 comes back as 10416.

    PARENB is cleared here and it is never set again, exactly as the standard
    path does. Only the speed differs.
    """
    buf = bytearray(TERMIOS2_SIZE)
    do_ioctl(fd, TCGETS2, buf)
    values = list(struct.unpack(TERMIOS2_FMT, bytes(buf)))

    iflag, oflag, cflag, lflag = values[0], values[1], values[2], values[3]
    iflag &= ~(
        termios.IGNBRK | termios.BRKINT | termios.PARMRK | termios.ISTRIP
        | termios.INLCR | termios.IGNCR | termios.ICRNL | termios.IXON
        | termios.IXOFF | termios.IXANY
    )
    oflag &= ~termios.OPOST
    lflag &= ~(termios.ECHO | termios.ECHONL | termios.ICANON
               | termios.ISIG | termios.IEXTEN)
    cflag &= ~termios.CSIZE
    cflag |= termios.CS8
    cflag &= ~termios.PARENB
    cflag &= ~termios.CSTOPB
    cflag &= ~termios.CRTSCTS
    cflag |= termios.CREAD | termios.CLOCAL
    cflag &= ~CBAUD
    cflag |= STANDARD_SPEEDS.get(baud, BOTHER)

    values[0], values[1], values[2], values[3] = iflag, oflag, cflag, lflag
    values[5 + termios.VMIN] = 0
    values[5 + termios.VTIME] = 5
    values[24] = baud
    values[25] = baud

    do_ioctl(fd, TCSETS2, bytearray(struct.pack(TERMIOS2_FMT, *values)))

    check = bytearray(TERMIOS2_SIZE)
    actual = baud
    try:
        do_ioctl(fd, TCGETS2, check)
        actual = struct.unpack(TERMIOS2_FMT, bytes(check))[25]
    except OSError:
        pass
    termios.tcflush(fd, termios.TCIFLUSH)
    return actual


def configure_port(fd: int, baud: int) -> None:
    """Set 8N1 at the given speed, once, on an already open descriptor.

    Every flag is set explicitly. Nothing is left to whatever the last program
    to touch this port decided, because the last program to touch this port is
    exactly what broke it.

    PARENB is cleared here and never set again for the life of the process.
    """
    if baud not in BAUD_CONSTANTS:
        actual = configure_port_custom(fd, baud)
        log.info("set %s to %d baud by termios2. The kernel reports %d.",
                 "the port", baud, actual)
        return
    speed = BAUD_CONSTANTS[baud]

    iflag, oflag, cflag, lflag, ispeed, ospeed, cc = termios.tcgetattr(fd)

    iflag &= ~(
        termios.IGNBRK | termios.BRKINT | termios.PARMRK | termios.ISTRIP
        | termios.INLCR | termios.IGNCR | termios.ICRNL | termios.IXON
        | termios.IXOFF | termios.IXANY
    )
    oflag &= ~termios.OPOST
    lflag &= ~(termios.ECHO | termios.ECHONL | termios.ICANON | termios.ISIG | termios.IEXTEN)

    cflag &= ~termios.CSIZE
    cflag |= termios.CS8
    cflag &= ~termios.PARENB
    cflag &= ~termios.CSTOPB
    cflag &= ~termios.CRTSCTS
    cflag |= termios.CREAD | termios.CLOCAL

    cc[termios.VMIN] = 0
    cc[termios.VTIME] = 5

    termios.tcsetattr(
        fd, termios.TCSANOW, [iflag, oflag, cflag, lflag, speed, speed, cc]
    )
    termios.tcflush(fd, termios.TCIFLUSH)


class Relay:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.stopping = threading.Event()
        self.clients: list[socket.socket] = []
        self.bytes_in = 0
        self.last_data_at = time.monotonic()

    def stop(self, signum: int, frame: FrameType | None) -> None:
        log.info("signal %d received, stopping", signum)
        self.stopping.set()

    def open_device(self) -> int:
        fd = os.open(self.args.device, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        configure_port(fd, self.args.baud)
        log.info(
            "holding %s at %d 8N1. The parity is set once and never changed.",
            self.args.device,
            self.args.baud,
        )
        return fd

    def run(self) -> int:
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind((self.args.host, self.args.port))
        listener.listen(4)
        listener.setblocking(False)
        log.info("serving the receiver on tcp://%s:%d", self.args.host, self.args.port)

        try:
            fd = self.open_device()
        except OSError as exc:
            log.error("cannot open %s: %s", self.args.device, exc)
            return 1

        selector = selectors.DefaultSelector()
        selector.register(listener, selectors.EVENT_READ, "listen")
        selector.register(fd, selectors.EVENT_READ, "device")

        warned = False
        try:
            while not self.stopping.is_set():
                for key, _ in selector.select(timeout=1.0):
                    if key.data == "listen":
                        self._accept(listener)
                    else:
                        self._pump(fd)

                idle = time.monotonic() - self.last_data_at
                if idle > STALL_WARN_SECONDS and not warned:
                    log.error(
                        "no bytes from %s for %.0f seconds. The receiver has stopped "
                        "talking. If this persists, power cycle the USB port: "
                        "echo 3-2 > /sys/bus/usb/drivers/usb/unbind then bind.",
                        self.args.device,
                        idle,
                    )
                    warned = True
                elif idle <= STALL_WARN_SECONDS:
                    warned = False
        finally:
            selector.close()
            os.close(fd)
            for client in self.clients:
                client.close()
            listener.close()
        return 0

    def _accept(self, listener: socket.socket) -> None:
        try:
            client, address = listener.accept()
        except OSError:
            return
        client.setblocking(False)
        self.clients.append(client)
        log.info("gpsd connected from %s, %d client(s)", address, len(self.clients))

    def _pump(self, fd: int) -> None:
        try:
            chunk = os.read(fd, READ_SIZE)
        except OSError as exc:
            if exc.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                return
            log.error("read from %s failed: %s", self.args.device, exc)
            return
        if not chunk:
            return

        self.bytes_in += len(chunk)
        self.last_data_at = time.monotonic()

        alive = []
        for client in self.clients:
            try:
                client.sendall(chunk)
                alive.append(client)
            except OSError:
                log.info("a client went away")
                client.close()
        self.clients = alive


def announce_baud(baud: int) -> None:
    """Say the speed at every start, and shout when it is not the correct one.

    A workaround that is quiet becomes permanent. This one is not quiet.
    """
    if baud == STANDARD_BAUD:
        log.info("port speed %d baud, the standard NMEA 0183 rate. No workaround "
                 "is active.", baud)
        return
    log.warning("=" * 72)
    log.warning("HARDWARE WORKAROUND ACTIVE. THIS STATION IS NOT RUNNING NORMALLY.")
    log.warning("=" * 72)
    log.warning("port speed is %d baud. The correct rate is %d.", baud, STANDARD_BAUD)
    log.warning("")
    log.warning("WHY. The Prolific PL2303 bridge fitted to this station transmits")
    log.warning("about 8.5 percent fast. Read at %d the station decodes nothing.",
                STANDARD_BAUD)
    log.warning("Reading faster compensates for the fault. It does not repair it.")
    log.warning("")
    log.warning("THE RECEIVER IS NOT THE FAULT. The bridge is. A CP2102 or an")
    log.warning("FT232R is the real fix and one is on order.")
    log.warning("")
    log.warning("TO REMOVE THIS WORKAROUND, when the new bridge is fitted:")
    log.warning("  set %s=%d in .env", BAUD_ENV, STANDARD_BAUD)
    log.warning("  sudo systemctl restart mobilelab-gpsrelay.service")
    log.warning("This warning then stops by itself.")
    log.warning("")
    log.warning("Tracked as an ACTIVE EXCEPTION in docs/MobileLab-Arch.md section 16.")
    log.warning("=" * 72)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m mobilelab.gpsrelay",
        description="Own the GPS serial port and serve it to gpsd over TCP.",
    )
    parser.add_argument("--device", default=DEFAULT_DEVICE)
    parser.add_argument("--baud", type=int, default=None)
    parser.add_argument("--host", default=DEFAULT_HOST)
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    return parser


def main(argv: list[str] | None = None) -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
        stream=sys.stderr,
    )
    args = build_parser().parse_args(argv)
    if args.baud is None:
        args.baud = configured_baud()
    announce_baud(args.baud)
    relay = Relay(args)
    signal.signal(signal.SIGTERM, relay.stop)
    signal.signal(signal.SIGINT, relay.stop)
    return relay.run()


if __name__ == "__main__":
    raise SystemExit(main())
