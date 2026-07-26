"""Custom React Flow node components — Detailed (card) + Simple (circle) views.

React Flow renders each with a props object whose `data` carries label / kind /
subdir / status / revealed / simple. `simple` toggles between the full shadcn
card and a compact circle-with-icon.

Handles attach to the node ELEMENT's edges, so in simple view the outer element
is a tight circle-sized box (w-16 h-16) — otherwise the handles float far from
the small circle. The label is absolutely positioned below so it doesn't grow
the box. Flow edges: top-target / bottom-source; feedback edge: right (id "fb").
"""

import from "@xyflow/react" { Handle, Position }
import from .components.ui.card { Card, CardHeader, CardTitle, CardContent }
import from .components.ui.badge { Badge }
import from .Loader { Loader }
# TypeScript components remain in the project source tree while Jac emits
# client modules to .jac/client/compiled.
import from "../../../components/ui/animated-icons" { CoordinatorIcon, WorkerIcon, DeploymentIcon, MonitoringIcon }

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

def reveal_cls(data: dict) -> str {
    if data["revealed"] {
        return "wj-node-in";
    }
    return "opacity-0 scale-95 pointer-events-none";
}

def outer_cls(data: dict) -> str {
    base = "relative w-16 h-16" if data["simple"] else "w-56";
    return base + " " + reveal_cls(data);
}

# ---- Node components --------------------------------------------------------

def:pub CoordinatorNode(data: dict) -> JsxElement {
    status = data["status"];
    return <div className={outer_cls(data)}>
        <Handle type="source" position={Position.Bottom} />
        <Handle type="target" position={Position.Right} id="fb" />
        {if data["simple"] {
            <div className="w-full h-full">
                <div className={"size-16 rounded-full bg-card border border-primary/50 flex items-center justify-center " + status_ring(status)}>
                    <CoordinatorIcon className="text-primary" active={is_working(status)} size={28} />
                </div>
                <span className="absolute left-1/2 -translate-x-1/2 top-[72px] text-xs font-medium whitespace-nowrap">{data["label"]}</span>
            </div>
        } else {
            <Card className={"w-full border-primary/40 bg-card " + status_ring(status)}>
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
        }}
    </div>;
}

def:pub WorkerNode(data: dict) -> JsxElement {
    status = data["status"];
    return <div className={outer_cls(data)}>
        <Handle type="target" position={Position.Top} />
        {if data["simple"] {
            <div className="w-full h-full">
                <div className={"size-16 rounded-full bg-card border border-border flex items-center justify-center " + status_ring(status)}>
                    <WorkerIcon kind={data["label"]} className="text-foreground" active={is_working(status)} size={28} />
                </div>
                <span className="absolute left-1/2 -translate-x-1/2 top-[72px] text-xs font-medium whitespace-nowrap">{data["label"]}</span>
            </div>
        } else {
            <Card className={"w-full bg-card " + status_ring(status)}>
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
        }}
        <Handle type="source" position={Position.Bottom} />
    </div>;
}

def:pub DeploymentNode(data: dict) -> JsxElement {
    status = data["status"];
    return <div className={outer_cls(data)}>
        <Handle type="target" position={Position.Top} />
        {if data["simple"] {
            <div className="w-full h-full">
                <div className={"size-16 rounded-full bg-card border border-border flex items-center justify-center " + status_ring(status)}>
                    <DeploymentIcon className="text-foreground" active={is_working(status)} size={28} />
                </div>
                <span className="absolute left-1/2 -translate-x-1/2 top-[72px] text-xs font-medium whitespace-nowrap">{data["label"]}</span>
            </div>
        } else {
            <Card className={"w-full bg-card " + status_ring(status)}>
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
        }}
        <Handle type="source" position={Position.Bottom} />
    </div>;
}

def:pub MonitoringNode(data: dict) -> JsxElement {
    status = data["status"];
    return <div className={outer_cls(data)}>
        <Handle type="target" position={Position.Top} />
        {if data["simple"] {
            <div className="w-full h-full">
                <div className={"size-16 rounded-full bg-card border border-border flex items-center justify-center " + status_ring(status)}>
                    <MonitoringIcon className="text-foreground" active={is_working(status)} size={28} />
                </div>
                <span className="absolute left-1/2 -translate-x-1/2 top-[72px] text-xs font-medium whitespace-nowrap">{data["label"]}</span>
            </div>
        } else {
            <Card className={"w-full bg-card " + status_ring(status)}>
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
        }}
        <Handle type="source" position={Position.Right} id="fb" />
    </div>;
}
