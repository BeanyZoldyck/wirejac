# WireJac Agent Graph

This repository contains a runnable Jac-native autonomous agent graph for an embedded data-collection project. Jac nodes represent the Coordinator, Client, Server, Device, Deployment, and Monitoring locations. A `ChangeRequest` walker carries one prompt through the graph.

## Requirements

- A current Jac installation.
- Node and npm for the demo client validation.
- An OpenRouter key for live agents.
- Optional: AWS CLI profile `wirejac` only for deploying infrastructure (not for using the samples API).

The configured default model is `deepseek/deepseek-v4-flash`. Override it with `OPENROUTER_MODEL` if necessary.

## Cloud samples API (portable)

Hackathon default: DynamoDB in AWS, HTTPS API in Lambda, shared team API key.

```text
Meta app / device  --(X-Api-Key)-->  SamplesApi (Lambda Function URL)
                                          | IAM role
                                          v
                                     DynamoDB wirejac-samples
```

No AWS login needed on laptops to read/write samples. After `cdk deploy`:

```bash
# API URL
aws ssm get-parameter --name /wirejac/dev/samples-api-url --profile wirejac \
  --query Parameter.Value --output text

# Shared team key
aws secretsmanager get-secret-value --secret-id wirejac/dev/samples-api-key \
  --profile wirejac --query SecretString --output text
```

```bash
curl "$SAMPLES_API_URL/api/health"
curl -H "X-Api-Key: $WIREJAC_API_KEY" \
  "$SAMPLES_API_URL/api/samples?session_id=training-001"
```

Local Jac (`workspace/server`) still supports in-memory or Dynamo via profile
when you want it; set `WIREJAC_API_KEY` to exercise the same auth gate.
Details: [`infrastructure/README.md`](infrastructure/README.md).
Contract: [`workspace/server/api-spec.md`](workspace/server/api-spec.md).

## Meta app hosting (S3 + CloudFront)

The product UI (`workspace/client`) is hosted on private S3 behind CloudFront.
`cdk deploy` syncs assets, injects `config.js` (API URL + shared key), and
prints `MetaAppUrl` (SSM `/wirejac/dev/meta-app-url`). The browser calls the
cloud samples API — never DynamoDB.

## Run With Live Agents

```bash
export OPENROUTER_API_KEY="..."
export WIREJAC_PROMPT="Make the active sample count more prominent"
jac run main.jac --no-cache
```

The Coordinator calls OpenRouter to produce an impact plan. Selected workspace nodes then call OpenRouter with contained file and command tools. Workspace tools cannot resolve paths outside their assigned directory.

## Run Without OpenRouter

Mock mode exercises the complete graph and deterministic validators without model calls or source edits:

```bash
WIREJAC_MOCK=1 \
WIREJAC_PROMPT="Make the active sample count more prominent" \
jac run main.jac --no-cache
```

Expected route:

```text
Coordinator -> Client -> Deployment -> Monitoring
```

Server and Device are recorded as skipped.

## Run Tests

```bash
jac test tests/wirejac.jac
```

The tests use mock mode and cover impact-plan validation, the client-only traversal, the six-node graph snapshot, deterministic workspace validation, and the ESP32 deployment placeholder.

## Public Walkers

`orchestrator/graph.jac` exposes:

- `SubmitChange`: accepts only a `prompt`, creates an internal `ChangeRequest`, and runs it through the agent graph.
- `GraphSnapshot`: reports the six graph nodes and eight workflow edges for a future dashboard.

Run `jac start main.jac --no_client` to expose public walkers through Jac's API-only server runtime. The external dashboard integration still needs to connect these endpoints and the activation stream.

```bash
curl -X POST http://localhost:8000/walker/SubmitChange \
  -H 'Content-Type: application/json' \
  -d '{"prompt":"Make the active sample count more prominent"}'

curl -X POST http://localhost:8000/walker/GraphSnapshot \
  -H 'Content-Type: application/json' \
  -d '{}'
```

## Generated Runtime Data

- `runtime/events/events.jsonl`: compact activation events. This is the dashboard event-sink placeholder.
- `runtime/snapshots/<request-id>/<workspace>`: pre-edit workspace snapshots and manifests.

These generated paths are ignored by Git.
Set `WIREJAC_EVENT_FILE` to redirect the JSONL sink, as the test suite does.

## Workspace Boundaries

```text
workspace/client  - editable accelerometer dashboard
workspace/server  - Jac samples API (memory or DynamoDB)
workspace/device  - restricted device Jac source
```

Each workspace includes a role file and its local `api-spec.md`. If an agent changes its API spec, the request walker returns to Coordinator before Deployment.

## External Placeholders

### Dashboard

`_emit_event` in `orchestrator/adapters.jac` currently appends JSONL events. Replace or extend it with SSE/WebSocket publication. `GraphSnapshot` already supplies static topology data.

Monitoring currently accepts configured checks without launching a browser. Replace `_monitor` with browser, process-log, HTTP, and serial adapters when the external dashboard is available.

### ESP32

Device changes stop in Deployment with `AWAITING_APPROVAL`. `_deploy` reports the expected artifact as `workspace/device/generated/main.py` but does not invoke Jac-to-Python, MicroPython, serial, or flashing tools.

The external device pipeline should:

1. Convert the restricted Jac source in `workspace/device/src` to Python.
2. Reject output incompatible with the target MicroPython runtime.
3. Place the prepared artifact in `workspace/device/generated/main.py`.
4. Require artifact-specific approval before writing to a physical ESP32.

See `jacgraph.md` for the complete architecture and safety model.

## Hardware Agent

The Jac-native hardware service lives under [`hardware/`](hardware/). It
converts a coordinator request into a validated ESP32 breadboard design,
assembly SVGs, constrained MicroPython firmware, optional Wokwi evidence, and
a guarded physical deployment path.

The supported physical MVP is a 30-pin DOIT ESP32 DevKit V1, GY-521 MPU6050,
momentary button, and half breadboard. Device operations require a stable
`/dev/serial/by-id/...` path, a confirmed ESP32 MAC, a verified flash backup,
and explicit assembly confirmation.

Useful entry points:

```bash
./scripts/start-local.sh
jac run demo.jac
/home/mason/jac/wirejac/.jac/venv/bin/python examples/hardware_status_dashboard.py
```

Hardware service contracts and deployment safety details are in
[`docs/coordinator-api.md`](docs/coordinator-api.md),
[`docs/hardware-profile.md`](docs/hardware-profile.md), and
[`docs/runtime-modes.md`](docs/runtime-modes.md).
