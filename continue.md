# WireJac Continuation Specification

## Goal

Finish the two web surfaces and deploy the accelerometer Meta app:

1. Keep `frontend/` as the WireJac orchestration dashboard backed by real Jac
   graph topology, request history, and activation events.
2. Replace the legacy static accelerometer demo in `workspace/client` with its
   Jac client build.
3. Deploy the Meta app to the existing private S3 bucket and CloudFront
   distribution through `WirejacDevStack`.
4. Verify the cloud samples API, deployed UI, and orchestration event display
   without exposing credentials in source, logs, artifacts, or agent context.

## Architecture That Must Be Preserved

- The Meta app and device call the Lambda Function URL samples API with
  `X-Api-Key`.
- The Lambda role, not the browser, accesses DynamoDB `wirejac-samples`.
- The browser must never receive AWS access keys, secret keys, session tokens,
  or unrestricted AWS permissions.
- Runtime API configuration is written during deployment and is not committed.
- `frontend/` is a separate orchestration dashboard. It must not be confused
  with the accelerometer product UI in `workspace/client`.
- Physical device deployment remains gated by stable serial identity, verified
  ESP32 MAC, backup, assembly confirmation, and explicit approval.

The current `workspace/client/client.md` section describing direct browser
Cognito/DynamoDB access is stale and conflicts with `README.md`,
`workspace/client/api-spec.md`, and the deployed infrastructure. Update it to
describe the Lambda API boundary before considering the client contract done.

## Current State

### Orchestration Dashboard

- Real request history and event APIs have been added in `main.jac`,
  `orchestrator/adapters.jac`, and `frontend/endpoints.sv.jac`.
- `frontend/` components now project graph status and chat/tool activity from
  persisted activation events.
- Unsupported JSX statement slots were removed from `Sidebar.cl.jac` and
  `nodes.cl.jac`.
- `frontend/jac.toml` now correctly uses `[plugins.client.vite]`, allowing its
  external TSX components to resolve dependencies from
  `.jac/client/node_modules`.
- This command passes and produces a client bundle:

  ```sh
  cd frontend
  jac build main.jac --client web
  ```

- `jac check main.jac` passes with the expected warning for the npm CSS import.
- Individual client modules still produce analyzer warnings/errors when checked
  outside their entry module. Treat the successful entry build as the current
  compiler integration check, but fix real runtime failures discovered in the
  browser.

### Meta App

- `workspace/client/index.html`, `app.js`, and `styles.css` are the legacy
  static demo currently selected by CDK.
- `workspace/client/main.jac` is the intended replacement and contains the
  three-axis chart, session selection, polling, summary metrics, and reading
  table.
- `workspace/client/jac.toml` has been changed to `typecheck = false`, but the
  build still fails before emitting bytecode:

  ```text
  Error: Build failed: No bytecode found for
  workspace/client/main.jac
  ```

- `jac check main.jac` reports unresolved client globals including `fetch`,
  `encodeURIComponent`, `Date`, `setInterval`, and `clearInterval`. It also
  reports expressions such as `error and <div ...>` as invalid client JSX
  usage.
- The Jac app currently fetches `/config.json`, while the deployment Lambda
  writes `/config.js`. These must be made consistent.
- `infrastructure/lib/meta-app-hosting.ts` currently uploads the entire
  `workspace/client` source directory instead of the Jac build output.

### Infrastructure

- Lambda handlers exist for the samples API and runtime configuration writer.
- SSM parameters and CloudFormation outputs exist for the Meta app URL, bucket,
  and CloudFront distribution ID.
- `npm run build` passes in `infrastructure/`.
- `npm test -- --runInBand` passes in `infrastructure/`.
- Both Python Lambda handlers pass `python3 -m py_compile`.
- No deployment has been performed during this continuation.

## Required Work

### 1. Make the Meta App Compile

Use the Jac MCP documentation and installed compiler as the source of truth.
Do not guess JavaScript interop syntax.

1. Read the Jac client documentation for browser APIs, effects, async HTTP,
   timers, and supported JSX conditional expressions.
2. Replace or correctly qualify unresolved browser globals in
   `workspace/client/main.jac`.
3. Replace JavaScript-only syntax such as `new Date()` with valid Jac client
   syntax or a narrow imported helper.
4. Replace boolean JSX expressions with explicit ternaries or precomputed
   `JsxElement` values, as done in `frontend/`.
5. Keep polling cleanup so the interval is removed when the component unmounts.
6. Keep malformed/error responses visible to the user without logging the API
   key or response headers.
7. Run until both commands succeed from `workspace/client`:

   ```sh
   jac check main.jac
   jac build main.jac --client web
   ```

If full analyzer success is impossible because the installed compiler reports
known browser-global portability warnings, document the exact warnings and
require a successful production bundle plus browser verification. Do not hide
actual parse or code-generation errors by disabling diagnostics.

### 2. Align Runtime Configuration

Use one runtime configuration format end to end. The preferred minimal path is
JSON because the Jac client already uses `fetch`:

1. Change `infrastructure/lambda/write-config/handler.py` to write
   `config.json` as `application/json; charset=utf-8` with
   `Cache-Control: no-store, max-age=0`.
2. Change the Lambda physical ID, S3 grant, invalidation path, construct
   comments, README references, and tests from `config.js` to `config.json`.
3. Keep only `apiBaseUrl`, `apiKey`, and the default `sessionId` in the runtime
   file.
4. Ensure neither `config.json` nor generated deployment configuration is
   tracked by git.
5. Never print or return the API key in CloudFormation output, custom-resource
   response data, deployment logs, or test snapshots.

The shared browser API key is intentionally readable by users of this
hackathon UI; it is not an AWS credential. Continue to enforce least privilege
in the Lambda execution role and never replace this design with direct browser
DynamoDB access.

### 3. Deploy the Jac Build Artifact

1. Change `MetaAppHosting` to use
   `workspace/client/.jac/client/dist` as the `BucketDeployment` source.
2. Do not upload `.jac` source, `main.jac`, markdown role files, package
   manifests, the legacy `app.js`, or a checked-in runtime configuration.
3. Ensure the generated `index.html`, hashed client JavaScript, CSS, fonts, and
   other Vite assets are all included.
4. Document that the Meta app build must run before CDK synth/deploy.
5. Add a non-secret repeatable command or package script for the build step.
   Keep orchestration and deployment decisions in Jac; external process and
   filesystem execution must remain behind the existing narrow Python adapter.
6. Extend the non-device deployment adapter so a client deployment:
   - builds `workspace/client` with `jac build main.jac --client web`;
   - validates that `.jac/client/dist/index.html` exists;
   - obtains the target bucket/distribution through stack outputs or SSM;
   - syncs only the generated distribution;
   - invalidates CloudFront only after a successful upload;
   - returns a useful artifact URL and sanitized failure message.
7. Do not allow generated code or an LLM workspace agent to invoke arbitrary
   shell, S3, CloudFront, CDK, or filesystem commands. Deployment remains an
   orchestrator-owned adapter operation.

If CDK continues to own `BucketDeployment`, avoid performing a second manual S3
sync in the same deployment path. Select one owner for upload/invalidation and
test that path. The smallest current change is to build first and let CDK deploy
the generated `dist` directory.

### 4. Validate Before AWS Changes

Run the repository-required checks:

```sh
jac check main.jac hardware/*.jac
jac test
```

Run Python adapter tests through the project environment. Hardware-in-loop
tests must remain disabled unless `WIREJAC_HIL=1` is explicitly set.

Run frontend builds:

```sh
cd frontend
jac build main.jac --client web

cd ../workspace/client
jac check main.jac
jac build main.jac --client web
```

Run infrastructure checks:

```sh
cd infrastructure
npm run build
npm test -- --runInBand
python3 -m py_compile lambda/samples-api/handler.py
python3 -m py_compile lambda/write-config/handler.py
npx cdk synth WirejacDevStack
```

Add or update tests for:

- the configuration writer's JSON object, content type, cache control, object
  key, and CloudFront invalidation path;
- the Meta app deployment source path;
- samples API health, authentication rejection, write, and session query;
- client handling of empty samples, successful samples, and failed API calls;
- event ordering by `sequence` and request-history status projection.

### 5. Review and Deploy

Deployment target:

- Stack: `WirejacDevStack`
- Region: `us-west-2`
- Account: `852353855241`

Credentials are already present in ignored local environment configuration.
Do not copy their values into commands, files, output, or this specification.

1. Confirm caller identity without printing secret material.
2. Run `cdk diff` and inspect replacements, IAM expansion, public access, and
   data-loss risk.
3. Require explicit operator approval before `cdk deploy` if the diff includes
   resource replacement, IAM broadening, or destructive changes.
4. Deploy `WirejacDevStack` only after all validation passes.
5. Retrieve the Meta app URL through the stack output or
   `/wirejac/dev/meta-app-url`; do not expose the API key.

### 6. Seed and Verify End to End

Use the samples API rather than direct DynamoDB writes for application-level
verification.

1. Check `/api/health`.
2. Submit deterministic sample readings for `training-001` with timestamps and
   distinct x/y/z values.
3. Query the same session and verify ordering and values.
4. Open the CloudFront Meta app in a browser.
5. Confirm runtime configuration loads without being cached.
6. Confirm the UI transitions from loading to live, renders all three traces,
   displays sample count and duration, and shows recent readings.
7. Verify desktop and mobile layouts.
8. Check browser console and network logs for errors and accidental credential
   disclosure. The request header may contain the shared API key, but it must
   not be written to application logs or rendered in the page.
9. Open `frontend/` against the Jac service and submit a request.
10. Confirm the graph uses real activation statuses and persisted tool/event
    history rather than the old timer simulation.

## Acceptance Criteria

- `frontend/` and `workspace/client` both produce successful Jac web bundles.
- The Meta app S3 deployment contains only generated web assets plus runtime
  configuration.
- CloudFront serves the Jac accelerometer dashboard over HTTPS.
- The dashboard reads session samples through the Lambda API and never accesses
  DynamoDB directly.
- Empty, loading, API error, and live-data states are visibly distinct.
- No AWS credentials or OpenRouter credentials appear in git, bundles, graph
  nodes, generated artifacts, simulation uploads, or logs.
- Infrastructure TypeScript, tests, Lambda syntax checks, CDK synth, repository
  Jac checks, and Jac tests pass.
- The WireJac orchestration dashboard displays real topology, request history,
  ordered activation events, tool activity, failures, deployment state, and
  monitoring state.
- No physical ESP32 is flashed without all hardware approval gates.

## Files Expected to Change

- `workspace/client/main.jac`
- `workspace/client/jac.toml`
- `workspace/client/client.md`
- `workspace/client/styles.css` if presentation fixes are needed
- `infrastructure/lib/meta-app-hosting.ts`
- `infrastructure/lambda/write-config/handler.py`
- infrastructure tests covering hosting and config writing
- `infrastructure/README.md`
- root `README.md`
- `orchestrator/adapters.jac` or a narrow deployment adapter module
- deployment/monitoring tests

Do not delete or rewrite unrelated staged or unstaged changes. The worktree may
contain concurrent user or agent edits; inspect each target file immediately
before patching it.
