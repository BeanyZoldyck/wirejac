"""Wirejac dashboard bound to the real Jac OSP orchestration graph."""

sv import from .endpoints {
    submit_build,
    get_request_events,
    get_request_history,
    get_graph_snapshot
}
import from "../../../components/ui/ai-prompt-box" { PromptInputBox }
import from .Sidebar { Sidebar }
import from .GraphCanvas { GraphCanvas }
import from .ChatPanel { ChatPanel }
import from .MonitoringBar { MonitoringBar }
import from .TopBar { TopBar }

def:pub Dashboard(project: dict) -> JsxElement {
    has simpleView: bool = False;
    events: list[dict] = list(project.get("events", []));
    status = str(project.get("status", "running"));

    def set_simple(v: bool) {
        simpleView = v;
    }

    return <div className="h-full w-full flex flex-col bg-background text-foreground">
        <TopBar events={events} title={str(project.get("name", "Wirejac build"))} status={status} />
        <div className="flex-1 flex min-h-0">
            <div className="w-[70%] h-full">
                <GraphCanvas events={events} simple={simpleView} onSetSimple={set_simple} />
            </div>
            <div className="w-[30%] h-full min-w-0">
                <ChatPanel prompt={str(project.get("prompt", ""))} events={events} status={status} />
            </div>
        </div>
        <MonitoringBar events={events} />
    </div>;
}

def:pub app -> JsxElement {
    has projects: list[dict] = [];
    has activeId: str = "";
    has topology: dict = {};

    async can with entry {
        document.documentElement.classList.add("dark");
        topology = await get_graph_snapshot();
        projects = await get_request_history();
    }

    def new_build() { activeId = ""; }
    def select_project(pid: str) { activeId = pid; }

    async def create_from_prompt(message: str, files: any) {
        pending_id = "pending-" + str(len(projects) + 1);
        pending = {
            "id": pending_id,
            "name": message,
            "prompt": message,
            "status": "running",
            "events": []
        };
        projects = [pending] + projects;
        activeId = pending_id;
        try {
            result = await submit_build(message);
            projects = [result] + [project for project in projects if project["id"] != pending_id];
            activeId = str(result["id"]);
        } except Exception as error {
            failed = {**pending, "status": "failed", "events": [{
                "node": "coordinator",
                "state": "failed",
                "summary": "Build request failed",
                "error": str(error)
            }]};
            projects = [failed] + [project for project in projects if project["id"] != pending_id];
        }
    }

    active: dict = {};
    found = False;
    for project in projects {
        if project["id"] == activeId {
            active = project;
            found = True;
        }
    }

    content = <div className="h-full w-full flex flex-col items-center justify-center gap-8 p-6">
        <div className="flex flex-col items-center gap-2 text-center">
            <h1 className="text-4xl font-semibold tracking-tight">wirejac</h1>
            <p className="text-muted-foreground max-w-md">
                Describe what you want built. The real Jac graph plans,
                edits, validates, deploys, and records every activation.
            </p>
        </div>
        <div className="w-full max-w-2xl">
            <PromptInputBox placeholder="build me ___ that does ___" onSend={create_from_prompt} />
        </div>
    </div>;
    if found {
        content = <Dashboard key={str(active["id"])} project={active} />;
    }

    return <div className="h-screen w-screen flex bg-background text-foreground overflow-hidden">
        <Sidebar projects={projects} activeId={activeId} onNew={new_build} onSelect={select_project} />
        <div className="flex-1 min-w-0 h-full">
            {content}
        </div>
    </div>;
}
