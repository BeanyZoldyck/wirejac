# wirejac — UI/UX Plan

> The frontend for a **pure-Jaclang OSP multi-agent CI/CD orchestrator**. A user
> describes what they want built; wirejac plans it, spins up worker agents to
> write + compile the code, deploys it, and monitors it live — all visualized as
> a graph that mirrors the underlying Jac Object-Spatial graph 1:1.
>
> Architecture reference: [`image.png`](./image.png), [`../jacgraph.md`](../jacgraph.md) (topology),
> [`../pijac.txt`](../pijac.txt) (hardware constraints).

---

## 1. Design language (global, already enforced)

Locked in via `frontend/styles/brand.css` — applies to every component automatically:

- **Super minimalistic & clean.** Generous whitespace, sparse UI, semantic color
  tokens only (`bg-background`, `text-muted-foreground`), no heavy shadows /
  borders / gradients. Content-first.
- **Squircle corners everywhere** (`corner-shape: squircle`, Apple-style
  superellipse) — ref: <https://www.arlan.me/vault/squircle>.
- **Elms Sans** as the default font everywhere — ref:
  <https://fonts.google.com/specimen/Elms+Sans>.
- Base: shadcn/ui primitives + Tailwind v4. Palette: zinc base + indigo accent
  (kept subtle). Theme via `jac retheme`.

---

## 2. Core flow (two screens)

### Screen 1 — Chat-first landing (the CTA)

- A single, centered, oversized prompt input. Placeholder framing the mental model:
  > **"build me ___ that does ___"**
  > e.g. *"build me a plant monitor that reads soil moisture on an ESP32 and shows it on a web dashboard"*
- Minimal chrome: just the wordmark + the input + a submit affordance. Nothing else.
- On submit, the prompt becomes the **Coordinator node's** initial prompt (feeds
  the `planner_walker`), and the view transitions into Screen 2.
- Transition is a smooth morph, not a hard page swap — the input "settles" into
  the Coordinator node at the top of the graph.

### Screen 2 — Live orchestration dashboard (70 / 30 split)

The heart of the product. Two panes side by side:

- **Left 70% — the graph canvas.** A **React Flow** (<https://reactflow.dev>,
  pkg `@xyflow/react`) canvas laying the Jac OSP graph out top-to-bottom
  (Coordinator → workers → Deployment → Monitoring). Nodes = Jac nodes, edges =
  walker paths.
- **Right 30% — a persistent chat UI.** The conversation that began on the
  landing page continues here: the **`PromptInputBox`** (adapted to our light
  theme) docked at the bottom, the message stream above it, and a
  **`ToolCallsSection`** block rendered inline whenever the wirejac agent calls a
  tool on the platform (stacked tool icons + expandable input/output).

Top-to-bottom layout of the left canvas (matching `image.png` / `jacgraph.md`):

```
                 ┌───────────────────────┐
                 │    COORDINATOR NODE    │   ← top; holds the prompt, generates
                 │  (prompt + JSON spec)  │     the JSON architecture spec
                 └───────────┬───────────┘
              ┌──────────────┼──────────────┐
              ▼              ▼              ▼
        ┌─────────┐    ┌─────────┐    ┌─────────┐   ← worker agents, orchestrated
        │ SERVER  │    │ CLIENT  │    │ DEVICE  │     in parallel; each bound to a
        │ worker  │    │ worker  │    │ worker  │     subdir (./workspace/*)
        └────┬────┘    └────┬────┘    └────┬────┘
             └──────────────┼──────────────┘
                            ▼
                 ┌───────────────────────┐
                 │    DEPLOYMENT NODE     │   ← final step; gathers artifacts,
                 │ (deploy scripts/ports) │     runs staging (server up, flash ESP32)
                 └───────────┬───────────┘
                             ▼
                 ┌───────────────────────┐
                 │    MONITORING NODE     │   ← reads serial / pings server;
                 │  (live status + logs)  │     feedback loop back up to Coordinator
                 └───────────────────────┘
```

Requirements the user called out, explicitly:

1. **Coordinator node on top.**
2. **Agent orchestration of workers** in the middle — you can *see* the
   Coordinator fan out to the Server / Client / Device workers and watch them
   work concurrently.
3. **Deployment node as the final node / step** downstream of all workers.
4. **Monitoring node** at the bottom, with a live-status feel (see §4).
5. A **feedback loop** edge from Monitoring back up to Coordinator (anomaly →
   re-dispatch a `builder_walker`), per `jacgraph.md` §4.

---

## 3. Node states & the "currently working" animation

Every node is a small status card on the canvas. State machine per node:

| State | Meaning | Visual |
| --- | --- | --- |
| `idle` | not started | muted, low opacity |
| `queued` | waiting on upstream | dim, subtle pulse |
| **`working`** | walker active on this node | **animated loader** (see below) + accent ring |
| `passing` | compile/step succeeded | check, calm green tone |
| `failing` | error; walker looping in place | subtle destructive tone, retry count |
| `deployed` | release step done | solid accent |

- **"Currently working" states** use tasteful CSS loaders in the spirit of
  <https://www.loaders.wtf> — one small, consistent loader animation shown inside
  a node while its walker is active (planner drafting spec, builder generating +
  compiling, deploy running scripts). Keep it minimal: **one** chosen loader
  style reused everywhere, not a zoo of spinners.
- The Code & Compile loop (`builder_walker` looping until compile passes) is
  visible as the Device/Server/Client node staying in `working`/`failing` with a
  live retry counter, then flipping to `passing`.
- Edges animate (flowing dashes) while a walker is traversing them, so you can
  literally watch orchestration move through the graph.

---

## 4. Monitoring node — status-page aesthetic

Modeled on a clean uptime/status page like <https://status.marshell.dev>:

- Uptime bars / heartbeat strip (green ticks, occasional red) for the running
  system.
- Live tail of the **ESP32 serial output** and **server ping** results
  (`monitor_walker` reads serial + pings localhost, per `jacgraph.md` §4 and
  `pijac.txt`).
- "Operational / Degraded / Down" summary line.
- When it detects a crash/anomaly, the **feedback-loop edge** to Coordinator
  lights up and a new builder pass kicks off — surfaced as a small event in the
  monitoring feed.

---

## 5. How the UI maps to the Jac OSP backend

The graph is not decoration — it renders live server state. Mapping:

| UI element | Jac backend |
| --- | --- |
| Coordinator node | root / Coordinator `node`; holds prompt + JSON spec |
| Worker nodes | Server / Client / Device `node`s, each bound to `./workspace/*` |
| Deployment node | Deployment `node` (creds, ports, `arduino-cli`/`pnpm` scripts) |
| Monitoring node | Monitoring `node` (serial read + server ping) |
| Node `working` state | a walker (`planner`/`builder`/`deploy`/`monitor`) currently on that node |
| Edge animation | a walker traversing that edge |
| Feedback-loop edge | Monitoring → Coordinator re-dispatch path |

- The client subscribes to node/walker state from `.sv.jac` endpoints (poll or
  **SSE stream** — see `jac-sv-streaming`) and re-renders the graph reactively.
- Prompt submit → spawns `planner_walker` at Coordinator; UI reflects each phase
  (Planning → Code & Compile → Release → Monitoring) as state flows down the graph.

---

## 6. Tech stack / implementation notes

- **Graph canvas:** React Flow (`@xyflow/react`) consumed as an npm package from
  a `.cl.jac` file: `cl import from "@xyflow/react" { ReactFlow, Background, ... }`;
  add to `jac.toml [dependencies.npm]` then `jac install` (see `jac-npm-packages`).
- Custom React Flow node types = wirejac `.cl.jac` components (CoordinatorNode,
  WorkerNode, DeploymentNode, MonitoringNode) composed from shadcn primitives
  (`Card`, `Badge`, `Spinner`/loader).
- **Loaders:** a single custom CSS keyframe loader in `brand.css` (or a scoped
  `.style.css`) inspired by loaders.wtf — reused across all `working` nodes.
- **Chat components (imported `.tsx`):** `PromptInputBox`
  (`components/ui/ai-prompt-box.tsx`, used on the landing CTA + the 30% chat
  panel) and `ToolCallsSection` (`components/ui/tool-calls-section.tsx`, rendered
  in the chat when the agent calls a tool). Both are pre-existing React/TS
  components imported into `.cl.jac` — Jac allows importing existing `.tsx`; we
  never author new ones. **Restyled to the light minimalist theme** (semantic
  tokens, squircles, Elms Sans) instead of their original dark palette.
  `tool-calls-section` needs three helper files created under
  `components/ui/tool-calls-section-utils/` (icons, tool-icons, compact-markdown).
  Deps: `lucide-react`, `framer-motion`, `@radix-ui/react-dialog`,
  `@radix-ui/react-tooltip`, `@hugeicons/react`, `@hugeicons/core-free-icons`.
- **Loaders / transitions are copy-paste galleries** (<https://www.loaders.wtf>,
  <https://transitions.dev>) — not npm packages; adapt chosen snippets into
  `brand.css` / scoped `.style.css`, themed to match.
- **Monitoring feed / serial + ping:** streamed via `.sv.jac` (SSE) so it's live.
- Squircles + Elms Sans are already global — new components inherit them for free.

---

## 7. Screen / state checklist (build order)

- [ ] Screen 1: chat-first landing with the "build me ___ that does ___" CTA
- [ ] Prompt-submit → morph transition into the graph view
- [ ] React Flow canvas wired in (`@xyflow/react`)
- [ ] Custom nodes: Coordinator (top), Server/Client/Device workers, Deployment, Monitoring
- [ ] Downstream + fan-out edges + the Monitoring→Coordinator feedback edge
- [ ] Per-node state machine (idle/queued/working/passing/failing/deployed)
- [ ] "Working" loader animation (loaders.wtf style), reused everywhere
- [ ] Animated edges while walkers traverse
- [ ] Monitoring node status-page panel (uptime bars + serial/ping feed)
- [ ] Live state binding to `.sv.jac` endpoints (poll → SSE)

---

## 8. Implementation phases

Each checklist item above is expanded into an ordered phase below. **Front-load
the visuals:** Phases 0–7 build the presentation layer against the stable run
view contract. Phases 8–9 connect that contract to live `.sv.jac` data. Phase
10 is polish.

> **Critical path:** 0 → 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9 → 10.
> Phases 4, 5, 7 can proceed in parallel once 3 lands. Phase 8 (backend) can be
> built in parallel with 4–7 by a second track.

---

### Phase 0 — Foundation & app shell
**Goal:** clear the guestbook starter and stand up the two-screen shell + shared client types.
**Depends on:** nothing (styling stack already done).
**Tasks:**
- [ ] Repurpose/remove guestbook (`frontend.cl.jac`, `components/MessageCard.cl.jac`, `endpoints.sv.jac` guestbook bits)
- [ ] Top-level view state in `app()`: `has phase: str = "landing";` ("landing" | "graph")
- [ ] Shared client types module: `NodeStatus` enum, `GraphNode`/`GraphEdge`/`GraphView` shapes (mirror the future `sv` view models)
- [ ] Full-viewport minimalist shell (wordmark only)

**Deliverable:** blank app shell that toggles between an empty landing and an empty graph screen.
**Done when:** `jac check main.jac` passes; both view states render.

---

### Phase 1 — Screen 1: chat-first landing CTA
**Goal:** the `"build me ___ that does ___"` prompt.
**Depends on:** Phase 0.
**Tasks:**
- [ ] Centered, oversized `Textarea`/`Input` with the placeholder framing
- [ ] Submit affordance (`Button` + Enter-to-submit)
- [ ] `has prompt: str = "";` captured on submit
- [ ] On submit → set `phase = "graph"` (no backend yet); keep the prompt in state
- [ ] Minimal chrome: wordmark + input only

**Deliverable:** type a prompt, hit Enter, land on the (empty) graph screen.
**Done when:** prompt is captured and the view switches.

---

### Phase 2 — React Flow canvas (static topology)
**Goal:** get `@xyflow/react` rendering the exact 6-node top-down topology, hardcoded.
**Depends on:** Phase 1.
**New deps / commands:**
```bash
cd frontend && jac add --npm @xyflow/react && jac install
```
**Tasks:**
- [ ] `GraphCanvas.cl.jac`: `cl import from "@xyflow/react" { ReactFlow, Background, Controls, MiniMap }`
- [ ] Import the base stylesheet: `import "@xyflow/react/dist/style.css";` (in the entry `cl` block)
- [ ] Hardcode nodes + positions: Coordinator (top) → Server/Client/Device (row) → Deployment → Monitoring
- [ ] Hardcode edges: Coordinator→each worker, each worker→Deployment, Deployment→Monitoring, Monitoring→Coordinator (feedback)

**Deliverable:** static graph matching [`image.png`](./image.png); pan/zoom works.
**Done when:** canvas renders the full topology with correct edge routing.

---

### Phase 3 — Custom node components
**Goal:** replace default boxes with branded node cards.
**Depends on:** Phase 2.
**Tasks:**
- [ ] `nodeTypes` map → custom `.cl.jac` components: `CoordinatorNode`, `WorkerNode` (prop: `kind = server|client|device`), `DeploymentNode`, `MonitoringNode`
- [ ] Compose from shadcn `Card`/`Badge`; add xyflow `Handle`s (top/bottom) for edge anchors
- [ ] Show title + subtitle + bound subdir (`./workspace/*`)
- [ ] Squircle + Elms Sans inherited automatically

**Deliverable:** styled, on-brand nodes wired to the canvas.
**Done when:** every node type renders with handles; edges connect to handles cleanly.

---

### Phase 4 — Node state machine + "working" loader
**Goal:** per-node status visuals and the single reused loader.
**Depends on:** Phase 3.
**Tasks:**
- [ ] `NodeStatus`: idle | queued | working | passing | failing | deployed
- [ ] status → visual map (opacity, accent ring, calm-green check, destructive tone + retry count, solid accent for deployed)
- [ ] One CSS keyframe loader (loaders.wtf spirit) in `styles/brand.css` or a scoped `.style.css`; shown inside a node while `working`
- [ ] Prop-drill `status` into nodes; temporary local state-cycler button for demo

**Deliverable:** nodes render all six states; `working` shows the loader.
**Done when:** cycling status re-renders the correct visual per node.

---

### Phase 5 — Edges, animation & feedback loop
**Goal:** animated edges + a distinct feedback edge.
**Depends on:** Phase 3 (parallel with 4).
**Tasks:**
- [ ] Animated flowing dashes on an edge while its target is `working`/traversing (xyflow `animated` + custom edge style)
- [ ] Style the Monitoring→Coordinator feedback edge distinctly (dashed, accent, curved back up)
- [ ] Optional edge labels (phase names)

**Deliverable:** edges animate; feedback loop is visually unmistakable.
**Done when:** a `traversing` flag drives edge animation.

---

### Phase 6 — Landing → graph morph transition
**Goal:** the input "settles" into the Coordinator node (no hard swap).
**Depends on:** Phases 1 + 3.
**Tasks:**
- [ ] Animate the centered prompt input to the top Coordinator position (shared-layout / CSS transition; respect `prefers-reduced-motion`)
- [ ] Coordinator node displays the submitted prompt text

**Deliverable:** submitting morphs smoothly into the graph.
**Done when:** transition reads as one continuous motion; Coordinator carries the prompt.

---

### Phase 7 — Monitoring status-page panel
**Goal:** [status.marshell.dev](https://status.marshell.dev/)-style monitoring surface.
**Depends on:** Phase 3.
**Tasks:**
- [ ] Expandable Monitoring node → side/detail panel
- [ ] Uptime heartbeat strip (green ticks, occasional red) + "Operational / Degraded / Down" line
- [ ] Live tail: ESP32 serial output + server-ping results
- [ ] Anomaly in the feed lights up the feedback edge

**Deliverable:** monitoring panel with uptime strip + live feed.
**Done when:** panel renders; an anomaly event highlights the feedback edge.

**→ Milestone: full flow driven by runtime events.**

---

### Phase 8 — Backend contract (`.sv.jac` endpoints)
**Goal:** define the server-side OSP graph + walkers, with statuses the UI can read.
**Depends on:** can start in parallel with Phases 4–7.
**Tasks:**
- [ ] OSP `node`s: `Coordinator`, `Worker` (server/client/device), `Deployment`, `Monitoring` (see `jac-node-edge-patterns`)
- [ ] Walkers `planner` / `builder` / `deploy` / `monitor` — stubs that just advance node `status` for demo (real logic later; see `jac-walker-patterns`)
- [ ] `endpoints.sv.jac`: `get_graph() -> GraphView` (nodes+edges+statuses), `submit_prompt(text: str)` (spawns `planner` at Coordinator)
- [ ] `to_view` projection so the client gets a clean serializable graph

**Deliverable:** `GET` graph returns topology + live statuses; `submit_prompt` advances state.
**Done when:** endpoints pass `jac check`; `curl` returns the graph JSON.

---

### Phase 9 — Live binding (poll → SSE)
**Goal:** the graph renders real server state and updates live.
**Depends on:** Phases 2–8.
**Tasks:**
- [ ] `sv import` `get_graph` in `GraphCanvas`; `async can with entry` to load initial graph
- [ ] Poll on an interval first; then upgrade to an **SSE stream** for push updates (see `jac-sv-streaming`)
- [ ] Map server `status` → node visuals and edge `traversing` flags
- [ ] Wire the landing submit → `submit_prompt`

**Deliverable:** real orchestration reflected live, no reload.
**Done when:** advancing server state animates the graph in place.

**→ Milestone: live demo ready.**

---

### Phase 10 — Minimalist polish & states
**Goal:** final clean pass to demo quality.
**Depends on:** all prior.
**Tasks:**
- [ ] Empty / loading / error states for the canvas and panels
- [ ] Responsive layout; keyboard nav; `prefers-reduced-motion`
- [ ] Design-language audit (spacing, semantic tokens, no shadows/gradients; squircles + Elms Sans everywhere)
- [ ] Remove obsolete demo controls

**Done when:** clean, on-brand, and demo-ready on Chrome (squircles at full effect).

---

### Reference links
- Graph UI: <https://reactflow.dev/>
- Working-state loaders: <https://www.loaders.wtf/>
- Monitoring / status-page style: <https://status.marshell.dev/>
- Squircle corners: <https://www.arlan.me/vault/squircle>
- Elms Sans font: <https://fonts.google.com/specimen/Elms+Sans>
- Architecture: [`image.png`](./image.png), [`../jacgraph.md`](../jacgraph.md), [`../pijac.txt`](../pijac.txt)
