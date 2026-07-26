"""Cloud sample API — DynamoDB-backed, shared team API key.

Implements the same contract as workspace/server (GET/POST /api/samples,
GET /api/health). Auth: X-Api-Key (or api_key query) must match
WIREJAC_API_KEY. Health is public for probes.
"""

from __future__ import annotations

import json
import os
import uuid
from typing import Any

import boto3

_TABLE_NAME = os.environ["WIREJAC_SAMPLES_TABLE"]
_API_KEY = os.environ.get("WIREJAC_API_KEY", "")
_REGION = os.environ.get("WIREJAC_AWS_REGION", "us-west-2")

_table = boto3.resource("dynamodb", region_name=_REGION).Table(_TABLE_NAME)


def _response(status: int, body: dict[str, Any], *, cors: bool = True) -> dict[str, Any]:
    headers = {"content-type": "application/json"}
    if cors:
        headers.update(
            {
                "access-control-allow-origin": "*",
                "access-control-allow-headers": "content-type,x-api-key",
                "access-control-allow-methods": "GET,POST,OPTIONS",
            }
        )
    return {
        "statusCode": status,
        "headers": headers,
        "body": json.dumps(body),
    }


def _headers(event: dict[str, Any]) -> dict[str, str]:
    raw = event.get("headers") or {}
    return {str(k).lower(): str(v) for k, v in raw.items()}


def _query(event: dict[str, Any]) -> dict[str, str]:
    params = event.get("queryStringParameters") or {}
    return {str(k): str(v) for k, v in params.items() if v is not None}


def _authorized(event: dict[str, Any]) -> bool:
    if not _API_KEY:
        return True
    headers = _headers(event)
    provided = headers.get("x-api-key", "")
    if not provided:
        provided = _query(event).get("api_key", "")
    return provided == _API_KEY


def _new_sample_id() -> str:
    return uuid.uuid4().hex[:12]


def _put_sample(item: dict[str, Any]) -> dict[str, Any]:
    _table.put_item(
        Item={
            "session_id": item["session_id"],
            "sample_id": item["sample_id"],
            "device_id": item["device_id"],
            "captured_at_ms": int(item["captured_at_ms"]),
            "x": str(item["x"]),
            "y": str(item["y"]),
            "z": str(item["z"]),
            "label": item["label"],
        }
    )
    return item


def _list_samples(session_id: str) -> list[dict[str, Any]]:
    response = _table.query(
        KeyConditionExpression="session_id = :sid",
        ExpressionAttributeValues={":sid": session_id},
    )
    rows: list[dict[str, Any]] = []
    for raw in response.get("Items", []):
        rows.append(
            {
                "sample_id": raw["sample_id"],
                "device_id": raw["device_id"],
                "session_id": raw["session_id"],
                "captured_at_ms": int(raw["captured_at_ms"]),
                "x": float(raw["x"]),
                "y": float(raw["y"]),
                "z": float(raw["z"]),
                "label": raw.get("label"),
            }
        )
    rows.sort(key=lambda row: row["captured_at_ms"])
    return rows


def _parse_body(event: dict[str, Any]) -> dict[str, Any]:
    raw = event.get("body") or ""
    if event.get("isBase64Encoded"):
        import base64

        raw = base64.b64decode(raw).decode("utf-8")
    if not raw:
        return {}
    data = json.loads(raw)
    if not isinstance(data, dict):
        raise ValueError("JSON body must be an object")
    return data


def _path(event: dict[str, Any]) -> str:
    raw = (
        event.get("rawPath")
        or event.get("path")
        or (event.get("requestContext") or {}).get("http", {}).get("path")
        or "/"
    )
    return raw.rstrip("/") or "/"


def _method(event: dict[str, Any]) -> str:
    return (
        (event.get("requestContext") or {}).get("http", {}).get("method")
        or event.get("httpMethod")
        or "GET"
    ).upper()


def handle_health() -> dict[str, Any]:
    return _response(
        200,
        {
            "status": "ok",
            "service": "wirejac-sample-api",
            "store": "dynamodb",
        },
    )


def handle_get_samples(event: dict[str, Any]) -> dict[str, Any]:
    if not _authorized(event):
        return _response(401, {"error": "invalid or missing API key"})
    session_id = _query(event).get("session_id", "")
    if not session_id:
        return _response(400, {"error": "session_id is required"})
    return _response(
        200,
        {"session_id": session_id, "samples": _list_samples(session_id)},
    )


def handle_post_samples(event: dict[str, Any]) -> dict[str, Any]:
    if not _authorized(event):
        return _response(401, {"error": "invalid or missing API key"})
    try:
        body = _parse_body(event)
    except (ValueError, json.JSONDecodeError) as exc:
        return _response(400, {"error": str(exc)})

    device_id = str(body.get("device_id") or "")
    if not device_id:
        return _response(400, {"error": "device_id is required"})

    try:
        captured_at_ms = int(body["captured_at_ms"])
        x = float(body["x"])
        y = float(body["y"])
        z = float(body["z"])
    except (KeyError, TypeError, ValueError):
        return _response(
            400,
            {"error": "captured_at_ms, x, y, z are required numbers"},
        )

    session_id = str(body.get("session_id") or device_id)
    label = body.get("label")
    if label is not None:
        label = str(label)

    saved = _put_sample(
        {
            "sample_id": _new_sample_id(),
            "device_id": device_id,
            "session_id": session_id,
            "captured_at_ms": captured_at_ms,
            "x": x,
            "y": y,
            "z": z,
            "label": label,
        }
    )
    return _response(200, {"accepted": True, "sample_id": saved["sample_id"]})


def handler(event: dict[str, Any], _context: Any) -> dict[str, Any]:
    method = _method(event)
    path = _path(event)

    if method == "OPTIONS":
        return _response(204, {})

    if path.endswith("/api/health") and method == "GET":
        return handle_health()

    if path.endswith("/api/samples") and method == "GET":
        return handle_get_samples(event)

    if path.endswith("/api/samples") and method == "POST":
        return handle_post_samples(event)

    return _response(404, {"error": "not found"})
