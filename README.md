# WireJac Hardware Service

WireJac's headless hardware subsystem turns a coordinator request into a
validated ESP32 design, MicroPython firmware, breadboard assembly artifacts,
optional Wokwi evidence, and a guarded physical deployment.

The main WireJac graph and chat UI lives elsewhere. This repository provides
the coordinator-facing service boundary it can call and the artifacts it can
render.

## What It Does

- Plans a typed hardware intent with Jac `by llm`, or uses the reviewed
  phone-snatch fixture for deterministic development.
- Compiles intent into Jac graph nodes for boards, components, pins, nets,
  placements, and assembly steps.
- Runs deterministic electrical checks against an exact board and component
  catalog.
- Generates a machine-readable netlist, step-by-step SVG breadboard views,
  Wokwi `diagram.json`, and a constrained MicroPython bundle.
- Runs Wokwi through its SDK in the service process and verifies emitted
  serial events.
- Discovers only stable `/dev/serial/by-id` devices, pins the ESP32 identity,
  backs up and restores flash transactionally, and deploys/verifies an inactive
  A/B slot under a device-wide lock.

Jac owns lifecycle state, OSP topology, contracts, gates, and orchestration.
Narrow Python adapters own filesystem, subprocess, serial, USB, flash, and
Wokwi SDK operations. Generated code never receives a shell or unrestricted
host filesystem.

## Supported MVP Kit

The current compiler supports one exact profile:

- DOIT ESP32 DevKit V1, 30-pin
- GY-521 MPU6050 accelerometer/gyroscope
- 5 mm LED with a 220 ohm series resistor
- 6 mm momentary pushbutton
- 400-point half breadboard with continuous power rails

The safe, physically accessible assignments are GPIO21 for SDA, GPIO22 for
SCL, GPIO18 for the LED, and GPIO19 for the active-low button. The ESP32 uses
a one-header overhang mount because a fully inserted 30-pin DevKit hides all
connection strips on a half breadboard. See
[docs/hardware-profile.md](docs/hardware-profile.md) before assembling or
powering the circuit.

## Quick Start

Jac 0.34.7 and Python 3.12 or newer are required by `jac.toml`.

```bash
jac install --dev
jac run demo.jac
```

The demo defaults to `plan` mode and the reviewed phone-snatch fixture. It
prints the job, gate, and immutable artifact metadata as JSON. Artifacts are
stored below `~/.wirejac/runs/artifacts` unless
`WIREJAC_WORKSPACE_ROOT` is set.

Pass a local prompt as arguments:

```bash
jac run demo.jac "Build an ESP32 motion alarm with a test button"
```

Use Jac's configured `by llm` provider for non-fixture generation:

```bash
WIREJAC_GENERATION=llm jac run demo.jac \
  "Build an ESP32 motion alarm with a test button"
```

Set `BYLLM_DEFAULT_MODEL` and the matching provider key before that command.
The `.env.example` file lists supported runtime settings, but Jac does not
implicitly source it.

## Run the Service

```bash
./scripts/start-local.sh
```

The API listens only on `127.0.0.1:8000` by default. The launcher creates a
mode-0600 JWT signing secret at `~/.wirejac/jwt-secret` when none is supplied,
and the Jac admin portal is disabled. Swagger is available at `/docs`; all
hardware functions are authenticated and use the caller's isolated Jac root.
The coordinator flow and exact request bodies are in
[docs/coordinator-api.md](docs/coordinator-api.md).

## Execution Modes

| Mode | Result |
| --- | --- |
| `plan` | Generates and validates all design, assembly, visualization, and firmware artifacts. It does not contact Wokwi or a device. |
| `simulate` | Runs the generated flash image through the Wokwi SDK and verifies expected serial events. `WOKWI_CLI_TOKEN` is required. |
| `deploy` | Stops at assembly confirmation, optionally simulates, identifies the selected ESP32, provisions MicroPython when authorized, activates an A/B release, and verifies serial output. |

Wokwi runs headlessly through `wokwi-client`; the user is not redirected to
another site. The coordinator UI can render the generated SVGs and simulation
evidence in-app. This service does not currently expose an interactive Wokwi
canvas.

Deployment must use a stable `/dev/serial/by-id/...` selector. The service
never chooses the first serial port. Supplying `metadata.expected_mac` pins
the request to that physical ESP32; otherwise the lifecycle opens a device
identity confirmation gate.

See [docs/runtime-modes.md](docs/runtime-modes.md) for every gate, provisioning
policy, artifact, and rollback rule.

## Verification

```bash
jac check main.jac demo.jac hardware/*.jac tests/*.jac
jac clean --data --force
jac test -v
jac x pytest -q tests/python
```

`jac clean --data --force` resets the local persisted test graph. It does not
remove the project virtual environment or the external artifact workspace.

## Layout

| Path | Responsibility |
| --- | --- |
| `hardware/contracts.jac` | Coordinator requests, status enums, views, gates, artifacts, and mutations |
| `hardware/graph.jac` | Persistent Jac job graph and physical topology |
| `hardware/orchestration.jac` | Lifecycle state machine and phase-hook boundary |
| `hardware/integration.jac` | Production phase hooks and constrained adapter calls |
| `hardware/planning.jac` | Typed `by llm` intent and MicroPython authoring |
| `hardware/circuit.jac` | Hardware IR and electrical validation |
| `hardware/breadboard.jac` | Deterministic placement, routing, and instructions |
| `hardware/visualization.jac` | UI model, Wokwi diagram, and assembly SVG generation |
| `hardware/firmware_tools.py` | Static source validation and reproducible firmware bundle |
| `hardware/adapters/` | Artifact, command, device, flash, serial, image, and Wokwi adapters |
| `demo.jac` | Synchronous local prompt runner |

## Safety Boundary

Do not resolve the assembly gate until the circuit is complete and inspected
with USB power disconnected. Never use a raw `/dev/ttyUSB*` path, bypass the
MAC check, inject credentials into requests or artifacts, or flash a device
without a verified backup and explicit provisioning policy.

Secret references may use `env:`, `keyring:`, or `vault:` prefixes. The current
MVP validates those references but does not resolve or upload them. Device-side
authorization must be provisioned through a future dedicated secret adapter;
it must not be placed in the generated firmware bundle.
