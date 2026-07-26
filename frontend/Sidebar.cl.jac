"""Left sidebar — brand, a New-build button, and the list of build projects
(each build shows as a folder). Selecting one opens its dashboard."""

import from "lucide-react" { Plus, Folder }

def dot(status: str) -> str {
    if status == "running" {
        return "bg-amber-500";
    }
    if status == "done" {
        return "bg-emerald-500";
    }
    return "bg-muted-foreground/40";
}

def:pub Sidebar(
    projects: list,
    activeId: str,
    onNew: Callable[[], None],
    onSelect: Callable[[str], None]
) -> JsxElement {
    return <div className="w-60 shrink-0 h-full border-r border-border bg-background flex flex-col">
        <div className="px-4 py-4">
            <span className="text-base font-semibold tracking-tight">wirejac</span>
        </div>

        <div className="px-3">
            <button
                onClick={onNew}
                className="w-full flex items-center gap-2 rounded-lg border border-border px-3 py-2 text-sm hover:bg-accent transition-colors"
            >
                <Plus className="size-4" />
                New build
            </button>
        </div>

        <div className="px-4 pt-5 pb-1 text-xs font-medium text-muted-foreground">Projects</div>
        <div className="flex-1 overflow-y-auto px-2 flex flex-col gap-0.5">
            {<p className="px-2 py-2 text-xs text-muted-foreground">No builds yet</p> if len(projects) == 0 else <></>}
            {[
                <button
                    key={p["id"]}
                    onClick={lambda -> None { onSelect(p["id"]); }}
                    className={"w-full flex items-center gap-2 rounded-lg px-2 py-2 text-sm text-left transition-colors " + ("bg-accent" if p["id"] == activeId else "hover:bg-accent/50")}
                >
                    <Folder className="size-4 shrink-0 text-muted-foreground" />
                    <span className="truncate flex-1">{p["name"]}</span>
                    <span className={"size-2 rounded-full shrink-0 " + dot(p["status"])}></span>
                </button>
                for p in projects
            ]}
        </div>

        <div className="p-3 border-t border-border flex items-center gap-2">
            <div className="size-7 rounded-full bg-primary text-primary-foreground flex items-center justify-center text-xs font-medium">W</div>
            <div className="text-xs leading-tight">
                <div className="font-medium">wirejac</div>
                <div className="text-muted-foreground">local</div>
            </div>
        </div>
    </div>;
}
