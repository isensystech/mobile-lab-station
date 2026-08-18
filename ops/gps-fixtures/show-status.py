"""Print one GPS status message from MQTT in one readable line.

install-gps.sh pipes a retained status into this. It exists as a file because
the same thing written inline needed four levels of shell quoting and broke.
"""

import json
import sys

try:
    status = json.load(sys.stdin)
except Exception as exc:
    print(f"    could not read the status: {exc}")
    raise SystemExit(0)

print(f"    state={status.get('state')} label={status.get('label')}")
print(f"    {status.get('detail')}")
fix = status.get("fix") or {}
print(
    f"    fix={fix.get('mode_text')} "
    f"satellites seen={fix.get('satellites_seen')} used={fix.get('satellites_used')}"
)
print(f"    device={status.get('device')} simulated={status.get('simulated')}")
