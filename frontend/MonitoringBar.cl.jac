"""Monitoring status derived from persisted Monitoring-node activations."""

import from .run_script { mon_state }

def status_dot(status: str) -> str {
    if status == "operational" { return "bg-emerald-500"; }
    if status == "degraded" { return "bg-red-500"; }
    if status == "checking" { return "bg-amber-500"; }
    return "bg-muted-foreground/40";
}

def:pub MonitoringBar(events: list[dict]) -> JsxElement {
    state = mon_state(events);
    up = int(state["up"]);
    return <div className="h-10 shrink-0 border-t border-border bg-background flex items-center gap-4 px-4 text-xs">
        <div className="flex items-center gap-2">
            <span className={"inline-block size-2 rounded-full " + status_dot(str(state["status"]))}></span>
            <span className="font-medium">{str(state["status"]).title()}</span>
        </div>
        <span className="text-muted-foreground">Monitoring</span>
        <div className="flex items-center gap-0.5">
            {[
                <span key={str(index)} className={"inline-block w-1 h-3 rounded-sm " + ("bg-emerald-500" if index < up else "bg-muted")}></span>
                for index in range(8)
            ]}
        </div>
        <span className="text-muted-foreground font-mono truncate">{state["line"]}</span>
    </div>;
}
