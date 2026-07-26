from __future__ import annotations

from collections import deque
from http.client import HTTPConnection
import json
from pathlib import Path
import threading

import pytest

from examples.motion_test_server import MAX_BODY_BYTES, build_server, parse_args
from examples.serial_motion_bridge import (
    OversizedSerialLine,
    parse_device_line,
    read_device_line,
    run_bridge,
    should_forward,
    validate_server_url,
)


class FakeSerial:
    def __init__(self, chunks: list[bytes]) -> None:
        self.chunks = deque(chunks)
        self.reset_count = 0

    def read_until(self, expected: bytes = b"\n", size: int | None = None) -> bytes:
        if not self.chunks:
            raise KeyboardInterrupt
        chunk = self.chunks.popleft()
        return chunk if size is None else chunk[:size]

    def reset_input_buffer(self) -> None:
        self.reset_count += 1
        self.chunks.clear()


@pytest.fixture
def motion_server(tmp_path: Path):
    server = build_server("127.0.0.1", 0, log_path=tmp_path / "events.ndjson")
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


def request(server, method: str, path: str, body: bytes | None = None, **headers):
    connection = HTTPConnection(*server.server_address[:2], timeout=2)
    connection.request(method, path, body=body, headers=headers)
    response = connection.getresponse()
    data = response.read()
    connection.close()
    return response.status, json.loads(data)


def test_server_defaults_to_loopback_and_accepts_bounded_events(motion_server) -> None:
    args = parse_args([])
    assert args.host == "127.0.0.1"

    status, health = request(motion_server, "GET", "/healthz")
    assert status == 200
    assert health == {"ok": True}

    payload = {"schema": "wirejac.device.event/v1", "event": "motion.sample", "ax": 0.5}
    body = json.dumps(payload).encode()
    status, accepted = request(
        motion_server,
        "POST",
        "/events",
        body,
        **{"Content-Type": "application/json"},
    )
    assert status == 202
    assert accepted["accepted"] is True

    status, result = request(motion_server, "GET", "/events?limit=1")
    assert status == 200
    assert result["count"] == 1
    assert result["events"][0]["payload"] == payload

    logged = json.loads(motion_server.event_store.path.read_text().strip())
    assert logged["payload"] == payload


def test_server_rejects_oversized_and_non_object_json(motion_server) -> None:
    status, result = request(
        motion_server,
        "POST",
        "/events",
        b"x" * (MAX_BODY_BYTES + 1),
        **{"Content-Type": "application/json"},
    )
    assert status == 413
    assert "too large" in result["error"]

    status, result = request(
        motion_server,
        "POST",
        "/events",
        b"[]",
        **{"Content-Type": "application/json"},
    )
    assert status == 400
    assert "object" in result["error"]


@pytest.mark.parametrize(
    ("event", "expected"),
    [
        ("motion.sample", True),
        ("snatch.detected", True),
        ("sensor.detected", True),
        ("recording.started", True),
        ("recording.stopped", True),
        ("button.pressed", True),
        ("wirejac.heartbeat", True),
        ("backend.delivery", False),
        (None, False),
    ],
)
def test_bridge_filters_to_test_events(event, expected: bool) -> None:
    assert should_forward({"event": event}) is expected


def test_bridge_parses_only_json_objects() -> None:
    assert parse_device_line(b'{"event":"motion.sample"}') == {
        "event": "motion.sample"
    }
    assert parse_device_line(b"not json") is None
    assert parse_device_line(b"[]") is None


def test_bridge_discards_oversized_lines() -> None:
    serial = FakeSerial([b"a" * 9, b"remainder\n"])
    with pytest.raises(OversizedSerialLine):
        read_device_line(serial, max_line_bytes=8)


def test_bridge_forwards_selected_events_to_server(motion_server) -> None:
    port = motion_server.server_address[1]
    url = f"http://127.0.0.1:{port}/events"
    serial = FakeSerial(
        [
            b"boot noise\r\n",
            b'{"event":"wirejac.heartbeat"}\n',
            b'{"event":"sensor.detected","address":"0x68"}\n',
            b'{"event":"motion.sample","ax":1.25}\n',
        ]
    )
    with pytest.raises(KeyboardInterrupt):
        run_bridge(serial, url)

    status, result = request(motion_server, "GET", "/events")
    assert status == 200
    assert [entry["payload"]["event"] for entry in result["events"]] == [
        "wirejac.heartbeat",
        "sensor.detected",
        "motion.sample",
    ]


@pytest.mark.parametrize(
    "url",
    [
        "ftp://example.test/events",
        "http://user:secret@example.test/events",
        "http:///events",
        "http://example.test/events#fragment",
    ],
)
def test_bridge_rejects_unsafe_server_urls(url: str) -> None:
    with pytest.raises(ValueError):
        validate_server_url(url)
