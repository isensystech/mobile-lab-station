# udev rules

## `70-mobilelab-gps.rules`

Gives the GPS receiver a stable name, and keeps other software off it.

### Why the rule exists

The receiver is a Prolific PL2303 USB-serial dongle. The kernel called it
`/dev/ttyUSB0` on the day it was fitted. That name is not a property of the
dongle. It is the order things were found in.

This already caused one fault on this station. `weather-collector.service`
hardcodes `RS485_PORT = "/dev/ttyUSB0"` for a DFRobot SEN0658 that is not
plugged in. With the sensor absent, that service opened the GPS receiver
instead, wrote Modbus frames into it every two seconds, and consumed its NMEA
output. Every baud probe returned corrupt data until the service was stopped.
Nothing was broken. Two programs simply agreed on a name that names nothing.

The rule replaces the name with three facts that ARE properties of the hardware.

### What each part does

| Part | Reason |
|---|---|
| `ATTRS{idVendor}=="067b"`, `ATTRS{idProduct}=="2303"` | It is a PL2303. |
| `ENV{ID_PATH}=="platform-xhci-hcd.1-usb-0:2:1.0"` | It is in THAT physical socket. |
| `SYMLINK+="mobilelab-gps"` | `/dev/mobilelab-gps` always means the receiver. |
| `ENV{ID_MM_DEVICE_IGNORE}="1"` | ModemManager stops probing it. |
| `ENV{SYSTEMD_WANTS}="gpsd.service"` | Plugging it in starts gpsd. |

### The number 70 is load bearing

The rule was written as `60-mobilelab-gps.rules` first, and it did nothing at
all. `ID_PATH` is not a property udev knows about a device. It is computed by
the `path_id` builtin, and that builtin runs from `60-serial.rules`. udev reads
rule files in filename order, so at 60 the names tie and `mobilelab` sorts
before `serial`. The rule was tested against an `ID_PATH` that had not been set
yet, matched nothing, and failed silently, which is how udev fails.

At 70 it runs after `60-serial.rules`, and `ID_PATH` has a value. Do not
renumber it below 60-serial without moving the match to something udev knows
earlier, such as `KERNELS`.

Confirm ordering with `udevadm test /sys/class/tty/ttyUSB0`.

### The USB socket is part of the match, and that is deliberate

The dongle reports **no serial number**. `/dev/serial/by-id/` therefore holds one
entry with no unique part in it, so a second PL2303 would collide with the first.
The RS485 dongle for the SEN0658 may well be another PL2303, which makes that
collision likely rather than theoretical.

The physical socket is the only thing left that separates two identical chips.

**This is a trade, and the cost is real.** Move the GPS dongle to a different USB
socket and the symlink does not appear. The receiver is fine, the cable is fine,
and the station says `NO GPS`. `ops/verify-gps.sh` gate 1 prints the socket it
expects, so the check names the cause instead of leaving it to be guessed.

If the station is rebuilt with a different USB layout, read the new value with:

```
udevadm info -q property -n /dev/ttyUSB0 | grep ID_PATH=
```

Then edit the rule, and run `sudo ops/install-gps.sh` again.
