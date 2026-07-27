# WireJac Agent Graph

This repository contains a runnable Jac-native autonomous agent graph for an embedded data-collection project. Jac nodes represent the Coordinator, Client, Server, Device, Deployment, and Monitoring locations. A `ChangeRequest` walker carries one prompt through the graph.

## Requirements

- A current Jac installation.
- The Jac MCP plugin (`jac install jac-mcp`).
- Node and npm for the demo client validation.
- An OpenRouter key for the coordinator and workspace agents.
- Optional: AWS CLI profile `wirejac` only for deploying infrastructure (not for using the samples API).

The configured default model is `deepseek/deepseek-v4-flash`. Override it with `OPENROUTER_MODEL` if necessary.

## Start the WireJac App

From the repository root:

```bash
./scripts/start-app.sh
```

The launcher installs the frontend dependencies, links this repository's Jac
modules into the frontend project, and starts the full-stack Jac app. Set
`OPENROUTER_API_KEY` before submitting a build. Open <http://localhost:8000/>. The Jac RPC API runs at
<http://localhost:8001/> while the development client is active.

Use this prompt for the complete six-node phone-snatch demo:

```text
Create a phone snatch data collection system with a dashboard, an event API,
and an ESP32 GY-521 recording button.
```

The normal prompt runs hardware in safe `plan` mode and generates firmware plus
14 progressive assembly SVGs without opening a serial device. An explicit
`flash` or `deploy` prompt instead stops at the physical assembly gate and
renders the full 18-step circuit before any device operation can continue.
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

## Run Agents

```bash
export OPENROUTER_API_KEY="..."
export WIREJAC_PROMPT="Make the active sample count more prominent"
jac run main.jac --no-cache
```

The Coordinator calls OpenRouter to produce an impact plan. Selected workspace nodes then call OpenRouter with contained file and command tools. Workspace tools cannot resolve paths outside their assigned directory.

Client and Device agent sessions also connect to `jac mcp --mode lite` over
stdio. They receive a constrained set of Jac documentation, formatting,
linting, validation, and transpilation tools; MCP command execution and code
execution tools are not exposed.

## Run Tests

```bash
jac test tests/wirejac.jac
```

The tests cover impact-plan validation, graph topology, hardware compilation,
and the guarded ESP32 hardware lifecycle.

## Public Walkers

`orchestrator/graph.jac` exposes:

- `SubmitChange`: accepts only a `prompt`, creates an internal `ChangeRequest`, and runs it through the agent graph.
- `GraphSnapshot`: reports the six graph nodes and eight workflow edges for a future dashboard.
- `HardwareJobStatus`: returns ordered hardware lifecycle events, open gates, and artifact count for a graph-owned hardware job.
- `ResolveHardwareGate`: records an explicit assembly or device-gate decision. Pass the original `prompt` and `request_id` to resume the graph automatically when the accepted job reaches success.

Run `jac start main.jac --no-client` to expose the public walkers
through Jac's API-only server runtime. The full-stack app already consumes the
same graph, activation history, hardware artifacts, and gate endpoints.

```bash
curl -X POST http://localhost:8000/walker/SubmitChange \
  -H 'Content-Type: application/json' \
  -d '{"prompt":"Make the active sample count more prominent"}'

curl -X POST http://localhost:8000/walker/GraphSnapshot \
  -H 'Content-Type: application/json' \
  -d '{}'

curl -X POST http://localhost:8000/walker/HardwareJobStatus \
  -H 'Content-Type: application/json' \
  -d '{"job_id":"<hardware-job-id>","after_sequence":0}'
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

### Event Transport and Monitoring

The Jac UI polls the durable JSONL activation sink written by `_emit_event` in
`orchestrator/adapters.jac`; SSE or WebSocket delivery remains a production
transport upgrade. `GraphSnapshot` supplies the topology rendered by the UI.

Monitoring currently accepts configured checks without launching a browser.
Replace `_monitor` with browser, process-log, HTTP, and serial adapters for
production runtime evidence.

### ESP32

When the planner selects `device`, the graph calls
[`orchestrator/hardware_bridge.jac`](orchestrator/hardware_bridge.jac), not the
legacy `_deploy` device placeholder. The bridge creates an idempotent hardware
job and mirrors its lifecycle events, revision ID, job ID, and open gate IDs
onto the `device` graph activations.

Ordinary device prompts use `plan` mode: the service generates the validated
breadboard design, ordered assembly SVGs, Wokwi diagram, and constrained
MicroPython firmware bundle without opening a serial device. Explicit flash or
deploy prompts use guarded `deploy` mode and stop at the required hardware
gate. Once hardware succeeds, graph Deployment excludes `device` from its
generic deployment adapter, and Monitoring rechecks the hardware job before
running the ordinary acceptance checks.

The WireJac UI renders `assembly.json` and `step-NN.svg` artifacts before
offering gate acceptance. It never infers a flash or assembly decision from
graph progress alone.

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
