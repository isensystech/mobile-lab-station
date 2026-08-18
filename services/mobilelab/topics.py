"""MQTT topic names.

The reading topics live under station/. The service topics live under mobilelab/.

Keeping them apart matters. The writer subscribes to station/# only. If the
writer published its own status under station/, it would read its own status
message back, fail to validate it, and count itself as a rejection forever.
"""

READINGS_WILDCARD = "station/#"
WRITER_STATUS = "mobilelab/writer/status"

# The GPS status is RETAINED, so a browser that loads after the driver spoke
# still gets the current state instead of a blank indicator.
#
# Retained also means a dead driver leaves its last words on the broker. The
# payload therefore carries reported_at, and the API ages it. A stale status is
# RED. See services/mobilelab/gps.py.
GPS_STATUS = "mobilelab/gps/status"
