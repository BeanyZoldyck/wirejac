"""React Flow canvas — driven by the run clock (see run_script.cl.jac).

Node status + reveal derive from `clock`. A Detailed/Simple toggle (top-right
overlay) switches every node between the full card and a compact circle. Flow
edges animate while their target is `working`; the feedback edge routes right.
"""

import from "@xyflow/react" { ReactFlow, Background }
import from .run_script { RUN_NODES, RUN_EDGES, node_status, node_revealed }
import from .nodes { CoordinatorNode, WorkerNode, DeploymentNode, MonitoringNode }

glob NODE_TYPES: dict[str, any] = {
    "coordinator": CoordinatorNode,
    "worker": WorkerNode,
    "deployment": DeploymentNode,
    "monitoring": MonitoringNode
};

glob NODE_POSITIONS: dict[str, dict[str, int]] = {
    "coordinator": {"x": 360, "y": 0},
    "server": {"x": 0, "y": 320},
    "client": {"x": 360, "y": 320},
    "device": {"x": 720, "y": 320},
    "deployment": {"x": 360, "y": 640},
    "monitoring": {"x": 360, "y": 960}
};

def:pub GraphCanvas(events: list[dict], simple: bool, onSetSimple: Callable[[bool], None]) -> JsxElement {
    nodes: list[dict[str, any]] = [];
    for n in RUN_NODES {
        pos = NODE_POSITIONS[n["id"]];
        nodes.append({
            "id": n["id"],
            "type": n["kind"],
            "position": {"x": pos["x"], "y": pos["y"]},
            "data": {
                "label": n["label"],
                "kind": n["kind"],
                "subdir": n["subdir"],
                "status": node_status(n["id"], events),
                "simple": simple,
                "revealed": node_revealed(n["id"], events)
            }
        });
    }

    edges: list[dict[str, any]] = [];
    for e in RUN_EDGES {
        both = node_revealed(e["source"], events) and node_revealed(e["target"], events);
        eid = f"{e['source']}-{e['target']}";
        if e["kind"] == "feedback" {
            edges.append({
                "id": eid, "source": e["source"], "target": e["target"],
                "sourceHandle": "fb", "targetHandle": "fb", "type": "smoothstep",
                "pathOptions": {"offset": 60, "borderRadius": 16},
                "hidden": not both, "animated": True
            });
        } else {
            active = node_status(e["target"], events) == "working";
            edges.append({
                "id": eid, "source": e["source"], "target": e["target"],
                "hidden": not both, "animated": active
            });
        }
    }

    return <div className="relative w-full h-full">
        <div className="absolute top-3 right-3 z-10 flex items-center gap-0.5 rounded-lg border border-border bg-background/80 backdrop-blur p-0.5 text-xs">
            <button
                onClick={lambda -> None { onSetSimple(False); }}
                className={"px-2.5 py-1 rounded-md transition-colors " + ("bg-primary text-primary-foreground" if not simple else "text-muted-foreground hover:text-foreground")}
            >Detailed</button>
            <button
                onClick={lambda -> None { onSetSimple(True); }}
                className={"px-2.5 py-1 rounded-md transition-colors " + ("bg-primary text-primary-foreground" if simple else "text-muted-foreground hover:text-foreground")}
            >Simple</button>
        </div>
        <ReactFlow
            nodes={nodes}
            edges={edges}
            nodeTypes={NODE_TYPES}
            fitView={True}
            minZoom={0.2}
            panOnScroll={True}
            proOptions={{"hideAttribution": True}}
        >
            <Background gap={22} />
        </ReactFlow>
    </div>;
}
