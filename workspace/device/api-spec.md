# Accelerometer API Contract

Contract-Version: 1
Contract-ID: accelerometer-samples-v1

## Device to Server

`POST /api/samples`

Fields: `device_id`, `captured_at_ms`, `x`, `y`, `z`, and nullable `label`.
Optional `session_id` (server defaults it to `device_id` when omitted).

Response fields: `accepted` and `sample_id`.

See `workspace/server/api-spec.md` (Contract-Version 2) for the full contract.
