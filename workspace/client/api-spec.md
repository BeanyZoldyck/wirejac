# Accelerometer API Contract

Contract-Version: 3
Contract-ID: accelerometer-samples-v1

The Meta app is static UI (S3 + CloudFront). It reads history through the
cloud samples API below — never DynamoDB from the browser.

Authorization: send header `X-Api-Key` with the shared team key from
deployed `config.js` (injected at `cdk deploy`; not committed).

## Server to Client

`GET /api/samples?session_id=<id>`

Headers: `X-Api-Key: <shared-team-key>`

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
