# Accelerometer API Contract

Contract-Version: 1
Contract-ID: accelerometer-samples-v1

## Server to Client

`GET /api/samples?session_id=<id>`

Response:

```json
{
  "session_id": "training-001",
  "samples": [
    {
      "captured_at_ms": 1720000000000,
      "x": 0.12,
      "y": -0.08,
      "z": 9.74,
      "label": "baseline"
    }
  ]
}
```

The client may change presentation without changing this contract.
