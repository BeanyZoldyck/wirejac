# Coordinator API

WireJac exposes authenticated Jac functions for a separate coordinator UI.
Start the service from the repository root:

```bash
./scripts/start-local.sh
```

The default base URL is `http://127.0.0.1:8000`. The service binds to loopback,
disables Jac's admin portal, and uses a persistent local JWT secret created by
the launcher. Set `WIREJAC_JWT_SECRET` explicitly in managed deployments. Use
`/healthz` for readiness, `/openapi.json` for the generated contract, and
`/docs` for Swagger. All function calls below use `POST`. Successful Jac
responses place the function return value in `data.result`.

## Authenticate

Register a local user:

```http
POST /user/register
Content-Type: application/json

{
  "identities": [
    {"type": "username", "value": "wirejac-coordinator"}
  ],
  "credential": {
    "type": "password",
    "password": "use-a-strong-local-password"
  }
}
```

Log in:

```http
POST /user/login
Content-Type: application/json

{
  "identity": {
    "type": "username",
    "value": "wirejac-coordinator"
  },
  "credential": {
    "type": "password",
    "password": "use-a-strong-local-password"
  }
}
```

Read the token from `data.token` and send it with every function request:

```http
Authorization: Bearer <token>
```

Jac isolates jobs under the authenticated caller's root. A coordinator must
not share one service account across tenants that require data isolation.

## Submit a Job

```http
POST /function/submit_job
Authorization: Bearer <token>
Content-Type: application/json

{
  "hardware_request": {
    "project_id": "phone-snatch-training",
    "prompt": "Build an ESP32 motion detector that reports snatch events",
    "board_profile": "doit-esp32-devkit-v1-30pin",
    "allowed_inventory": [
      "gy521-mpu6050",
      "led-5mm-red",
      "resistor-220ohm",
      "button-6mm"
    ],
    "integration": {
      "event_schema_version": "1.0",
      "backend_endpoint": "https://training.example.test/events",
      "backend_secret_ref": "env:WIREJAC_DEVICE_TOKEN",
      "expected_ack_event": "event.accepted"
    },
    "execution_mode": "plan",
    "device_selector": "",
    "provision_policy": "never",
    "secret_refs": {},
    "metadata": {}
  },
  "idempotency_key": "phone-snatch-hardware-v1"
}
```

For physical deployment, set `execution_mode` to `deploy`, provide a stable
`/dev/serial/by-id/...` selector, and set
`metadata.expected_mac` after identity confirmation. Provisioning remains
disabled unless `provision_policy` is explicitly `allow_if_needed` or `force`.
Secret values are not accepted in this contract; only `env:`, `keyring:`, or
`vault:` references are valid.

The response includes `job.job_id`, `job.revision_id`, and the initial status.
Reusing the same idempotency key returns the original job instead of creating
another one.

## Function Surface

| Function path | Request fields | Purpose |
| --- | --- | --- |
| `/function/submit_job` | `hardware_request`, `idempotency_key` | Create an idempotent job and launch it |
| `/function/revise_job` | `job_id`, `hardware_request`, `reason`, `idempotency_key` | Add an immutable revision to a stopped job |
| `/function/get_job` | `job_id` | Read job, revisions, gates, artifacts, events, issues, and verification |
| `/function/list_jobs` | optional `project_id` | List jobs owned by the caller |
| `/function/cancel_job` | `job_id`, optional `reason` | Request cancellation at a safe phase boundary |
| `/function/resolve_gate` | `job_id`, `gate_id`, `accepted`, `resolution_note`, `idempotency_key` | Record a revision-scoped user decision |
| `/function/resume_job` | `job_id` | Retry a blocked phase after its cause is fixed |
| `/function/discover_devices` | empty object | Discover stable supported serial devices |
| `/function/get_capabilities` | empty object | Report hooks, tools, token, firmware, and host access |
| `/function/get_artifacts` | `job_id`, optional `revision_id` | List immutable artifacts for a revision |
| `/function/get_artifact_content` | `job_id`, `artifact_id` | Retrieve bytes after server-side SHA-256 verification |
| `/function/get_events` | `job_id`, optional `after_sequence` | Poll ordered lifecycle events |
| `/function/stream_events` | `job_id`, optional cursor and timing fields | Stream events until idle, blocked, gated, or terminal |

Send `{}` to functions with no required parameters. Treat the generated
OpenAPI document as the source of truth for concrete response schemas.

## Coordinator Flow

1. Call `get_capabilities`, then `submit_job` with a unique idempotency key.
2. Follow progress with `get_events` or `stream_events`; retain the highest
   observed sequence as the next cursor.
3. When status is `assembly_required`, fetch `assembly.json` and every
   `step-NN.svg`. Render these before offering gate acceptance.
4. Resolve only a gate whose `revision_id` matches the job's current
   `revision_id`.
5. For an unpinned device, show the stable path, chip, and MAC from the
   `device_selection` gate. Submit a revision with that MAC before deployment.
6. On `blocked`, fix the named external condition and call `resume_job`, or
   submit a revision when an immutable request field must change.
7. On success, fetch `verification-manifest.json` and verify artifact hashes
   before presenting completion.

Never resolve the assembly gate automatically. Device discovery, simulation,
provisioning, deployment, and rollback are host operations, so the coordinator
must display their evidence rather than infer success from job progress alone.
