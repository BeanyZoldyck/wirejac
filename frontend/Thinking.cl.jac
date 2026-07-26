"""Agent 'thinking…' indicator — the animated matrix loader (assets/matrix-loader.svg,
inlined via components/ui/matrix-loader.tsx), shown in the conversation while the
agent works on the next step."""

import from "./components/ui/matrix-loader" { MatrixLoader }

def:pub Thinking() -> JsxElement {
    return <div className="flex items-center gap-2 text-muted-foreground py-1">
        <MatrixLoader size={16} />
        <span className="text-xs">thinking…</span>
    </div>;
}
