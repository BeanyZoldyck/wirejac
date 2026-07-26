"""Lambda Function URL API for Wirejac accelerometer samples."""

from __future__ import annotations

import json
import os
import time
import uuid
from decimal import Decimal

import boto3


TABLE = boto3.resource("dynamodb").Table(os.environ["WIREJAC_SAMPLES_TABLE"])
API_KEY = os.environ["WIREJAC_API_KEY"]


def response(status: int, body: dict) -> dict:
    return {
        "statusCode": status,
        "headers": {
            "content-type": "application/json",
            "access-control-allow-origin": "*",
            "access-control-allow-headers": "content-type,x-api-key",
            "access-control-allow-methods": "GET,POST,OPTIONS",
        },
        "body": json.dumps(body),
    }


def authorized(headers: dict) -> bool:
    normalized = {str(key).lower(): value for key, value in headers.items()}
    return normalized.get("x-api-key", "") == API_KEY


def parse_number(value: object, field: str) -> Decimal:
    try:
        return Decimal(str(value))
    except Exception as exc:
        raise ValueError(f"{field} must be numeric") from exc


def put_sample(payload: dict) -> dict:
    device_id = str(payload.get("device_id", "")).strip()
    if not device_id:
        raise ValueError("device_id is required")
    captured_at_ms = int(payload["captured_at_ms"])
    session_id = str(payload.get("session_id") or device_id)
    sample_id = str(payload.get("sample_id") or f"{captured_at_ms:013d}#{uuid.uuid4().hex[:8]}")
    item = {
        "session_id": session_id,
        "sample_id": sample_id,
        "device_id": device_id,
        "captured_at_ms": captured_at_ms,
        "x": parse_number(payload["x"], "x"),
        "y": parse_number(payload["y"], "y"),
        "z": parse_number(payload["z"], "z"),
        "label": payload.get("label"),
        "received_at_ms": int(time.time() * 1000),
    }
    TABLE.put_item(Item=item)
    return {"accepted": True, "sample_id": sample_id, "session_id": session_id}


def list_samples(session_id: str) -> dict:
    if not session_id:
        raise ValueError("session_id is required")
    result = TABLE.query(
        KeyConditionExpression="session_id = :session_id",
        ExpressionAttributeValues={":session_id": session_id},
    )
    rows = result.get("Items", [])
    rows.sort(key=lambda item: int(item.get("captured_at_ms", 0)))
    samples = []
    for item in rows:
        samples.append(
            {
                "session_id": item["session_id"],
                "sample_id": item["sample_id"],
                "device_id": item["device_id"],
                "captured_at_ms": int(item["captured_at_ms"]),
                "x": float(item["x"]),
                "y": float(item["y"]),
                "z": float(item["z"]),
                "label": item.get("label"),
            }
        )
    return {"session_id": session_id, "samples": samples}


def handler(event: dict, _context: object) -> dict:
    request = event.get("requestContext", {}).get("http", {})
    method = request.get("method", "GET").upper()
    path = request.get("path", event.get("rawPath", "/"))
    if method == "OPTIONS":
        return response(204, {})
    if path.rstrip("/") == "/api/health":
        return response(200, {"status": "ok", "service": "wirejac-samples-api", "store": "dynamodb"})
    if not authorized(event.get("headers") or {}):
        return response(401, {"error": "invalid API key"})
    try:
        if path.rstrip("/") == "/api/samples" and method == "POST":
            payload = json.loads(event.get("body") or "{}")
            return response(200, put_sample(payload))
        if path.rstrip("/") == "/api/samples" and method == "GET":
            query = event.get("queryStringParameters") or {}
            return response(200, list_samples(str(query.get("session_id", ""))))
        return response(404, {"error": "not found"})
    except (KeyError, TypeError, ValueError) as exc:
        return response(400, {"error": str(exc)})
    except Exception:
        return response(503, {"error": "sample store unavailable"})
