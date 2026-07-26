"""Run from host RAM before a release is activated."""

import json
import machine
import os

payload = {
    "schema": "wirejac.device.event/v1",
    "event": "wirejac.smoke_passed",
    "device_id": machine.unique_id().hex(),
    "filesystem_root": os.listdir("/"),
}
print(json.dumps(payload))

