# Runtime Modes and Gates

Every request becomes an immutable revision in the caller's Jac graph. A
revision progresses through planning, validation, generation, and then the
mode-specific phases below. Any revision can be inspected through events and
artifacts while it runs.

## Plan

`execution_mode: "plan"` stops after generation with `succeeded`. It produces
the full design, assembly sequence, Wokwi diagram, and MicroPython bundle but
does not contact Wokwi or open a serial device.

Use this for coordinator previews and UI iteration.

## Simulate

`execution_mode: "simulate"` builds a 4 MiB ESP32 flash image from the pinned
MicroPython image plus the generated LittleFS filesystem. It uploads that
image and `diagram.json` through `wokwi-client`, applies MPU6050 acceleration
and rotation plus button controls, captures serial JSON, and disconnects.

The run passes only when it observes:

- `wirejac.ready`
- `sensor.detected`
- `snatch.detected`

Without `WOKWI_CLI_TOKEN`, a simulation-only request becomes `blocked` with
`WOKWI_UNAVAILABLE`. Wokwi is an external service even though the SDK call and
evidence presentation remain inside WireJac.

## Deploy

`execution_mode: "deploy"` always opens `assembly_confirmation` after
generation. Only acceptance continues the physical path.

After the gate:

1. Wokwi runs when a token is available. If it is unavailable, deploy mode
   records simulation as skipped and continues.
2. The service requires a stable `/dev/serial/by-id/...` selector.
3. It identifies the chip and verifies the immutable
   `metadata.expected_mac` when supplied. A confirmed identity is persisted as
   `device-identity.json` for later retries.
4. It probes for MicroPython while holding the device transaction lock.
5. If provisioning is authorized and required, one locked transaction reads a
   full flash backup, verifies the backup metadata, and writes the pinned,
   SHA-verified MicroPython image. A write or verification failure restores
   the full backup before releasing the lock.
6. A second device-wide transaction rechecks the MAC, uploads the release to
   the inactive A/B slot, records previous and boot-failure metadata, and
   activates the new slot last.
7. It resets the device and captures serial output for 12 seconds while still
   holding that lock. Verification requires `sensor.detected`,
   `wirejac.ready`, and `wirejac.heartbeat`.
8. Failed verification restores the previous slot before the lock is
   released. Persistent operation journals let an interrupted process resume
   verification or recovery without blindly repeating a destructive action.

## Provision Policies

| Policy | Behavior |
| --- | --- |
| `never` | Reuse an existing responsive MicroPython runtime. Block rather than flash when MicroPython is unavailable. |
| `allow_if_needed` | Reuse MicroPython when present; otherwise back up flash and provision the pinned image. |
| `force` | Back up flash and provision the pinned image even when MicroPython responds. |

Provisioning is a destructive operation and should never be inferred from a
prompt. The coordinator must submit the policy explicitly.

## Gates and Blocks

| Kind or code | Why it opens | Coordinator action |
| --- | --- | --- |
| `assembly_confirmation` | Deploy generation completed | Render `assembly.json` and `step-*.svg`; accept only after the user builds and inspects the unpowered circuit. |
| `device_selection` | Device identity was read but no expected MAC was supplied | Show the stable path, chip, and MAC from gate metadata; accept only after user confirmation. |
| `device_permission` | The service cannot read/write the selected serial device | Fix host permissions and reconnect if needed, then resolve the gate. Accepting without fixing access simply retries and fails again. |
| `DEVICE_SELECTOR_REQUIRED` | The immutable request has no stable device selector | Submit a new revision containing the selector. |
| `PROVISIONING_NOT_AUTHORIZED` | MicroPython is absent and policy is `never` | Submit a new revision with `allow_if_needed` after explicit approval. |
| `WOKWI_UNAVAILABLE` | A simulation-only request has no token | Configure `WOKWI_CLI_TOKEN`, then resume the blocked job. |

Rejecting any open gate records the decision and leaves the job `blocked`.
`resume_job` retries a blocked phase only when no gate remains open. Changes to
prompt, device selector, expected MAC, mode, or policy require `revise_job`.
Every gate records the revision that opened it. Creating a revision rejects
any still-open gate from the prior revision, and an old gate ID cannot resume
new work.

On Linux, serial adapters commonly belong to the `dialout` group. Inspect the
stable link and group before changing permissions:

```bash
ls -l /dev/serial/by-id/
groups
```

Prefer a persistent group membership fix and a new login session. Do not make
the device world-writable and do not replace the stable selector with
`/dev/ttyUSB0`.

## Generated Artifacts

| Artifact | Purpose |
| --- | --- |
| `hardware-intent.json` | Typed LLM or reviewed planning output |
| `hardware-spec.json` | Validated board, components, GPIO assignments, and nets |
| `visualization.json` | UI-ready components, holes, routes, colors, and steps |
| `assembly.json` | Ordered placement and wiring instructions |
| `step-NN.svg` | One accessible breadboard view per assembly step |
| `diagram.json` | Wokwi parts and connections |
| `firmware-bundle.zip` | Reproducible constrained MicroPython release |
| `firmware-manifest.json` | SHA-256 and size for every bundled file |
| `simulation-evidence.json` | Controls, serial output, and observed Wokwi events |
| `wokwi-flash.bin` | Merged simulation flash image |
| `device-identity.json` | Stable selector, chip family, and confirmed immutable MAC |
| `flash-backup.bin` | Full pre-provisioning device backup |
| `provisioning-evidence.json` | Locked backup/provision result, including recovery status |
| `deployment-evidence.json` | Locked identity check, A/B activation, serial verification, and rollback result |
| `serial-verification.json` | Physical serial capture and observed events |
| `verification-manifest.json` | Final verification checks |
| `rollback-evidence.json` | Previous-slot restoration result when applicable |

Artifacts use immutable `artifact://` URIs and SHA-256 metadata. Coordinators
should retrieve content through `get_artifact_content`, verify the returned
hash, and render only the declared media type.
