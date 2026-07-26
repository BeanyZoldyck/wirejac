"""Minimal A/B release loader for WireJac-managed MicroPython devices."""

import gc
import json
import os
import sys
import time

ACTIVE_FILE = "/config/active"
PREVIOUS_FILE = "/config/previous"
FAILURES_FILE = "/config/boot_failures.json"
MAX_FAILURES = 2


def _emit(event, **fields):
    payload = {
        "schema": "wirejac.device.event/v1",
        "event": event,
        "ts_ms": time.ticks_ms(),
    }
    payload.update(fields)
    print(json.dumps(payload))


def _read_text(path, default=""):
    try:
        with open(path, "r") as handle:
            return handle.read().strip()
    except OSError:
        return default


def _read_failures():
    try:
        with open(FAILURES_FILE, "r") as handle:
            value = json.loads(handle.read())
            return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def _write_failures(failures):
    try:
        os.mkdir("/config")
    except OSError:
        pass
    with open(FAILURES_FILE, "w") as handle:
        handle.write(json.dumps(failures))


def _load_slot(slot):
    release_path = "/releases/" + slot
    if release_path not in sys.path:
        sys.path.insert(0, release_path)
    if "app" in sys.modules:
        del sys.modules["app"]
    module = __import__("app")
    module.run()


def boot():
    active = _read_text(ACTIVE_FILE, "A")
    previous = _read_text(PREVIOUS_FILE, "B" if active == "A" else "A")
    failures = _read_failures()
    candidates = [active]
    if previous != active:
        candidates.append(previous)

    for slot in candidates:
        if failures.get(slot, 0) >= MAX_FAILURES:
            continue
        try:
            gc.collect()
            _emit("wirejac.booting", slot=slot)
            _load_slot(slot)
            return
        except Exception as exc:
            failures[slot] = failures.get(slot, 0) + 1
            _write_failures(failures)
            _emit(
                "wirejac.boot_failed",
                slot=slot,
                error_type=exc.__class__.__name__,
                error=str(exc),
            )

    _emit("wirejac.recovery_required", active=active, previous=previous)
    while True:
        time.sleep(1)

