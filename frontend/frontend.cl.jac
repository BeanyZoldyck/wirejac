"""wirejac — client entry (mission-control shell with projects sidebar).

A left sidebar lists build projects (folders); the main area shows either the
chat-first landing (New build) or the selected project's dashboard: a top
pipeline bar, a 70/30 split (React Flow graph + streaming conversation), and a
bottom monitoring strip — all animated by a single mock run clock.
"""

import from react { useEffect }
# Client bundles are emitted to .jac/client/compiled; this reaches the retained
# TypeScript UI component from that generated location.
import from "../../../components/ui/ai-prompt-box" { PromptInputBox }
import from .Sidebar { Sidebar }
import from .GraphCanvas { GraphCanvas }
import from .ChatPanel { ChatPanel }
import from .MonitoringBar { MonitoringBar }
import from .TopBar { TopBar }

def:pub Dashboard(prompt: str, title: str) -> JsxElement {
    has clock: int = 0;
    has clockRef: Ref[int] = Ref(0);
    has idRef: Ref[int] = Ref(0);
    has simpleView: bool = False;

    def set_simple(v: bool) {
        simpleView = v;
    }

    # One run clock ticks every 200ms; everything derives from it. Ref-backed
    # accumulator avoids setInterval stale-closure bugs; cleanup on unmount.
    useEffect(lambda {
        idRef.current = setInterval(lambda {
            clockRef.current = clockRef.current + 200;
            clock = clockRef.current;
            if clockRef.current >= 24000 {
                clearInterval(idRef.current);
            }
        }, 200);
        return lambda { clearInterval(idRef.current); };
    }, []);

    return <div className="h-full w-full flex flex-col bg-background text-foreground">
        <TopBar clock={clock} title={title} />
        <div className="flex-1 flex min-h-0">
            <div className="w-[70%] h-full">
                <GraphCanvas clock={clock} simple={simpleView} onSetSimple={set_simple} />
            </div>
            <div className="w-[30%] h-full min-w-0">
                <ChatPanel prompt={prompt} clock={clock} />
            </div>
        </div>
        <MonitoringBar clock={clock} />
    </div>;
}

def:pub app -> JsxElement {
    # Each submitted build becomes a project { id, name, prompt, status }.
    has projects: list[dict] = [];
    has activeId: str = "";

    # Dark mode: flip the whole shadcn palette by adding `.dark` to <html>.
    can with entry {
        document.documentElement.classList.add("dark");
    }

    def new_build() {
        activeId = "";
    }

    def select_project(pid: str) {
        activeId = pid;
    }

    def create_from_prompt(message: str, files: any) {
        newid = "p" + str(len(projects) + 1);
        proj = {"id": newid, "name": message, "prompt": message, "status": "running"};
        projects = projects + [proj];   # rebind, never mutate
        activeId = newid;
    }

    active: dict = {};
    found = False;
    for p in projects {
        if p["id"] == activeId {
            active = p;
            found = True;
        }
    }

    return <div className="h-screen w-screen flex bg-background text-foreground overflow-hidden">
        <Sidebar projects={projects} activeId={activeId} onNew={new_build} onSelect={select_project} />
        <div className="flex-1 min-w-0 h-full">
            {if found {
                <Dashboard key={active["id"]} prompt={active["prompt"]} title={active["name"]} />
            } else {
                <div className="h-full w-full flex flex-col items-center justify-center gap-8 p-6">
                    <div className="flex flex-col items-center gap-2 text-center">
                        <h1 className="text-4xl font-semibold tracking-tight">wirejac</h1>
                        <p className="text-muted-foreground max-w-md">
                            Describe what you want built — wirejac plans it, wires up worker agents, deploys it, and watches it run live.
                        </p>
                    </div>
                    <div className="w-full max-w-2xl">
                        <PromptInputBox placeholder="build me ___ that does ___" onSend={create_from_prompt} />
                    </div>
                </div>
            }}
        </div>
    </div>;
}
