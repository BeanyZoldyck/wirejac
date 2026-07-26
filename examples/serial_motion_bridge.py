#!/usr/bin/env python3
"""Forward selected WireJac device JSON events from USB serial to HTTP.

This is the local test transport: the ESP32 talks to its sensors and emits
events, while the host bridge performs the HTTP request. It does not claim to
exercise the ESP32 Wi-Fi stack.
"""

from __future__ import annotations

import argparse
from collections.abc import Callable
import json
import sys
from typing import Any, Protocol
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import Request, urlopen


DEFAULT_SERVER_URL = "http://127.0.0.1:8787/events"
DEFAULT_BAUD = 115200
DEFAULT_TIMEOUT_S = 1.0
MAX_LINE_BYTES = 16 * 1024
MAX_DRAIN_BYTES = 1024 * 1024
FORWARDED_EVENTS = frozenset(
    {
        "motion.sample",
        "snatch.detected",
        "sensor.detected",
        "wirejac.ready",
        "wirejac.heartbeat",
    }
)
FORWARDED_PREFIXES = ("recording.", "button.")


class SerialReader(Protocol):
    def read_until(self, expected: bytes = b"\n", size: int | None = None) -> bytes: ...


class OversizedSerialLine(ValueError):
    """Raised after an oversized serial line has been discarded."""


def validate_server_url(value: str) -> str:
    if len(value) > 2048:
        raise ValueError("server URL is too long")
    parsed = urlsplit(value)
    if parsed.scheme not in {"http", "https"}:
        raise ValueError("server URL must use http or https")
    if not parsed.hostname or parsed.username or parsed.password:
        raise ValueError("server URL must have a host and no embedded credentials")
    if parsed.fragment:
        raise ValueError("server URL must not include a fragment")
    return value


def should_forward(payload: dict[str, Any]) -> bool:
    event = payload.get("event")
    return isinstance(event, str) and (
        event in FORWARDED_EVENTS or event.startswith(FORWARDED_PREFIXES)
    )


def parse_device_line(line: bytes) -> dict[str, Any] | None:
    try:
        payload = json.loads(line.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None
    return payload if isinstance(payload, dict) else None


def _discard_line(serial_port: SerialReader, already_read: int) -> None:
    discarded = already_read
    while discarded < MAX_DRAIN_BYTES:
        chunk = serial_port.read_until(expected=b"\n", size=MAX_LINE_BYTES + 1)
        discarded += len(chunk)
        if not chunk or chunk.endswith(b"\n"):
            return
    reset = getattr(serial_port, "reset_input_buffer", None)
    if callable(reset):
        reset()


def read_device_line(
    serial_port: SerialReader,
    *,
    max_line_bytes: int = MAX_LINE_BYTES,
) -> bytes | None:
    if max_line_bytes < 1 or max_line_bytes > MAX_LINE_BYTES:
        raise ValueError(f"max_line_bytes must be between 1 and {MAX_LINE_BYTES}")
    line = serial_port.read_until(expected=b"\n", size=max_line_bytes + 1)
    if not line:
        return None
    if len(line) > max_line_bytes or not line.endswith(b"\n"):
        _discard_line(serial_port, len(line))
        raise OversizedSerialLine(
            f"discarded serial line larger than {max_line_bytes} bytes"
        )
    return line.rstrip(b"\r\n")


def post_event(
    server_url: str,
    payload: dict[str, Any],
    *,
    timeout_s: float = 5.0,
) -> int:
    url = validate_server_url(server_url)
    body = json.dumps(
        payload,
        ensure_ascii=True,
        separators=(",", ":"),
        allow_nan=False,
    ).encode("utf-8")
    if len(body) > MAX_LINE_BYTES:
        raise ValueError("encoded event exceeds the bridge payload limit")
    request = Request(
        url,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urlopen(request, timeout=timeout_s) as response:
            response.read(16 * 1024)
            return response.status
    except HTTPError as error:
        error.read(16 * 1024)
        raise RuntimeError(f"event server rejected the request: HTTP {error.code}") from error
    except URLError as error:
        raise RuntimeError(f"could not reach event server: {error.reason}") from error


def run_bridge(
    serial_port: SerialReader,
    server_url: str,
    *,
    poster: Callable[[str, dict[str, Any]], int] = post_event,
) -> None:
    validate_server_url(server_url)
    while True:
        try:
            line = read_device_line(serial_port)
        except OversizedSerialLine as error:
            print(f"warning: {error}", file=sys.stderr)
            continue
        if line is None:
            continue
        payload = parse_device_line(line)
        if payload is None or not should_forward(payload):
            continue
        event = payload["event"]
        try:
            status = poster(server_url, payload)
        except (RuntimeError, TypeError, ValueError) as error:
            print(f"forward failed for {event}: {error}", file=sys.stderr)
            continue
        print(f"forwarded {event}: HTTP {status}")


def open_serial(port: str, baud: int, timeout_s: float):
    try:
        import serial
    except ImportError as error:
        raise RuntimeError(
            "pyserial is required; run this through the WireJac Jac environment"
        ) from error
    try:
        return serial.Serial(port=port, baudrate=baud, timeout=timeout_s)
    except serial.SerialException as error:
        raise RuntimeError(f"could not open serial port {port}: {error}") from error


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--port",
        required=True,
        help="explicit serial path, preferably /dev/serial/by-id/...",
    )
    parser.add_argument("--baud", type=int, default=DEFAULT_BAUD)
    parser.add_argument("--server-url", default=DEFAULT_SERVER_URL)
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT_S)
    args = parser.parse_args(argv)
    if args.baud < 1:
        parser.error("--baud must be positive")
    if args.timeout <= 0 or args.timeout > 30:
        parser.error("--timeout must be between 0 and 30 seconds")
    try:
        validate_server_url(args.server_url)
    except ValueError as error:
        parser.error(str(error))
    return args


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        serial_port = open_serial(args.port, args.baud, args.timeout)
    except RuntimeError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    print(
        f"Reading WireJac events from {args.port} at {args.baud} baud; "
        f"posting to {args.server_url}"
    )
    try:
        with serial_port:
            run_bridge(serial_port, args.server_url)
    except KeyboardInterrupt:
        print("Stopping serial bridge")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
