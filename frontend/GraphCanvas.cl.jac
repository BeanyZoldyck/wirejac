"""React Flow canvas — driven by the run clock (see run_script.cl.jac).

All node status + reveal is derived from `clock`; nodes stay in the layout so
the view is stable, fading in via `wj-node-in` when revealed. Flow edges animate
while their target node is actively `working` (a walker traversing); the
feedback edge routes on the right so no line crosses behind the center nodes.
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

def:pub GraphCanvas(clock: int) -> JsxElement {
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
                "status": node_status(n["id"], clock),
                "revealed": node_revealed(n["id"], clock)
            }
        });
    }

    edges: list[dict[str, any]] = [];
    for e in RUN_EDGES {
        both = node_revealed(e["source"], clock) and node_revealed(e["target"], clock);
        eid = f"{e['source']}-{e['target']}";
        if e["kind"] == "feedback" {
            edges.append({
                "id": eid, "source": e["source"], "target": e["target"],
                "sourceHandle": "fb", "targetHandle": "fb", "type": "smoothstep",
                "pathOptions": {"offset": 60, "borderRadius": 16},
                "hidden": not both, "animated": True
            });
        } else {
            active = node_status(e["target"], clock) == "working";
            edges.append({
                "id": eid, "source": e["source"], "target": e["target"],
                "hidden": not both, "animated": active
            });
        }
    }

    return <div className="w-full h-full">
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
