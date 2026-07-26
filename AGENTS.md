# WireJac Hardware Service

The main WireJac UI is developed separately. This repository owns the headless
hardware subsystem and its integration contract.

## Boundaries

- Keep orchestration, graph state, validation, and artifact contracts in Jac.
- Keep USB, serial, subprocess, filesystem, and Wokwi SDK calls behind narrow
  Python adapters.
- Never give generated code or an LLM unrestricted shell or filesystem access.
- Never select the first serial port. Bind deployments to an explicit stable
  port and verified ESP32 MAC.
- Never persist credentials in graph nodes, generated artifacts, logs, or
  simulation uploads.

## Validation

- Run `jac check main.jac hardware/*.jac`.
- Run `jac test`.
- Run Python adapter tests through the project environment.
- Hardware-in-loop tests must require `WIREJAC_HIL=1`.

