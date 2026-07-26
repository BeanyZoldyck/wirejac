"""Shared client-side graph types.

Frontend-only placeholders that mirror the future server (`.sv.jac`) view
models for the orchestration graph. These describe the OSP topology the React
Flow canvas renders: a Coordinator fanning out to Server/Client/Device
workers, down to Deployment and Monitoring nodes.

Server-side (`.sv.jac`) versions with real graph nodes/edges + `to_view`
projections come in a later phase (see UI-UX-PLAN.md §8, Phase 8).
"""

enum:pub NodeStatus {
    idle = "idle",
    queued = "queued",
    working = "working",
    passing = "passing",
    failing = "failing",
    deployed = "deployed"
}

obj:pub GraphNode {
    has id: str,
        kind: str,          # coordinator | worker | deployment | monitoring
        label: str,
        subdir: str = "",
        status: NodeStatus = NodeStatus.idle;
}

obj:pub GraphEdge {
    has source: str,
        target: str,
        kind: str = "flow";  # flow | feedback
}
