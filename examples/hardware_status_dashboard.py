#!/usr/bin/env python3
"""Live ESP32 wiring dashboard for the WireJac motion-test circuit."""

from __future__ import annotations

import argparse
from collections import deque
import json
import queue
import subprocess
import sys
import threading
import time


DEFAULT_PORT = "/dev/serial/by-id/usb-Silicon_Labs_CP2102_USB_to_UART_Bridge_Controller_0001-if00-port0"
DEFAULT_MPREMOTE = "/home/mason/.local/bin/jac"

PROBE = r'''import json
import time
from machine import I2C, Pin

button = Pin(19, Pin.IN, Pin.PULL_UP)
i2c = None

def signed(high, low):
    value = (high << 8) | low
    return value - 65536 if value & 0x8000 else value

while True:
    result = {"button": button.value(), "scan": [], "who": None, "accel": None, "gyro": None}
    try:
        if i2c is None:
            i2c = I2C(0, sda=Pin(21), scl=Pin(22), freq=100000)
        result["scan"] = i2c.scan()
        if 104 in result["scan"]:
            result["who"] = i2c.readfrom_mem(104, 117, 1)[0]
            # Wake the MPU6050 before reading its output registers.
            i2c.writeto_mem(104, 107, b"\x00")
            time.sleep_ms(10)
            raw = i2c.readfrom_mem(104, 59, 14)
            result["accel"] = [round(signed(raw[0], raw[1]) / 16384, 3), round(signed(raw[2], raw[3]) / 16384, 3), round(signed(raw[4], raw[5]) / 16384, 3)]
            result["gyro"] = [round(signed(raw[8], raw[9]) / 131, 2), round(signed(raw[10], raw[11]) / 131, 2), round(signed(raw[12], raw[13]) / 131, 2)]
    except Exception as error:
        result["error"] = str(error)
        i2c = None
    print("WJPROBE " + json.dumps(result))
    time.sleep_ms(300)
'''


def parse_probe_line(line: str) -> dict[str, object] | None:
    if not line.startswith("WJPROBE "):
        return None
    try:
        value = json.loads(line[8:])
    except json.JSONDecodeError:
        return None
    return value if isinstance(value, dict) else None


def _reader(stream, output: queue.Queue[str]) -> None:
    for line in iter(stream.readline, ""):
        output.put(line.rstrip())


def _status(value: bool, good: str = "OK", bad: str = "CHECK") -> str:
    return good if value else bad


def render(probe: dict[str, object] | None, recent: deque[str], port: str) -> str:
    scan = probe.get("scan", []) if probe else []
    found = isinstance(scan, list) and 104 in scan
    button = probe.get("button") if probe else None
    lines = [
        "WIREJAC ESP32 MOTION WIRING",
        "=" * 32,
        f"USB:       CONNECTED  {port}",
        f"I2C bus:   {_status(found, 'OK', 'NO DEVICE')}  scan={scan}",
        f"GY-521:    {_status(found, 'FOUND @ 0x68', 'MISSING')}",
        f"WHO_AM_I:  {probe.get('who') if probe else '---'}",
        f"BUTTON19:  {'PRESSED / LOW' if button == 0 else 'RELEASED / HIGH' if button == 1 else '---'}",
        f"ACCEL (g): {probe.get('accel') if found else '---'}",
        f"GYRO (d/s):{probe.get('gyro') if found else '---'}",
        "",
    ]
    if not found:
        lines.extend([
            "CHECK: GY-521 VCC -> 3V3",
            "CHECK: GY-521 GND -> GND",
            "CHECK: SDA -> GPIO21, SCL -> GPIO22",
        ])
    if button == 0:
        lines.append("CHECK: GPIO19 is grounded; release button or inspect orientation")
    else:
        lines.append("BUTTON WIRING: signal GPIO19, other side GND")
    lines.extend(["", "Recent serial output:"])
    lines.extend(f"  {line[:120]}" for line in list(recent)[-4:])
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", default=DEFAULT_PORT)
    parser.add_argument("--mpremote", default=DEFAULT_MPREMOTE)
    args = parser.parse_args(argv)
    command = [args.mpremote, "-m", "mpremote", "connect", args.port, "exec", PROBE]
    try:
        process = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
    except OSError as error:
        print(f"Could not start mpremote: {error}", file=sys.stderr)
        return 2
    assert process.stdout is not None
    output: queue.Queue[str] = queue.Queue()
    threading.Thread(target=_reader, args=(process.stdout, output), daemon=True).start()
    recent: deque[str] = deque(maxlen=12)
    latest: dict[str, object] | None = None
    try:
        while process.poll() is None:
            try:
                line = output.get(timeout=0.3)
                recent.append(line)
                parsed = parse_probe_line(line)
                if parsed is not None:
                    latest = parsed
            except queue.Empty:
                pass
            print("\033[2J\033[H" + render(latest, recent, args.port), flush=True)
    except KeyboardInterrupt:
        pass
    finally:
        process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
