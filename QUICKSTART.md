Implemented the runnable Jac-native agent graph.
What I Made
- Six-node OSP graph in orchestrator/graph.jac:
- Coordinator
- Client
- Server
- Device
- Deployment
- Monitoring
- Typed workflow edges: Project, Dispatch, ReadyToDeploy, Verify, and Feedback.
- Internal stateful ChangeRequest walker.
- Narrow public SubmitChange(prompt) walker.
- Public GraphSnapshot walker for dashboard topology.
- Persistent topology lookup with stale-development-anchor fallback.
Agent Runtime
- Live OpenRouter integration using deepseek/deepseek-v4-flash.
- Coordinator produces and validates structured impact plans.
- Workspace agents receive role instructions, API contracts, acceptance criteria, and contained tools.
- Tools support file listing, reading, searching, writing, and allowlisted commands.
- Path traversal, symlink escapes, unrestricted environment access, and unapproved executables are blocked.
- Filesystem snapshots are taken before agent edits.
- Deterministic validation failures are returned to the bounded model loop for repair.
- API-spec edits stop deployment and return execution to Coordinator.
Placeholders
- Dashboard events write to runtime/events/events.jsonl.
- GraphSnapshot returns six nodes and eight edges.
- Monitoring has a replaceable browser/runtime adapter placeholder.
- Device deployment stops at AWAITING_APPROVAL.
- Expected ESP32 artifact: workspace/device/generated/main.py.
- No conversion, serial access, or physical flashing occurs yet.
Demo Workspaces
- Editable accelerometer dashboard under workspace/client.
- Jac server placeholder under workspace/server.
- Restricted device Jac source under workspace/device.
- Each workspace has role instructions and an API spec.
Project Support
- Added jac.toml, .gitignore, README.md, and tests/wirejac.jac.
- Added mock mode for testing without OpenRouter.
- Verified API-only startup and both public HTTP endpoints.
Verification
- All Jac source passes jac check.
- npm run check passes.
- Four Jac tests pass.
- Mock CLI traversal passes.
- HTTP SubmitChange returns one complete activation trace.
- HTTP GraphSnapshot returns the expected topology.
- OpenRouter currently advertises deepseek/deepseek-v4-flash.
- Live model calls were not executed because OPENROUTER_API_KEY is not set.
Run locally:
WIREJAC_MOCK=1 \
WIREJAC_PROMPT="Make the active sample count more prominent" \
jac run main.jac --no-cache
Run the API:
WIREJAC_MOCK=1 jac start main.jac --no_client
