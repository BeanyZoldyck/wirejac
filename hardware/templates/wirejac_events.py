"""Structured device events shared by generated WireJac applications."""

import json
import time


def emit(event, **fields):
    payload = {
        "schema": "wirejac.device.event/v1",
        "event": event,
        "ts_ms": time.ticks_ms(),
    }
    payload.update(fields)
    print(json.dumps(payload))
    return payload

