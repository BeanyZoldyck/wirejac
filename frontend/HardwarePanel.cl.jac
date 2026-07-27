"""Hardware lifecycle, approval gates, and generated assembly visuals."""

import from "lucide-react" { Check, ChevronLeft, ChevronRight, Cpu, X }


def status_class(status: str) -> str {
    if status == "succeeded" { return "bg-emerald-500"; }
    if status in ["failed", "blocked", "cancelled", "rolled_back"] {
        return "bg-red-500";
    }
    return "bg-amber-500";
}


def:pub HardwarePanel(
    hardware: dict,
    resolving: bool,
    onResolve: Callable[[str, bool], None]
) -> JsxElement {
    has stepIndex: int = 0;
    status = str(hardware.get("status", "queued"));
    artifact_values: list[dict] = hardware.get("artifacts", []);
    hardware_events: list[dict] = hardware.get("events", []);
    recent_events = hardware_events[-8:] if len(hardware_events) > 8 else hardware_events;
    steps: list[dict] = [];
    for artifact in artifact_values {
        if artifact.get("kind") == "assembly_step_svg" and artifact.get("data_url") {
            steps.append(artifact);
        }
    }
    active: dict = steps[stepIndex] if stepIndex < len(steps) else {};
    gates: list[dict] = hardware.get("open_gates", []);

    return <section className="w-full min-w-0 border border-border bg-card overflow-hidden">
        <div className="flex items-center justify-between gap-3 px-3 py-2 border-b border-border">
            <div className="flex items-center gap-2 min-w-0">
                <Cpu className="size-4 text-primary shrink-0" />
                <div className="min-w-0">
                    <p className="text-xs font-medium">ESP32 hardware job</p>
                    <p className="text-[10px] text-muted-foreground font-mono truncate">
                        {str(hardware.get("job_id", ""))}
                    </p>
                </div>
            </div>
            <div className="flex items-center gap-1.5 shrink-0">
                <span className={"size-2 rounded-full " + status_class(status)}></span>
                <span className="text-[10px] uppercase text-muted-foreground">{status}</span>
            </div>
        </div>

        {if len(steps) > 0 {
            <div className="bg-white border-b border-border">
                <img
                    src={str(active.get("data_url", ""))}
                    alt={str(active.get("name", "Assembly step"))}
                    className="w-full aspect-[4/3] object-contain"
                />
                <div className="flex items-center justify-between gap-2 px-2 py-1.5 bg-background text-[10px]">
                    <button
                        title="Previous assembly step"
                        disabled={stepIndex == 0}
                        onClick={lambda -> None { stepIndex = max(0, stepIndex - 1); }}
                        className="size-7 inline-flex items-center justify-center border border-border disabled:opacity-30 hover:bg-accent"
                    ><ChevronLeft className="size-4" /></button>
                    <span className="text-muted-foreground">
                        Step {stepIndex + 1} of {len(steps)}
                    </span>
                    <button
                        title="Next assembly step"
                        disabled={stepIndex >= len(steps) - 1}
                        onClick={lambda -> None { stepIndex = min(len(steps) - 1, stepIndex + 1); }}
                        className="size-7 inline-flex items-center justify-center border border-border disabled:opacity-30 hover:bg-accent"
                    ><ChevronRight className="size-4" /></button>
                </div>
            </div>
        }}

        <div className="px-3 py-2 text-xs text-muted-foreground">
            {str(hardware.get("summary", "Hardware lifecycle queued"))}
            <span className="ml-2 font-mono">
                {int(hardware.get("artifact_count", 0))} artifacts
            </span>
        </div>

        {if len(recent_events) > 0 {
            <div className="px-3 py-2 border-t border-border flex flex-col gap-1.5">
                {for event in recent_events {
                    <div key={str(event.get("sequence", ""))} className="grid grid-cols-[auto_1fr] gap-2 text-[10px] leading-relaxed">
                        <span className="font-mono uppercase text-muted-foreground">
                            {str(event.get("phase", "hardware"))}
                        </span>
                        <span>{str(event.get("message", "Working"))}</span>
                    </div>
                }}
            </div>
        }}

        {for gate in gates {
            <div key={str(gate["gate_id"])} className="px-3 py-3 border-t border-border flex flex-col gap-2">
                <div>
                    <p className="text-xs font-medium">{str(gate["title"])}</p>
                    <p className="text-[11px] leading-relaxed text-muted-foreground">
                        {str(gate["instructions"])}
                    </p>
                </div>
                <div className="flex items-center gap-2">
                    <button
                        disabled={resolving}
                        onClick={lambda -> None { onResolve(str(gate["gate_id"]), True); }}
                        className="h-8 px-3 inline-flex items-center gap-1.5 bg-primary text-primary-foreground text-xs disabled:opacity-50"
                    ><Check className="size-3.5" />Approve</button>
                    <button
                        disabled={resolving}
                        onClick={lambda -> None { onResolve(str(gate["gate_id"]), False); }}
                        className="h-8 px-3 inline-flex items-center gap-1.5 border border-border text-xs disabled:opacity-50 hover:bg-accent"
                    ><X className="size-3.5" />Reject</button>
                </div>
            </div>
        }}
    </section>;
}
