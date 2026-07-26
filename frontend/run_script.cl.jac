"""Mock 'run' script — the single source of truth that animates the whole
dashboard (graph statuses, chat stream, tool calls, monitoring) from one clock.

Everything derives from `clock` (ms since the run started). The Dashboard ticks
the clock; the canvas, chat panel and monitoring strip all read these pure
functions. No backend — this simulates a real orchestration run end to end.
"""

# ---- Static topology --------------------------------------------------------
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

# ---- Node status timeline (id, at ms, status) -------------------------------
# A node is "revealed" once any entry has at <= clock; its status is the last
# such entry's status. Spawn timing: coordinator now, server +4s, client +7s,
# device +9s, deployment +16s, monitoring +19.5s.
glob:pub NODE_EVENTS: list[dict] = [
    {"id": "coordinator", "at": 200,   "status": "working"},
    {"id": "coordinator", "at": 1800,  "status": "passing"},
    {"id": "server",      "at": 4000,  "status": "working"},
    {"id": "server",      "at": 10000, "status": "passing"},
    {"id": "client",      "at": 7000,  "status": "working"},
    {"id": "client",      "at": 12000, "status": "passing"},
    {"id": "device",      "at": 9000,  "status": "working"},
    {"id": "device",      "at": 13000, "status": "failing"},
    {"id": "device",      "at": 15000, "status": "passing"},
    {"id": "deployment",  "at": 16000, "status": "working"},
    {"id": "deployment",  "at": 19000, "status": "deployed"},
    {"id": "monitoring",  "at": 19500, "status": "working"},
    {"id": "monitoring",  "at": 21000, "status": "passing"}
];

# ---- Chat script (at ms, role, text, tools) ---------------------------------
glob:pub CHAT_EVENTS: list[dict] = [
    {"at": 300, "role": "agent", "text": "Planning the architecture and generating the JSON spec…",
     "tools": [{"tool_name": "generate_spec", "tool_category": "planning", "integration_name": "Coordinator",
                "message": "Drafted architecture spec", "inputs": {"targets": "server, client, device"},
                "output": "3-service spec: Jac API + web dashboard + ESP32 firmware."}]},
    {"at": 1900, "role": "agent", "text": "Spec ready — spinning up Server, Client and Device workers.", "tools": []},
    {"at": 4200, "role": "agent", "text": "Server agent: scaffolding the Jac API service…",
     "tools": [{"tool_name": "write_file", "tool_category": "server", "integration_name": "Server worker",
                "message": "Wrote ./workspace/server", "inputs": {"path": "server/main.sv.jac"}, "output": "12 files written."}]},
    {"at": 7200, "role": "agent", "text": "Client agent: building the dashboard UI…",
     "tools": [{"tool_name": "write_file", "tool_category": "client", "integration_name": "Client worker",
                "message": "Wrote ./workspace/client", "inputs": {"path": "client/app.cl.jac"}, "output": "UI scaffolded."}]},
    {"at": 9200, "role": "agent", "text": "Device agent: generating ESP32 firmware…",
     "tools": [{"tool_name": "write_file", "tool_category": "device", "integration_name": "Device worker",
                "message": "Wrote ./workspace/device", "inputs": {"path": "device/sensor.na.jac"}, "output": "Firmware drafted."}]},
    {"at": 13200, "role": "agent", "text": "Device build failed — patching and recompiling in place…",
     "tools": [{"tool_name": "run_compile", "tool_category": "compile", "integration_name": "Device worker",
                "message": "jac nacompile sensor.na.jac", "inputs": {"retry": "1"}, "output": "error: undeclared GPIO pin → patched."}]},
    {"at": 15200, "role": "agent", "text": "All workers passing ✅  Gathering artifacts.", "tools": []},
    {"at": 16200, "role": "agent", "text": "Deploying: starting the server and flashing the ESP32…",
     "tools": [{"tool_name": "deploy", "tool_category": "deploy", "integration_name": "Deployment",
                "message": "arduino-cli upload + pnpm start", "inputs": {"port": "/dev/tty.usb", "server": ":8000"}, "output": "Server up · board flashed."}]},
    {"at": 21200, "role": "agent", "text": "System is live. Monitoring serial output and pinging the server.", "tools": []}
];

# ---- Monitoring timeline ----------------------------------------------------
glob:pub MON_EVENTS: list[dict] = [
    {"at": 0,     "status": "idle",        "line": "waiting for deployment…",           "up": 0},
    {"at": 19000, "status": "degraded",    "line": "esp32 booting · server starting",   "up": 3},
    {"at": 21000, "status": "operational", "line": "serial OK · ping 12ms · 3.3V ok",    "up": 8}
];

# ---- Derive functions -------------------------------------------------------

def:pub node_status(node_id: str, clock: int) -> str {
    result = "idle";
    for e in NODE_EVENTS {
        if e["id"] == node_id and e["at"] <= clock {
            result = e["status"];
        }
    }
    return result;
}

def:pub node_revealed(node_id: str, clock: int) -> bool {
    for e in NODE_EVENTS {
        if e["id"] == node_id and e["at"] <= clock {
            return True;
        }
    }
    return False;
}

def:pub chat_upto(clock: int) -> list {
    out = [];
    for m in CHAT_EVENTS {
        if m["at"] <= clock {
            out.append(m);
        }
    }
    return out;
}

def:pub mon_state(clock: int) -> dict {
    cur = MON_EVENTS[0];
    for e in MON_EVENTS {
        if e["at"] <= clock {
            cur = e;
        }
    }
    return cur;
}

def:pub pipeline_phase(clock: int) -> str {
    if clock >= 19500 { return "monitor"; }
    if clock >= 16000 { return "deploy"; }
    if clock >= 4000 { return "build"; }
    return "plan";
}
