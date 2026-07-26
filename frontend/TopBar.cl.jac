"""Top app bar — current build name, pipeline stepper, elapsed timer, status."""

import from .run_script { pipeline_phase }

glob STEPS: list[dict] = [
    {"key": "plan", "n": "1", "label": "Plan"},
    {"key": "build", "n": "2", "label": "Build"},
    {"key": "deploy", "n": "3", "label": "Deploy"},
    {"key": "monitor", "n": "4", "label": "Monitor"}
];

def phase_rank(p: str) -> int {
    if p == "plan" { return 0; }
    if p == "build" { return 1; }
    if p == "deploy" { return 2; }
    return 3;
}

def step_active(step_key: str, phase: str) -> bool {
    return phase_rank(step_key) <= phase_rank(phase);
}

def pad2(n: int) -> str {
    if n < 10 {
        return "0" + str(n);
    }
    return str(n);
}

def fmt_time(clock: int) -> str {
    secs = clock // 1000;
    return pad2(secs // 60) + ":" + pad2(secs % 60);
}

def:pub TopBar(clock: int, title: str) -> JsxElement {
    phase = pipeline_phase(clock);
    return <div className="h-12 shrink-0 border-b border-border bg-background flex items-center px-4 gap-4">
        <div className="w-56 shrink-0 min-w-0 flex items-center">
            <span className="text-sm font-medium truncate">{title}</span>
        </div>

        <div className="flex-1 flex items-center justify-center gap-2">
            {for (i, s) in enumerate(STEPS) {
                <div key={s["key"]} className="flex items-center gap-2">
                    {if i > 0 { <span className="text-muted-foreground/40 text-xs">—</span> }}
                    <div className={"flex items-center gap-1.5 " + ("text-foreground" if step_active(s["key"], phase) else "text-muted-foreground/50")}>
                        <span className={"flex items-center justify-center size-5 rounded-full text-[10px] font-medium " + ("bg-primary text-primary-foreground" if step_active(s["key"], phase) else "bg-muted text-muted-foreground")}>{s["n"]}</span>
                        <span className="text-xs font-medium">{s["label"]}</span>
                    </div>
                </div>
            }}
        </div>

        <div className="w-56 shrink-0 flex items-center justify-end gap-3">
            <span className="text-xs font-mono text-muted-foreground">{fmt_time(clock)}</span>
            <div className="flex items-center gap-1.5">
                <span className="inline-block size-2 rounded-full bg-emerald-500"></span>
                <span className="text-xs">Live</span>
            </div>
        </div>
    </div>;
}
