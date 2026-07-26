# Accelerometer API Contract

Contract-Version: 1
Contract-ID: accelerometer-samples-v1

## Device to Server

`POST /api/samples`

Fields: `device_id`, `captured_at_ms`, `x`, `y`, `z`, and nullable `label`.

Response fields: `accepted` and `sample_id`.

## Server to Client

`GET /api/samples?session_id=<id>`

Response fields: `session_id` and `samples`.
