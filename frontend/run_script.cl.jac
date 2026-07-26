"""Pure client projections from real Wirejac activation events."""

glob:pub RUN_NODES: list[dict] = [
    {"id": "coordinator", "kind": "coordinator", "label": "Coordinator", "subdir": ""},
    {"id": "server", "kind": "worker", "label": "Server", "subdir": "./workspace/server"},
    {"id": "client", "kind": "worker", "label": "Client", "subdir": "./workspace/client"},
    {"id": "device", "kind": "worker", "label": "Device", "subdir": "./workspace/device"},
    {"id": "deployment", "kind": "deployment", "label": "Deployment", "subdir": ""},
    {"id": "monitoring", "kind": "monitoring", "label": "Monitoring", "subdir": ""}
];

glob:pub RUN_EDGES: list[dict] = [
    {"source": "coordinator", "target": "server", "kind": "flow"},
    {"source": "coordinator", "target": "client", "kind": "flow"},
    {"source": "coordinator", "target": "device", "kind": "flow"},
    {"source": "server", "target": "deployment", "kind": "flow"},
    {"source": "client", "target": "deployment", "kind": "flow"},
    {"source": "device", "target": "deployment", "kind": "flow"},
    {"source": "deployment", "target": "monitoring", "kind": "flow"},
    {"source": "monitoring", "target": "coordinator", "kind": "feedback"}
];

def map_status(state: str, node_id: str) -> str {
    if state in ["planned", "queued"] { return "queued"; }
    if state in ["running", "repairing", "replanning", "validating", "deploying", "monitoring"] {
        return "working";
    }
    if state == "failed" { return "failing"; }
    if state == "succeeded" {
        return "deployed" if node_id == "deployment" else "passing";
    }
    if state == "awaiting_approval" { return "queued"; }
    if state == "skipped" { return "passing"; }
    return "idle";
}

def:pub node_status(node_id: str, events: list[dict]) -> str {
    status = "idle";
    for event in events {
        if str(event.get("node", "")) == node_id {
            status = map_status(str(event.get("state", "")), node_id);
        }
    }
    return status;
}

def:pub node_revealed(node_id: str, events: list[dict]) -> bool {
    return True;
}

def:pub chat_from_events(events: list[dict]) -> list[dict] {
    messages: list[dict] = [];
    for event in events {
        count = int(event.get("tool_count", 0));
        tools: list[dict] = [];
        if count > 0 {
            tools.append({
                "tool_name": "workspace_tools",
                "tool_category": str(event.get("node", "agent")),
                "integration_name": str(event.get("node", "agent")),
                "message": f"{count} contained tool call(s)",
                "inputs": {"request_id": str(event.get("request_id", ""))},
                "output": str(event.get("revision", "validation recorded"))
            });
        }
        text = str(event.get("summary", ""));
        if event.get("error") {
            text = text + ": " + str(event.get("error"));
        }
        messages.append({
            "text": text,
            "tools": tools,
            "node": str(event.get("node", "system")),
            "state": str(event.get("state", "")),
            "timestamp": str(event.get("timestamp", ""))
        });
    }
    return messages;
}

def:pub mon_state(events: list[dict]) -> dict {
    current = {
        "status": "idle",
        "line": "waiting for deployment",
        "up": 0
    };
    for event in events {
        if str(event.get("node", "")) == "monitoring" {
            state = str(event.get("state", ""));
            current = {
                "status": "operational" if state == "succeeded" else (
                    "degraded" if state == "failed" else "checking"
                ),
                "line": str(event.get("summary", "monitoring")),
                "up": 8 if state == "succeeded" else (3 if state == "failed" else 5)
            };
        }
    }
    return current;
}

def:pub pipeline_phase(events: list[dict]) -> str {
    phase = "plan";
    for event in events {
        node_id = str(event.get("node", ""));
        if node_id in ["server", "client", "device"] { phase = "build"; }
        if node_id == "deployment" { phase = "deploy"; }
        if node_id == "monitoring" { phase = "monitor"; }
    }
    return phase;
}
