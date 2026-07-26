# Device Agent Role

You own only the ESP32 device workspace in this directory. Your target is an
ESP32 connected to an MPU6050 and a breadboard push button.

## Current Status

The hardware data path is not implemented yet. The current Jac source only
constructs an acceleration payload with `x`, `y`, and `z`. It does not read the
MPU6050, capture gyro values, handle the button, obtain Cognito credentials,
sign AWS requests, or write DynamoDB.

Do not report hardware capture or DynamoDB upload as working until it has been
validated on an ESP32.

## Default Hardware Configuration

- Button: GPIO 4 using the internal pull-up; pressed is active-low.
- I2C SDA: GPIO 21.
- I2C SCL: GPIO 22.
- MPU6050 address: `0x68`.
- Capture duration: 3 seconds.
- Sample rate: 100 Hz.
- Expected samples per experiment: approximately 300.

Keep these values in a configuration object so a different board or wiring can
override them without changing capture logic.

## Capture Flow

1. Initialize I2C and verify the MPU6050 responds at the configured address.
2. Configure the MPU6050 accelerometer range and wake it from sleep.
3. Configure the button with a pull-up and debounce repeated transitions.
4. Wait for a button press without continuously allocating memory.
5. Generate a unique `session_id` for the experiment.
6. Capture at 100 Hz for 3 seconds using monotonic timing.
7. Store `captured_at_ms`, acceleration `x/y/z`, and a stable sample index.
8. Leave `label` unset so the client can label the experiment after upload.
9. Upload samples to DynamoDB in batches of at most 25 write requests.
10. Retry bounded transient failures with backoff and retain unsent samples.
11. Show capture/upload state through serial output or a configured status LED.

Timing should not drift by sleeping for an unconditional 10 ms after each
read. Compute the next sample deadline from a monotonic clock and sleep only
for the remaining interval.

## DynamoDB Target

Write to table `wirejac-samples` in `us-west-2`.

The table key is:

- Partition key: `session_id` (string).
- Sort key: `sample_id` (string).

Use sortable sample IDs such as `SAMPLE#000000`, `SAMPLE#000001`, and so on.
All readings from one button capture share the same `session_id`.

Each DynamoDB item must contain:

```json
{
  "session_id": "EXP#<uuid>",
  "sample_id": "SAMPLE#000000",
  "device_id": "esp32-01",
  "captured_at_ms": 1720000000000,
  "x": 0.12,
  "y": -0.08,
  "z": 9.74,
  "label": null
}
```

Use DynamoDB number attributes for timestamps and numeric readings. The raw
HTTP DynamoDB representation sends number values as strings under the `N`
attribute type.

Use `BatchWriteItem` with no more than 25 `PutRequest` entries per call. Retry
only entries returned in `UnprocessedItems`; do not resend the entire capture
after a partially successful batch.

## Cognito Credentials

The ESP32 accesses DynamoDB directly with temporary Cognito Identity Pool
credentials. It must never use the administrator access key from the host
`.env` file.

Inject these non-secret deployment values into device configuration:

- `AWS_REGION`
- `COGNITO_DEVICE_IDENTITY_POOL_ID`
- `DYNAMODB_TABLE_NAME`
- `DEVICE_ID`

Credential flow:

1. Call Cognito Identity `GetId` with the configured Identity Pool ID.
2. Call `GetCredentialsForIdentity` with the returned identity ID.
3. Retain the temporary access key, secret key, session token, and expiration
   only in RAM.
4. Refresh credentials before expiration.
5. Synchronize time before signing requests because AWS SigV4 rejects requests
   with an invalid clock.

The Cognito device role must be scoped to DynamoDB writes for
`wirejac-samples`. It must not allow table scans, deletes, infrastructure
changes, S3 deployment, IAM operations, or reads of unrelated sessions.

## AWS SigV4 DynamoDB Requests

Send HTTPS requests to:

```text
https://dynamodb.us-west-2.amazonaws.com/
```

For batch writes:

- Method: `POST`
- Service: `dynamodb`
- Region: `us-west-2`
- `Content-Type`: `application/x-amz-json-1.0`
- `X-Amz-Target`: `DynamoDB_20120810.BatchWriteItem`
- `X-Amz-Date`: current UTC signing timestamp
- `X-Amz-Security-Token`: Cognito session token
- `Authorization`: generated AWS SigV4 authorization value

Build the canonical request, payload SHA-256, credential scope, string to sign,
and HMAC signature according to AWS Signature Version 4. Never print the
secret key, session token, signing key, or complete Authorization header.

## Gyroscope Status

The current cross-workspace API contract contains acceleration `x/y/z` only.
Gyroscope readings are not currently implemented or stored.

The MPU6050 can provide `gx/gy/gz`, but adding them is a contract change. Before
implementing gyro capture:

1. Update Device, Server, and Client `api-spec.md` files with gyro units and
   field names.
2. Return control to the Coordinator so all affected workspaces are selected.
3. Add `gx`, `gy`, and `gz` to DynamoDB writes and client parsing together.
4. Validate the scale conversion against the configured MPU6050 gyro range.

Do not silently place gyro values into acceleration fields.

## Pipeline Boundary

- Author restricted Jac source under `src/`.
- Run `jac check src/main.jac` before reporting success.
- Treat `generated/main.py` as the external Jac-to-Python output location.
- Run the MicroPython compatibility checks defined by the project.
- Do not invoke board, serial, `mpremote`, or flashing commands from agent
  tools.
- Do not claim arbitrary Jac, OSP, or Jac runtime code works in MicroPython.

## Contract Rules

- Follow `api-spec.md` for every DynamoDB item and client-visible field.
- If the payload changes, edit `api-spec.md`; WireJac must stop and replan.
- Keep Wi-Fi settings, Cognito configuration, and temporary credentials out of
  source control.
- Never read the repository root `.env` file.
