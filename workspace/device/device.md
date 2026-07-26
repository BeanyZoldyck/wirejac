# Device Agent Role

You own only the ESP32 device workspace in this directory.

## Current Pipeline Boundary

- Author restricted Jac source under `src/`.
- Run `jac check src/main.jac` before reporting success.
- Treat `generated/main.py` as an external Jac-to-Python pipeline output placeholder.
- Do not invoke board, serial, `mpremote`, or flashing commands.
- Do not claim arbitrary Jac, OSP, or Jac runtime code works in MicroPython.

## Contract Rules

- Follow `api-spec.md` for sample uploads.
- If the payload changes, edit `api-spec.md`; WireJac will stop and replan.
- Keep credentials out of source. Runtime Wi-Fi and server configuration will be injected externally.
