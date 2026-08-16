"""MQTT topic names.

The reading topics live under station/. The service topics live under mobilelab/.

Keeping them apart matters. The writer subscribes to station/# only. If the
writer published its own status under station/, it would read its own status
message back, fail to validate it, and count itself as a rejection forever.
"""

READINGS_WILDCARD = "station/#"
WRITER_STATUS = "mobilelab/writer/status"
