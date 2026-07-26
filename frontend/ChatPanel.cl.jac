"""Real activation summaries and contained tool evidence for one build."""

import from .run_script { chat_from_events }
import from "../../../components/ui/tool-calls-section" { ToolCallsSection }
import from "../../../components/ui/ai-prompt-box" { PromptInputBox }
import from .Thinking { Thinking }

def:pub ChatPanel(prompt: str, events: list[dict], status: str) -> JsxElement {
    has scrollRef: Ref[HTMLDivElement] = Ref();
    messages = chat_from_events(events);
    streaming = status == "running";

    can with [len(events)] entry {
        if scrollRef.current {
            scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
        }
    }

    def handle_followup(message: str, files: any) {}

    return <div className="h-full flex flex-col bg-background border-l border-border">
        <div className="px-4 py-3 border-b border-border shrink-0">
            <p className="text-sm font-medium">Build log</p>
            <p className="text-[11px] text-muted-foreground">{len(events)} persisted activations</p>
        </div>
        <div ref={scrollRef} className="flex-1 overflow-y-auto p-4 flex flex-col gap-4">
            <div className="flex justify-end">
                <div className="max-w-[85%] rounded-2xl bg-primary text-primary-foreground px-3 py-2 text-sm">{prompt}</div>
            </div>
            {for (index, message) in enumerate(messages) {
                <div key={str(index)} className="flex flex-col gap-1.5">
                    <div className="flex items-center gap-2 text-[10px] uppercase tracking-wide text-muted-foreground">
                        <span>{message["node"]}</span><span>{message["state"]}</span>
                    </div>
                    <div className="max-w-[95%] text-sm text-foreground leading-relaxed">{message["text"]}</div>
                    {if len(message["tools"]) > 0 {
                        <ToolCallsSection toolCalls={message["tools"]} />
                    }}
                </div>
            }}
            {if streaming { <Thinking /> }}
        </div>
        <div className="p-3 border-t border-border shrink-0">
            <PromptInputBox placeholder="Follow-up support coming next" onSend={handle_followup} />
        </div>
    </div>;
}
