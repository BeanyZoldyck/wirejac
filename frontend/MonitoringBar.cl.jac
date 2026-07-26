"""Bottom monitoring strip — status pill + uptime heartbeat + serial/ping line.
Driven by the run clock (status.marshell.dev vibe)."""

import from .run_script { mon_state }

def status_dot(status: str) -> str {
    if status == "operational" { return "bg-emerald-500"; }
    if status == "degraded" { return "bg-amber-500"; }
    return "bg-muted-foreground/40";
}

def status_word(status: str) -> str {
    if status == "operational" { return "Operational"; }
    if status == "degraded" { return "Degraded"; }
    return "Idle";
}

def:pub MonitoringBar(clock: int) -> JsxElement {
    m = mon_state(clock);
    up = m["up"];
    return <div className="h-10 shrink-0 border-t border-border bg-background flex items-center gap-4 px-4 text-xs">
        <div className="flex items-center gap-2">
            <span className={"inline-block size-2 rounded-full " + status_dot(m["status"])}></span>
            <span className="font-medium">{status_word(m["status"])}</span>
        </div>
        <span className="text-muted-foreground">Monitoring</span>
        <div className="flex items-center gap-0.5">
            {for i in range(8) {
                <span key={str(i)} className={"inline-block w-1 h-3 rounded-sm " + ("bg-emerald-500" if i < up else "bg-muted")}></span>
            }}
        </div>
        <span className="text-muted-foreground font-mono">{m["line"]}</span>
    </div>;
}
