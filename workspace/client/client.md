# Client Agent Role

You own only the accelerometer experiment dashboard in this directory. Build
the production client using Jac client components, then compile it to static
web assets for S3 and CloudFront.

## Current Status

The existing dashboard is a static demonstration. It does not currently query
DynamoDB, obtain Cognito credentials, list experiments, or label uploaded
captures. Do not report those operations as working until the Jac client build
and DynamoDB integration tests pass.

## Responsibilities

- Implement the client in Jac client syntax.
- List uploaded MPU6050 capture sessions.
- Query all readings for a selected `session_id`.
- Render acceleration `x/y/z` against capture time.
- Show device ID, capture timestamp, sample count, duration, and label state.
- Allow labels and notes to be assigned after upload when the deployed IAM
  policy permits metadata updates.
- Export selected experiments as JSON or CSV.
- Keep the app usable on desktop and mobile.
- Handle loading, empty, partial, throttled, and credential-expired states.

WireJac build provenance does not belong in this application. The separate
WireJac dashboard will consume orchestration logs later.

## DynamoDB Target

Read from table `wirejac-samples` in `us-west-2`.

The table key is:

- Partition key: `session_id` (string).
- Sort key: `sample_id` (string).

Device captures use a session ID such as `EXP#<uuid>` and sortable sample IDs
such as `SAMPLE#000000`.

Expected reading shape:

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

The current contract contains acceleration only. Do not expect `gx/gy/gz`
until all workspace API specifications have been updated together.

## Browser Cognito Credentials

Use temporary Cognito Identity Pool credentials in the browser. Never bundle
the host administrator access key or secret key.

The static build may receive only these public values:

- `AWS_REGION`
- `COGNITO_CLIENT_IDENTITY_POOL_ID`
- `DYNAMODB_TABLE_NAME`

Use a separate Client Identity Pool role from the ESP32 Device role. The client
role may receive only the DynamoDB operations needed for the experiment UI,
such as `Query`, a constrained catalog `Scan` or index query, and metadata
`UpdateItem`. It must not have infrastructure, IAM, S3 deployment, or arbitrary
table-write permissions.

## Jac Client AWS SDK

Use the browser-compatible AWS SDK v3 packages through Jac's npm integration:

- `@aws-sdk/client-dynamodb`
- `@aws-sdk/lib-dynamodb`
- `@aws-sdk/credential-provider-cognito-identity`
- `@aws-sdk/client-cognito-identity`

Construct a `DynamoDBClient` with the configured region and Cognito identity
credential provider. Construct a document client with
`DynamoDBDocumentClient.from(...)` so application code receives ordinary
JavaScript values rather than raw DynamoDB attribute maps.

Never persist temporary AWS credentials in local storage, session storage,
application state logs, query strings, or error reports.

## Querying Readings

Use DynamoDB `Query`, not `Scan`, to load readings for one experiment:

```text
KeyConditionExpression: session_id = :session_id
ExpressionAttributeValues: {":session_id": selectedSessionId}
ScanIndexForward: true
```

Request these fields unless the UI needs more:

```text
session_id, sample_id, device_id, captured_at_ms, x, y, z, label
```

Continue querying while `LastEvaluatedKey` is present. Do not assume one
response contains the complete three-second capture.

After retrieval:

1. Ignore malformed items and surface a count of rejected readings.
2. Sort by `captured_at_ms`, using the sample index as a stable tie-breaker.
3. Convert numeric values before charting.
4. Compute duration from the first and last timestamps.
5. Keep the original readings unchanged for JSON/CSV export.
6. Downsample only for rendering when necessary; exports retain full data.

Listing every experiment with an unrestricted table scan is acceptable only as
a temporary demo fallback. Prefer the experiment metadata index defined by the
infrastructure contract once it is available.

## Labeling After Upload

An uploaded experiment initially has no label. Label and notes updates must
target only the experiment metadata item defined by the shared contract. Never
rewrite all sample items merely to change a label.

Use a conditional update so the client cannot accidentally create metadata for
an experiment that does not exist. Display update failures and retain the
user's unsaved text until retry or cancellation.

## Client Build

Use the Jac CLI supported in this project:

```bash
jac check main.jac
jac build main.jac --client web
```

Run commands from `workspace/client`. The Deployment node owns S3 upload and
CloudFront invalidation after the build succeeds. The Client agent must never
run `aws s3 sync`, `cloudfront create-invalidation`, or CDK deployment commands.

## Contract Rules

- Preserve the fields documented in `api-spec.md` unless a coordinated change
  is necessary.
- If you edit `api-spec.md`, state it in the structured result so WireJac stops
  before deployment and returns to the Coordinator.
- Pure presentation changes must not modify the DynamoDB contract.

## Boundaries

- Do not access parent directories.
- Do not read the repository root `.env` file.
- Do not start or stop host processes.
- Do not put credentials, temporary tokens, or signed requests in source files.
- Do not claim browser monitoring passed; Monitoring owns that check.
