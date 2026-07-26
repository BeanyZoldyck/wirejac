# Accelerometer API Contract

Contract-Version: 3
Contract-ID: accelerometer-samples-v1

## Overview

The server accepts accelerometer samples from devices and serves session
histories to the client dashboard. Durable storage is an AWS DynamoDB table
owned by the infrastructure worker — the server never writes CDK.

**Cloud (hackathon default):** Lambda Function URL (`SamplesApi`) with IAM
access to DynamoDB. Callers send a shared team API key. Laptops do not need
AWS credentials.

**Local:** `jac start` on `workspace/server` with optional in-memory store
when `WIREJAC_SAMPLES_TABLE` is unset.

## Required infrastructure

| Resource       | Kind            | Purpose                                      |
|----------------|-----------------|----------------------------------------------|
| `SamplesTable` | data            | Persist samples keyed by `session_id`        |
| `SamplesApi`   | backend_runtime | Cloud HTTPS API + IAM role for DynamoDB      |

Emitted as an `InfraRequest` when missing. Fulfilled only by changes under
`infrastructure/`.

Environment after deploy:

- `WIREJAC_SAMPLES_TABLE` — DynamoDB table name (from stack output / SSM)
- `WIREJAC_AWS_REGION` — region (default `us-west-2`)
- `WIREJAC_AWS_PROFILE` — optional profile name (local Jac → Dynamo only)
- `WIREJAC_API_KEY` — shared team key (required in cloud; optional locally)

SSM / Secrets:

- `/wirejac/dev/samples-api-url` — Function URL
- `wirejac/dev/samples-api-key` — Secrets Manager secret (shared key)

## Authorization

When `WIREJAC_API_KEY` is set (always in cloud):

| Surface | How to send the key |
|---------|---------------------|
| Cloud Lambda | Header `X-Api-Key: <key>` (preferred); or query `api_key` |
| Local Jac    | Query/body field `api_key` |

`GET /api/health` stays public (no key).

Missing/wrong key → `401`.

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

Also send `X-Api-Key` (cloud) or `api_key` in the JSON body (local Jac).

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
| `401`  | Missing/invalid API key        |
| `503`  | Durable store unavailable      |

## Server to Client

The Meta app (product UI on CloudFront) calls this HTTP API. It must not
query DynamoDB directly from the browser. Deploy injects `config.js` with
`apiBaseUrl` + `apiKey`.

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
| `401`  | Missing/invalid API key |
| `503`  | Durable store unavailable |

## Health

`GET /api/health` → `{"status": "ok", "service": "wirejac-sample-api", "store": "memory"|"dynamodb"}`
