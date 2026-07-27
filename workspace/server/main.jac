"""WireJac accelerometer sample API.

Uses DynamoDB when WIREJAC_SAMPLES_TABLE is set; otherwise an in-process store
for local development.

When WIREJAC_API_KEY is set, POST/GET /api/samples require a matching api_key
(query/body). Health stays open for probes. Cloud deploy uses the Lambda
runtime under infrastructure/lambda/samples-api (same contract + X-Api-Key).
"""

import os;
import from typing { cast }
import from http { HTTPMethod }

obj Sample {
    has sample_id: str,
        device_id: str,
        session_id: str,
        captured_at_ms: int,
        x: float,
        y: float,
        z: float,
        label: str | None = None;
}

obj AcceptResult {
    has accepted: bool,
        sample_id: str;
}

obj SampleList {
    has session_id: str,
        samples: list[Sample] = [];
}

obj HealthStatus {
    has status: str,
        service: str,
        store: str;
}

::py::
import os
import uuid

_MEMORY: dict[str, list[dict]] = {}


def _store_mode():
    return "dynamodb" if os.environ.get("WIREJAC_SAMPLES_TABLE") else "memory"


def _new_sample_id():
    return uuid.uuid4().hex[:12]


def _put_memory(item):
    session = item["session_id"]
    _MEMORY.setdefault(session, []).append(item)
    _MEMORY[session].sort(key=lambda row: row["captured_at_ms"])
    return item


def _list_memory(session_id):
    return list(_MEMORY.get(session_id, []))


def _dynamo_table():
    import boto3

    name = os.environ["WIREJAC_SAMPLES_TABLE"]
    region = os.environ.get("WIREJAC_AWS_REGION", "us-west-2")
    profile = os.environ.get("WIREJAC_AWS_PROFILE", "")
    if profile:
        session = boto3.Session(profile_name=profile, region_name=region)
    else:
        session = boto3.Session(region_name=region)
    return session.resource("dynamodb").Table(name)


def _put_dynamo(item):
    table = _dynamo_table()
    table.put_item(Item={
        "session_id": item["session_id"],
        "sample_id": item["sample_id"],
        "device_id": item["device_id"],
        "captured_at_ms": int(item["captured_at_ms"]),
        "x": str(item["x"]),
        "y": str(item["y"]),
        "z": str(item["z"]),
        "label": item["label"] if item["label"] is not None else None,
    })
    return item


def _list_dynamo(session_id):
    table = _dynamo_table()
    response = table.query(
        KeyConditionExpression="session_id = :sid",
        ExpressionAttributeValues={":sid": session_id},
    )
    rows = []
    for raw in response.get("Items", []):
        rows.append({
            "sample_id": raw["sample_id"],
            "device_id": raw["device_id"],
            "session_id": raw["session_id"],
            "captured_at_ms": int(raw["captured_at_ms"]),
            "x": float(raw["x"]),
            "y": float(raw["y"]),
            "z": float(raw["z"]),
            "label": raw.get("label"),
        })
    rows.sort(key=lambda row: row["captured_at_ms"])
    return rows


def _put_sample(device_id, session_id, captured_at_ms, x, y, z, label):
    item = {
        "sample_id": _new_sample_id(),
        "device_id": device_id,
        "session_id": session_id or device_id,
        "captured_at_ms": int(captured_at_ms),
        "x": float(x),
        "y": float(y),
        "z": float(z),
        "label": label,
    }
    if _store_mode() == "dynamodb":
        return _put_dynamo(item)
    return _put_memory(item)


def _list_samples(session_id):
    if _store_mode() == "dynamodb":
        return _list_dynamo(session_id)
    return _list_memory(session_id)


def _api_key_ok(provided):
    expected = os.environ.get("WIREJAC_API_KEY", "")
    if not expected:
        return True
    return bool(provided) and provided == expected
::py::


"""True when the caller may hit sample endpoints (shared team API key)."""
def require_api_key(api_key: str = "") {
    if not _api_key_ok(api_key) {
        raise PermissionError("invalid or missing API key");
    }
}


"""In-process / DynamoDB write used by the public ingest endpoint."""
def put_sample(
    device_id: str,
    session_id: str,
    captured_at_ms: int,
    x: float,
    y: float,
    z: float,
    label: str | None = None
) -> dict {
    return cast(dict, _put_sample(
        device_id, session_id, captured_at_ms, x, y, z, label
    ));
}


"""List samples for one session from the active store."""
def list_samples(session_id: str) -> list {
    return cast(list, _list_samples(session_id));
}


@restspec(method=HTTPMethod.GET, path="/api/health")
def:pub health -> HealthStatus {
    mode = os.environ.get("WIREJAC_SAMPLES_TABLE", "");
    return HealthStatus(
        status="ok",
        service="wirejac-sample-api",
        store="dynamodb" if mode else "memory"
    );
}


@restspec(method=HTTPMethod.POST, path="/api/samples")
def:pub post_sample(
    device_id: str,
    captured_at_ms: int,
    x: float,
    y: float,
    z: float,
    session_id: str = "",
    label: str | None = None,
    api_key: str = ""
) -> AcceptResult {
    require_api_key(api_key);
    if not device_id {
        raise ValueError("device_id is required");
    }
    saved = put_sample(
        device_id, session_id, captured_at_ms, x, y, z, label
    );
    return AcceptResult(
        accepted=True,
        sample_id=cast(str, saved["sample_id"])
    );
}


@restspec(method=HTTPMethod.GET, path="/api/samples")
def:pub get_samples(session_id: str, api_key: str = "") -> SampleList {
    require_api_key(api_key);
    if not session_id {
        raise ValueError("session_id is required");
    }
    rows = list_samples(session_id);
    samples: list[Sample] = [];
    for row in rows {
        item = cast(dict, row);
        samples.append(Sample(
            sample_id=cast(str, item["sample_id"]),
            device_id=cast(str, item["device_id"]),
            session_id=cast(str, item["session_id"]),
            captured_at_ms=cast(int, item["captured_at_ms"]),
            x=cast(float, item["x"]),
            y=cast(float, item["y"]),
            z=cast(float, item["z"]),
            label=cast(str | None, item.get("label"))
        ));
    }
    return SampleList(session_id=session_id, samples=samples);
}
