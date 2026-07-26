# WireJac Agent Graph

This repository contains a runnable Jac-native autonomous agent graph for an embedded data-collection project. Jac nodes represent the Coordinator, Client, Server, Device, Deployment, and Monitoring locations. A `ChangeRequest` walker carries one prompt through the graph.

## Requirements

- A current Jac installation.
- Node and npm for the demo client validation.
- An OpenRouter key for live agents.

The configured default model is `deepseek/deepseek-v4-flash`. Override it with `OPENROUTER_MODEL` if necessary.

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
workspace/server  - Jac API placeholder
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
