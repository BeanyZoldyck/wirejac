"""Pipeline phase bar derived from real graph activations."""

import from .run_script { pipeline_phase }

glob STEPS: list[dict] = [
    {"key": "plan", "n": "1", "label": "Plan"},
    {"key": "build", "n": "2", "label": "Build"},
    {"key": "deploy", "n": "3", "label": "Deploy"},
    {"key": "monitor", "n": "4", "label": "Monitor"}
];

def phase_rank(phase: str) -> int {
    if phase == "plan" { return 0; }
    if phase == "build" { return 1; }
    if phase == "deploy" { return 2; }
    return 3;
}

def:pub TopBar(events: list[dict], title: str, status: str) -> JsxElement {
    phase = pipeline_phase(events);
    return <div className="h-12 shrink-0 border-b border-border bg-background flex items-center px-4 gap-4">
        <div className="w-56 shrink-0 min-w-0 flex items-center">
            <span className="text-sm font-medium truncate">{title}</span>
        </div>
        <div className="flex-1 flex items-center justify-center gap-2">
            {[
                <div key={step["key"]} className="flex items-center gap-2">
                    {<span className="text-muted-foreground/40 text-xs">—</span> if index > 0 else <></>}
                    <div className={"flex items-center gap-1.5 " + ("text-foreground" if phase_rank(step["key"]) <= phase_rank(phase) else "text-muted-foreground/50")}>
                        <span className={"flex items-center justify-center size-5 rounded-full text-[10px] font-medium " + ("bg-primary text-primary-foreground" if phase_rank(step["key"]) <= phase_rank(phase) else "bg-muted text-muted-foreground")}>{step["n"]}</span>
                        <span className="text-xs font-medium">{step["label"]}</span>
                    </div>
                </div>
                for (index, step) in enumerate(STEPS)
            ]}
        </div>
        <div className="w-56 shrink-0 flex items-center justify-end gap-2">
            <span className={"inline-block size-2 rounded-full " + ("bg-emerald-500" if status == "done" else ("bg-red-500" if status == "failed" else "bg-amber-500"))}></span>
            <span className="text-xs capitalize">{status}</span>
        </div>
    </div>;
}
