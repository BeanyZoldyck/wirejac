"""Custom React Flow node components.

Branded, shadcn `Card`-based nodes for the orchestration canvas. React Flow
renders each custom node with a props object whose `data` field carries the
domain payload (label / kind / subdir / status / revealed).

Handles: flow edges use top-target / bottom-source. The Monitoring->Coordinator
feedback edge uses dedicated RIGHT handles (id "fb") so it routes on the side
and never crosses behind the center-column nodes.

Per-state visuals: each node's Card gets state-driven classes from
`status_ring()`, `working` nodes render the shared `<Loader/>`, and every node
carries an animated per-kind icon (see `animated-icons.tsx`). `reveal_cls()`
fades a node in when the mock spawn timeline reaches it.
"""

import from "@xyflow/react" { Handle, Position }
import from .components.ui.card { Card, CardHeader, CardTitle, CardContent }
import from .components.ui.badge { Badge }
import from .Loader { Loader }
import from "./components/ui/animated-icons" { CoordinatorIcon, WorkerIcon, DeploymentIcon, MonitoringIcon }

# ---- Helpers ----------------------------------------------------------------

def status_label(status: any) -> str {
    text = str(status);
    if "." in text {
        text = text.split(".")[-1];
    }
    return text;
}

def status_variant(name: str) -> str {
    if name == "passing" or name == "deployed" {
        return "default";
    }
    if name == "failing" {
        return "destructive";
    }
    if name == "working" {
        return "secondary";
    }
    return "outline";
}

def StatusBadge(status: any) -> JsxElement {
    name = status_label(status);
    return <Badge variant={status_variant(name)}>{name}</Badge>;
}

def is_working(status: str) -> bool {
    return status_label(status) == "working";
}

# Container classes for a node's outer Card, keyed off its status string.
def status_ring(status: str) -> str {
    name = status_label(status);
    if name == "idle" {
        return "opacity-70";
    }
    if name == "queued" {
        return "opacity-85 animate-pulse";
    }
    if name == "working" {
        return "ring-2 ring-primary";
    }
    if name == "failing" {
        return "border-destructive text-destructive";
    }
    if name == "deployed" {
        return "ring-2 ring-primary bg-accent";
    }
    return "";
}

# Fade a node in when the mock spawn timeline reveals it; keep it invisible (but
# in the layout, so the canvas view stays stable) beforehand.
def reveal_cls(data: dict) -> str {
    if data["revealed"] {
        return "wj-node-in";
    }
    return "opacity-0 scale-95 pointer-events-none";
}

# ---- Node components --------------------------------------------------------

def:pub CoordinatorNode(data: dict) -> JsxElement {
    status = data["status"];
    return <div className={"w-56 " + reveal_cls(data)}>
        <Card className={"border-primary/40 bg-card " + status_ring(status)}>
            <CardHeader>
                <p className="text-xs font-medium text-primary">Coordinator</p>
                <div className="flex items-center gap-2">
                    <CoordinatorIcon className="text-primary" active={is_working(status)} />
                    <CardTitle className="text-base">{data["label"]}</CardTitle>
                </div>
                <p className="text-xs text-muted-foreground">Plans the spec, orchestrates workers</p>
            </CardHeader>
            <CardContent>
                <div className="flex items-center gap-2">
                    <StatusBadge status={status} />
                    {if is_working(status) { <Loader /> }}
                </div>
            </CardContent>
        </Card>
        <Handle type="source" position={Position.Bottom} />
        <Handle type="target" position={Position.Right} id="fb" />
    </div>;
}

def:pub WorkerNode(data: dict) -> JsxElement {
    status = data["status"];
    return <div className={"w-56 " + reveal_cls(data)}>
        <Handle type="target" position={Position.Top} />
        <Card className={"bg-card " + status_ring(status)}>
            <CardHeader>
                <p className="text-xs font-medium text-muted-foreground">Worker agent</p>
                <div className="flex items-center gap-2">
                    <WorkerIcon kind={data["label"]} className="text-foreground" active={is_working(status)} />
                    <CardTitle className="text-base">{data["label"]}</CardTitle>
                </div>
                {if data["subdir"] {
                    <p className="text-xs text-muted-foreground font-mono">{data["subdir"]}</p>
                }}
            </CardHeader>
            <CardContent>
                <div className="flex items-center gap-2">
                    <StatusBadge status={status} />
                    {if is_working(status) { <Loader /> }}
                </div>
            </CardContent>
        </Card>
        <Handle type="source" position={Position.Bottom} />
    </div>;
}

def:pub DeploymentNode(data: dict) -> JsxElement {
    status = data["status"];
    return <div className={"w-56 " + reveal_cls(data)}>
        <Handle type="target" position={Position.Top} />
        <Card className={"bg-card " + status_ring(status)}>
            <CardHeader>
                <p className="text-xs font-medium text-muted-foreground">Release step</p>
                <div className="flex items-center gap-2">
                    <DeploymentIcon className="text-foreground" active={is_working(status)} />
                    <CardTitle className="text-base">{data["label"]}</CardTitle>
                </div>
                <p className="text-xs text-muted-foreground">Gathers artifacts, runs staging</p>
            </CardHeader>
            <CardContent>
                <div className="flex items-center gap-2">
                    <StatusBadge status={status} />
                    {if is_working(status) { <Loader /> }}
                </div>
            </CardContent>
        </Card>
        <Handle type="source" position={Position.Bottom} />
    </div>;
}

def:pub MonitoringNode(data: dict) -> JsxElement {
    status = data["status"];
    return <div className={"w-56 " + reveal_cls(data)}>
        <Handle type="target" position={Position.Top} />
        <Card className={"bg-card " + status_ring(status)}>
            <CardHeader>
                <p className="text-xs font-medium text-muted-foreground">Live status</p>
                <div className="flex items-center gap-2">
                    <MonitoringIcon className="text-foreground" active={is_working(status)} />
                    <CardTitle className="text-base">{data["label"]}</CardTitle>
                </div>
                <p className="text-xs text-muted-foreground">Serial + ping; feeds back to Coordinator</p>
            </CardHeader>
            <CardContent>
                <div className="flex items-center gap-2">
                    <StatusBadge status={status} />
                    {if is_working(status) { <Loader /> }}
                </div>
            </CardContent>
        </Card>
        <Handle type="source" position={Position.Right} id="fb" />
    </div>;
}
