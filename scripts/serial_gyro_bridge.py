"""Forward real WireJac ESP32 gyro events from USB serial to the samples API."""

from __future__ import annotations

import json
import os
from pathlib import Path
import time
import urllib.error
import urllib.request

import serial


PORT = os.environ.get("WIREJAC_DEVICE_SELECTOR", "")
API_URL = os.environ.get("WIREJAC_SAMPLES_API_URL", "").rstrip("/")
API_KEY = os.environ.get("WIREJAC_API_KEY", "")
SESSION_ID = os.environ.get("WIREJAC_SESSION_ID", "training-001")
PAUSE_FILE = Path(
    os.environ.get(
        "WIREJAC_GYRO_BRIDGE_PAUSE_FILE",
        str(Path.home() / ".wirejac" / "gyro-bridge.pause"),
    )
).expanduser()


def gyro_bridge_paused() -> bool:
    return PAUSE_FILE.exists()


def post_sample(event: dict) -> None:
    payload = {
        "session_id": SESSION_ID,
        "device_id": "esp32-8c-aa-b5-8b-44-5c",
        "captured_at_ms": int(time.time() * 1000),
        "x": event["gyro_x"],
        "y": event["gyro_y"],
        "z": event["gyro_z"],
        "label": "gyro",
    }
    request = urllib.request.Request(
        API_URL + "/api/samples",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json", "X-Api-Key": API_KEY},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=10) as response:
        if response.status != 200:
            raise RuntimeError("samples API returned HTTP %d" % response.status)


def main() -> None:
    if not PORT or not API_URL or not API_KEY:
        raise RuntimeError(
            "WIREJAC_DEVICE_SELECTOR, WIREJAC_SAMPLES_API_URL, and WIREJAC_API_KEY are required"
        )
    print("WireJac gyro bridge connected; forwarding real motion.sample events")
    last_post = 0.0
    while True:
        if gyro_bridge_paused():
            time.sleep(0.2)
            continue
        try:
            with serial.Serial(PORT, 115200, timeout=0.2) as stream:
                stream.dtr = False
                stream.rts = False
                while not gyro_bridge_paused():
                    raw = stream.readline().decode("utf-8", errors="replace").strip()
                    if not raw.startswith("{"):
                        continue
                    try:
                        event = json.loads(raw)
                        if event.get("event") != "motion.sample":
                            continue
                        now = time.monotonic()
                        if now - last_post < 0.2:
                            continue
                        post_sample(event)
                        last_post = now
                        print(
                            "gyro x={:.2f} y={:.2f} z={:.2f}".format(
                                float(event["gyro_x"]),
                                float(event["gyro_y"]),
                                float(event["gyro_z"]),
                            )
                        )
                    except (KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
                        print("ignored invalid serial event: %s" % error)
                    except (OSError, urllib.error.URLError) as error:
                        print("samples API post failed: %s" % error)
        except (OSError, serial.SerialException) as error:
            print("serial bridge waiting: %s" % error)
            time.sleep(0.5)


if __name__ == "__main__":
    main()
