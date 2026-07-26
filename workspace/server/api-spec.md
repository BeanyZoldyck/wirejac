# Accelerometer API Contract

Contract-Version: 2
Contract-ID: accelerometer-samples-v1

## Overview

The server accepts accelerometer samples from devices and serves session
histories to the client dashboard. Durable storage is an AWS DynamoDB table
owned by the infrastructure worker — the server never writes CDK.

## Required infrastructure

| Resource       | Kind | Purpose                                      |
|----------------|------|----------------------------------------------|
| `SamplesTable` | data | Persist samples keyed by `session_id`        |

Emitted as an `InfraRequest` when missing. Fulfilled only by changes under
`infrastructure/`.

Environment after deploy:

- `WIREJAC_SAMPLES_TABLE` — DynamoDB table name (from stack output / SSM)
- `WIREJAC_AWS_REGION` — region (default `us-west-2`)
- `WIREJAC_AWS_PROFILE` — optional profile name (credentials stay local)

Without `WIREJAC_SAMPLES_TABLE`, the server uses an in-process store so local
mock runs stay offline.

## Device to Server

`POST /api/samples`

Request:

```json
{
  "device_id": "esp32-01",
  "session_id": "training-001",
  "captured_at_ms": 1720000000000,
  "x": 0.12,
  "y": -0.08,
  "z": 9.74,
  "label": "baseline"
}
```

| Field            | Required | Notes                                      |
|------------------|----------|--------------------------------------------|
| `device_id`      | yes      | Hardware source identifier                 |
| `session_id`     | no       | Defaults to `device_id` when omitted       |
| `captured_at_ms` | yes      | Unix epoch milliseconds                    |
| `x`, `y`, `z`    | yes      | Acceleration components                    |
| `label`          | no       | Nullable string                            |

Response `200`:

```json
{
  "accepted": true,
  "sample_id": "a1b2c3d4e5f6"
}
```

Errors:

| Status | When                          |
|--------|-------------------------------|
| `400`  | Missing/invalid required field |
| `503`  | Durable store unavailable      |

## Server to Client

`GET /api/samples?session_id=<id>`

Response `200`:

```json
{
  "session_id": "training-001",
  "samples": [
    {
      "sample_id": "a1b2c3d4e5f6",
      "device_id": "esp32-01",
      "captured_at_ms": 1720000000000,
      "x": 0.12,
      "y": -0.08,
      "z": 9.74,
      "label": "baseline"
    }
  ]
}
```

Samples are ordered by `captured_at_ms` ascending. Empty sessions return
`"samples": []`.

Errors:

| Status | When                    |
|--------|-------------------------|
| `400`  | Missing `session_id`    |
| `503`  | Durable store unavailable |

## Health

`GET /api/health` → `{"status": "ok", "service": "wirejac-sample-api", "store": "memory"|"dynamodb"}`
