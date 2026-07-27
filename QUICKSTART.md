# WireJac Quick Start

## Run the App

```bash
cd /home/mason/jac/wirejac
./scripts/start-app.sh
```

Set `OPENROUTER_API_KEY` before submitting a build. The launcher links the root
Jac package into the frontend project and starts the Jac UI plus RPC API at
<http://localhost:8000/>.

Use this full-stack prompt:

```text
Create a phone snatch data collection system with a dashboard, an event API,
and an ESP32 GY-521 recording button.
```

Expected result:

- Coordinator selects Client, Server, and Device.
- Client and Server run contained agent builds and validation.
- Device produces a validated MicroPython bundle, Wokwi diagram, assembly JSON,
  and 14 progressive breadboard SVGs.
- Deployment and Monitoring complete without accessing the ESP32.

Use an explicit flash prompt to exercise the guarded physical path:

```text
Prepare and flash an ESP32 phone-snatch detector with a GY-521 and recording
button.
```

That request must stop at `assembly_required`, show 18 assembly SVGs, and expose
Approve/Reject controls. Do not approve until the unpowered circuit and device
identity have been checked.

## Agent Configuration

```bash
OPENROUTER_API_KEY="..." ./scripts/start-app.sh
```

## Verify

```bash
jac check main.jac orchestrator/*.jac hardware/*.jac tests/*.jac
jac test
jac x pytest -q tests/python
```

The exact breadboard layout is in [`docs/hardware-profile.md`](docs/hardware-profile.md).
