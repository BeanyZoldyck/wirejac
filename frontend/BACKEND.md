# wirejac — Backend Handoff Guide

**Read this first.** The frontend is complete but runs entirely on **mock data**.
Your job: build the real **Object-Spatial (OSP) backend** — graph `node`s,
`walker`s, and `by llm()` — and expose it through `.sv.jac` endpoints that match
the **contract** in §2. Then flip the frontend from mock → live at the single
**seam** in §4. Nothing else in the UI needs to change.

> Why this matters for judging: the two heaviest-weighted criteria ("Use of Jac"
> and "Depth of Agentic Behavior") are exactly the parts that are mocked today.
> This is the highest-leverage work left.

---

## 1. What exists (frontend, done)

A Jac fullstack app (dark mode, "Mission Control" UI):
- **Sidebar** of build projects → **landing prompt** → **dashboard**: top pipeline
  stepper + timer, a **React Flow graph canvas** (70%), a **streaming chat** with
  inline tool-calls (30%), and a **monitoring strip**. Detailed/Simple node views.
- Everything animates from **one mock "run clock"** in `run_script.cl.jac`. That
  file is your spec — it defines every shape the UI consumes. Reproduce those
  shapes for real and the UI lights up unchanged.

Key files: `frontend.cl.jac` (shell + Dashboard clock), `GraphCanvas.cl.jac`,
`nodes.cl.jac`, `ChatPanel.cl.jac`, `MonitoringBar.cl.jac`, `TopBar.cl.jac`,
`run_script.cl.jac` (**the mock to replace**).

The architecture you're implementing is described in `../jacgraph.md` (OSP
topology) and `../pijac.txt` (the ESP32/Pi hardware loop).

---

## 2. The data contract (implement these shapes server-side)

The UI consumes plain dicts. Match these exactly (see `run_script.cl.jac`):

```jac
# A graph node
{ "id": str,            # "coordinator" | "server" | "client" | "device" | "deployment" | "monitoring"
  "kind": str,          # "coordinator" | "worker" | "deployment" | "monitoring"
  "label": str, "subdir": str,
  "status": str }       # "idle" | "queued" | "working" | "passing" | "failing" | "deployed"

# A graph edge
{ "source": str, "target": str, "kind": str }   # kind: "flow" | "feedback"

# A chat message (agent turn), streamed as the run progresses
{ "role": "agent", "text": str, "tools": [ToolCall] }

# A tool call (renders in ToolCallsSection)
{ "tool_name": str, "tool_category": str, "integration_name": str,
  "message": str, "inputs": dict, "output": str }

# Monitoring state
{ "status": str,        # "idle" | "degraded" | "operational"
  "line": str, "up": int }   # up = 0..8 uptime ticks

# Pipeline phase (top-bar stepper): "plan" | "build" | "deploy" | "monitor"
```

---

## 3. What to build (the OSP backend)

In `.sv.jac` (server codespace). This is the real agentic engine:

1. **Graph-native data model** — `node Coordinator`, `node Worker` (server/client/
   device), `node Deployment`, `node Monitoring`; connect them with edges
   (`root ++> ...`, `-->`). See the `jac-node-edge-patterns` guide.
2. **Walkers** (the agents) — `planner`, `builder`, `deploy`, `monitor` that
   traverse the graph. See `jac-walker-patterns`. This is your multi-agent
   coordination.
   - `planner` → **`by llm()`** to draft the JSON architecture spec, then
     deposits it into each worker node.
   - `builder` → **`by llm()`** to generate code into the node's `./workspace/*`
     subdir, runs the compile via Python interop, and **loops in place on
     failure** until it passes (real autonomy + tool use). See `jac-by-llm`.
   - `deploy` → gathers artifacts, runs staging (arduino-cli / pnpm).
   - `monitor` → reads ESP32 serial + pings the server; on anomaly, sends a
     signal back up to Coordinator (the feedback edge).
3. **Endpoints** the frontend calls:
   ```jac
   def:pub submit_prompt(prompt: str) -> str;      # create a run, spawn planner, return run_id
   def:pub get_run(run_id: str) -> dict;           # { nodes, edges, chat, monitoring, phase }
   ```
   For live updates, add a **streaming** endpoint (SSE) — see `jac-sv-streaming`.
   Persist graph state per run (see `jac-sv-persistence`).

---

## 4. The seam (how to flip the frontend from mock → live)

The whole mock lives behind these `def:pub` functions in **`run_script.cl.jac`**,
consumed by the UI keyed off a client `clock` (ms):

| Mock function (run_script) | Consumed by | Replace with |
|---|---|---|
| `RUN_NODES`, `RUN_EDGES` | GraphCanvas | server topology (`get_run`) |
| `node_status(id, clock)` / `node_revealed(id, clock)` | GraphCanvas | live node status from `get_run` |
| `chat_upto(clock)` | ChatPanel | live chat/tool stream |
| `mon_state(clock)` | MonitoringBar | live monitoring |
| `pipeline_phase(clock)` | TopBar | live phase |

**Recommended swap:** in `frontend.cl.jac`'s `Dashboard`, replace the `setInterval`
clock with an `async can with entry` that calls `get_run(run_id)` (poll, then
upgrade to the SSE stream) and stores the result in `has run: dict`. Pass `run`
down to the panels instead of `clock`; each panel reads `run["nodes"]`,
`run["chat"]`, etc. The component JSX **doesn't change** — only the data source.

Keep `run_script.cl.jac` as a fallback/demo mode until the endpoints are live.

`submit_prompt` is already wired at the UI: `frontend.cl.jac` → `create_from_prompt`
captures the prompt when a build is submitted — call your endpoint there.

---

## 5. Jac gotchas we hit (save yourself the pain)

- **`jac check` passing ≠ the client compiles.** The client `jac2js` compiler is
  stricter. Watch the `jac start --dev` log for `Unexpected token` / `Missing ';'`
  — those mean the served JS is stale even though `jac check` says PASSED.
- **Cross-module exports need `:pub`** on the archetype/enum/glob (not just `def`).
  A plain `obj Foo` / `enum Bar` / `glob baz` compiles with **no `export`** →
  importing it elsewhere fails at runtime → **blank page**. Use `obj:pub`,
  `enum:pub`, `glob:pub`.
- **Enum members default to `null`** in compiled client JS. Give explicit values:
  `enum:pub Status { idle = "idle", ... }` — else everything reads "null".
- **The client compiler rejects dict subscript assignment** `d["k"] = v`
  (`Duplicate declaration of '['`). Build dicts as complete literals.
- **Can't call a JSX-returning function inside a statement slot** — write the JSX
  inline. (Helpers returning `str` for classNames are fine.)
- **`.tsx` / `.style.css` files copy into the build only on a file-CHANGE event**
  while `jac start --dev` runs; a fresh start doesn't copy them. Touch the file to
  trigger `✔ Copied`. Import a `.tsx` from `.cl.jac` with a quoted relative path.
- **`node_modules` lives at `.jac/client/node_modules`**, not the project root.
- Benign warnings: `W1051` (unresolved type on imported npm/tsx JSX), `W1100`
  (CSS subpath import). Not errors.
- **`jac check` alone won't catch runtime crashes.** Verify in a real browser:
  `jac browse open localhost:8000`, `jac browse console` (read errors),
  `jac browse screenshot out.png`.

---

## 6. Run & verify

```bash
# toolchain (macOS): jaclang needs Python 3.12+; jac-client for fullstack
pipx install jaclang --python python3.14
pipx inject jaclang jac-client

cd frontend
jac install
jac start --dev            # http://localhost:8000 (app) + :8001 (API)

# Get the 37 bundled Jac reference guides as local docs / agent skills:
jac guide --export ./.claude/skills
jac guide jac-walker-patterns      # or jac-by-llm, jac-sv-endpoints, ...
```

Start with the guides for the parts you're building: `jac-node-edge-patterns`,
`jac-walker-patterns`, `jac-by-llm`, `jac-sv-endpoints`, `jac-sv-streaming`,
`jac-sv-persistence`, `jac-fullstack-patterns`.
