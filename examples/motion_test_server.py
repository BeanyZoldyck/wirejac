#!/usr/bin/env python3
"""Small bounded HTTP collector for WireJac motion-test events."""

from __future__ import annotations

import argparse
from collections import deque
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import threading
from typing import Any, BinaryIO
from urllib.parse import parse_qs, urlsplit


DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8787
DEFAULT_LOG_PATH = Path.home() / ".wirejac" / "test-server" / "events.ndjson"
MAX_BODY_BYTES = 16 * 1024
MAX_QUERY_BYTES = 256
MAX_RECENT_EVENTS = 500
MAX_RESPONSE_EVENTS = 100
MAX_BOOTSTRAP_BYTES = 1024 * 1024


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


class EventStore:
    """Append-only NDJSON storage with a bounded in-memory recent-event view."""

    def __init__(self, path: str | os.PathLike[str]) -> None:
        self.path = Path(path).expanduser().resolve(strict=False)
        self._events: deque[dict[str, Any]] = deque(maxlen=MAX_RECENT_EVENTS)
        self._lock = threading.Lock()
        self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        self._load_recent()

    @staticmethod
    def _open_flags(flags: int) -> int:
        nofollow = getattr(os, "O_NOFOLLOW", 0)
        return flags | nofollow

    def _open(self, flags: int) -> int:
        return os.open(self.path, self._open_flags(flags), 0o600)

    def _load_recent(self) -> None:
        try:
            descriptor = self._open(os.O_RDONLY)
        except FileNotFoundError:
            return
        try:
            size = os.fstat(descriptor).st_size
            offset = max(0, size - MAX_BOOTSTRAP_BYTES)
            os.lseek(descriptor, offset, os.SEEK_SET)
            data = os.read(descriptor, MAX_BOOTSTRAP_BYTES)
        finally:
            os.close(descriptor)
        lines = data.splitlines()
        if offset and lines:
            lines = lines[1:]
        for line in lines[-MAX_RECENT_EVENTS:]:
            try:
                record = json.loads(line)
            except (UnicodeDecodeError, json.JSONDecodeError):
                continue
            if isinstance(record, dict):
                self._events.append(record)

    def append(self, payload: dict[str, Any]) -> dict[str, Any]:
        record = {"received_at": _utc_now(), "payload": payload}
        line = json.dumps(
            record,
            ensure_ascii=True,
            separators=(",", ":"),
            allow_nan=False,
        ).encode("utf-8") + b"\n"
        with self._lock:
            descriptor = self._open(os.O_APPEND | os.O_CREAT | os.O_WRONLY)
            try:
                view = memoryview(line)
                while view:
                    written = os.write(descriptor, view)
                    view = view[written:]
            finally:
                os.close(descriptor)
            self._events.append(record)
        return record

    def recent(self, limit: int) -> list[dict[str, Any]]:
        bounded = min(max(1, limit), MAX_RESPONSE_EVENTS)
        with self._lock:
            return list(self._events)[-bounded:]


class MotionEventServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(
        self,
        address: tuple[str, int],
        store: EventStore,
    ) -> None:
        self.event_store = store
        super().__init__(address, MotionEventHandler)


class MotionEventHandler(BaseHTTPRequestHandler):
    server: MotionEventServer

    def log_message(self, format: str, *args: object) -> None:
        print("%s - %s" % (self.address_string(), format % args))

    def _send_json(self, status: int, payload: dict[str, Any]) -> None:
        body = json.dumps(
            payload,
            ensure_ascii=True,
            separators=(",", ":"),
            allow_nan=False,
        ).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)

    def _path(self) -> str:
        return urlsplit(self.path).path

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        parsed = urlsplit(self.path)
        if parsed.path == "/healthz":
            self._send_json(200, {"ok": True})
            return
        if parsed.path != "/events":
            self._send_json(404, {"error": "not found"})
            return
        if len(parsed.query.encode("utf-8")) > MAX_QUERY_BYTES:
            self._send_json(414, {"error": "query too large"})
            return
        query = parse_qs(parsed.query, keep_blank_values=True)
        if set(query) - {"limit"}:
            self._send_json(400, {"error": "only the limit query is supported"})
            return
        try:
            limit = int(query.get("limit", [str(MAX_RESPONSE_EVENTS)])[0])
        except (TypeError, ValueError):
            self._send_json(400, {"error": "limit must be an integer"})
            return
        if limit < 1:
            self._send_json(400, {"error": "limit must be positive"})
            return
        events = self.server.event_store.recent(limit)
        self._send_json(200, {"count": len(events), "events": events})

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        if self._path() != "/events":
            self._send_json(404, {"error": "not found"})
            return
        if self.headers.get("Transfer-Encoding"):
            self._send_json(400, {"error": "chunked requests are not supported"})
            return
        content_type = self.headers.get_content_type()
        if content_type != "application/json":
            self._send_json(415, {"error": "Content-Type must be application/json"})
            return
        try:
            length = int(self.headers.get("Content-Length", ""))
        except ValueError:
            self._send_json(411, {"error": "valid Content-Length required"})
            return
        if length < 1:
            self._send_json(400, {"error": "request body is empty"})
            return
        if length > MAX_BODY_BYTES:
            self._send_json(413, {"error": "request body too large"})
            return
        body = self.rfile.read(length)
        if len(body) != length:
            self._send_json(400, {"error": "incomplete request body"})
            return
        try:
            payload = json.loads(body)
        except (UnicodeDecodeError, json.JSONDecodeError):
            self._send_json(400, {"error": "request body is not valid JSON"})
            return
        if not isinstance(payload, dict):
            self._send_json(400, {"error": "event must be a JSON object"})
            return
        try:
            record = self.server.event_store.append(payload)
        except (TypeError, ValueError):
            self._send_json(400, {"error": "event contains unsupported JSON values"})
            return
        self._send_json(202, {"accepted": True, "received_at": record["received_at"]})


def build_server(
    host: str = DEFAULT_HOST,
    port: int = DEFAULT_PORT,
    *,
    log_path: str | os.PathLike[str] = DEFAULT_LOG_PATH,
) -> MotionEventServer:
    if not 0 <= port <= 65535:
        raise ValueError("port must be between 0 and 65535")
    return MotionEventServer((host, port), EventStore(log_path))


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default=DEFAULT_HOST)
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--log", type=Path, default=DEFAULT_LOG_PATH)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    server = build_server(args.host, args.port, log_path=args.log)
    host, port = server.server_address[:2]
    print(f"WireJac motion test server listening on http://{host}:{port}")
    print(f"Writing NDJSON events to {server.event_store.path}")
    try:
        server.serve_forever(poll_interval=0.25)
    except KeyboardInterrupt:
        print("Stopping motion test server")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
