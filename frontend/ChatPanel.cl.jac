"""Right-pane conversation: the user's prompt, streaming agent messages with
inline tool-call blocks, and a docked prompt box. Driven by the run clock."""

import from .run_script { chat_upto }
import from "./components/ui/tool-calls-section" { ToolCallsSection }
import from "./components/ui/ai-prompt-box" { PromptInputBox }
import from .Thinking { Thinking }

def:pub ChatPanel(prompt: str, clock: int) -> JsxElement {
    has scrollRef: Ref[HTMLDivElement] = Ref();

    messages = chat_upto(clock);
    # Agent is still working while the run hasn't produced its last message.
    streaming = clock < 21500;

    # Auto-scroll to the newest message as the run streams.
    can with [clock] entry {
        if scrollRef.current {
            scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
        }
    }

    def handle_followup(message: str, files: any) {
        # Follow-ups are cosmetic in the mock run.
    }

    return <div className="h-full flex flex-col bg-background border-l border-border">
        <div className="px-4 py-3 border-b border-border shrink-0">
            <p className="text-sm font-medium">Conversation</p>
        </div>

        <div ref={scrollRef} className="flex-1 overflow-y-auto p-4 flex flex-col gap-4">
            <div className="flex justify-end">
                <div className="max-w-[85%] rounded-2xl bg-primary text-primary-foreground px-3 py-2 text-sm">{prompt}</div>
            </div>

            {for (i, m) in enumerate(messages) {
                <div key={str(i)} className="flex flex-col gap-1.5">
                    <div className="max-w-[95%] text-sm text-foreground leading-relaxed">{m["text"]}</div>
                    {if len(m["tools"]) > 0 {
                        <ToolCallsSection toolCalls={m["tools"]} />
                    }}
                </div>
            }}

            {if streaming { <Thinking /> }}
        </div>

        <div className="p-3 border-t border-border shrink-0">
            <PromptInputBox placeholder="Ask a follow-up…" onSend={handle_followup} />
        </div>
    </div>;
}
