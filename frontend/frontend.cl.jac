"""WireJac mission control bound to the real Jac OSP graph."""

sv import from .endpoints {
    get_graph_snapshot,
    get_hardware_job,
    get_request_events,
    get_request_history,
    resolve_followup_hardware_approval,
    resolve_hardware_approval,
    submit_build,
    submit_project_followup
}
import from react { useEffect }
import from "lucide-react" { Folder, Plus }
import from "../../../components/ui/ai-prompt-box" { PromptInputBox }
import from .Sidebar { Sidebar }
import from .GraphCanvas { GraphCanvas }
import from .ChatPanel { ChatPanel }
import from .MonitoringBar { MonitoringBar }
import from .TopBar { TopBar }


def latest_followup_route(events: list[dict]) -> str {
    route = "";
    for event in events {
        summary = str(event.get("summary", ""));
        if summary.startswith("User follow-up: ") {
            text = summary.lower();
            is_hardware = "hardware" in text;
            is_frontend = "frontend" in text;
            if is_hardware and not is_frontend { route = "hardware"; }
            elif is_frontend and not is_hardware { route = "frontend"; }
        }
    }
    return route;
}


def build_status(events: list[dict], hardware: dict, route: str = "") -> str {
    status = "running";
    for event in events {
        state = str(event.get("state", ""));
        if state in [
            "planned", "queued", "running", "repairing", "replanning",
            "validating", "deploying", "monitoring"
        ] {
            status = "running";
        }
        if event.get("state") == "awaiting_approval" {
            status = "waiting";
        }
        if event.get("state") == "failed" {
            status = "failed";
        }
        if event.get("node") == "monitoring" and event.get("state") == "succeeded" {
            status = "done";
        }
    }
    if route != "frontend" {
        hardware_status = str(hardware.get("status", ""));
        if hardware.get("awaiting_gate") {
            status = "waiting";
        } elif hardware_status in ["failed", "cancelled", "interrupted", "rolled_back"] {
            status = "failed";
        } elif hardware_status == "succeeded" {
            status = "done";
        } elif hardware_status {
            status = "running";
        }
    }
    return status;
}


def project_dot(status: str) -> str {
    if status == "done" { return "bg-emerald-500"; }
    if status == "running" or status == "waiting" { return "bg-amber-500"; }
    if status == "failed" { return "bg-red-500"; }
    return "bg-muted-foreground/40";
}


def:pub Dashboard(project: dict) -> JsxElement {
    has events: list[dict] = project.get("events", []);
    has status: str = str(project.get("status", "running"));
    has hardware: dict = project.get("hardware", {});
    has resolvingHardware: bool = False;
    has followupRoute: str = latest_followup_route(events);
    has followupHardware: bool = followupRoute == "hardware";
    has followupRunNonce: int = 0;
    has activeHardwareJobId: str = str(project.get("hardware_job_id", ""));
    has simpleView: bool = False;
    request_id = str(project.get("id", ""));
    prompt = str(project.get("prompt", project.get("name", "")));

    def set_simple(value: bool) {
        simpleView = value;
    }

    async def refresh() {
        if status in ["done", "failed"] or (
            status == "waiting" and followupRoute != "frontend"
        ) {
            return;
        }
        if request_id and not request_id.startswith("pending-") {
            nonce = int(Date.now());
            fresh_events = await get_request_events(request_id, nonce);
            fresh_hardware = hardware;
            if activeHardwareJobId {
                fresh_hardware = await get_hardware_job(activeHardwareJobId, nonce);
                hardware = fresh_hardware;
            }
            events = fresh_events;
            status = build_status(fresh_events, fresh_hardware, followupRoute);
        }
    }

    async def resolve_hardware(gate_id: str, accepted: bool) {
        resolvingHardware = True;
        followupRoute = "hardware";
        try {
            if followupHardware {
                result = await resolve_followup_hardware_approval(
                    str(hardware.get("job_id", activeHardwareJobId)),
                    gate_id,
                    accepted,
                    request_id
                );
            } else {
                result = await resolve_hardware_approval(
                    str(hardware.get("job_id", activeHardwareJobId)),
                    gate_id,
                    accepted,
                    prompt,
                    request_id
                );
            }
            hardware = result.get("hardware", {});
            activeHardwareJobId = str(hardware.get("job_id", activeHardwareJobId));
            events = result.get("events", events);
            status = build_status(events, hardware, "hardware");
        } except Exception {
            status = "failed";
        }
        resolvingHardware = False;
    }

    async def submit_followup(message: str, files: any) {
        _ = files;
        text = message.lower();
        route = (
            "hardware" if "hardware" in text and "frontend" not in text else (
                "frontend" if "frontend" in text and "hardware" not in text else ""
            )
        );
        followupRoute = route;
        followupRunNonce = int(Date.now());
        status = "running";
        events = events + [{
            "request_id": request_id,
            "node": "coordinator",
            "state": "running",
            "summary": "User follow-up: " + message,
            "timestamp": "",
            "tool_count": 0,
            "revision": "",
            "hardware_job_id": "",
            "hardware_status": "",
            "error": ""
        }];
        try {
            result = await submit_project_followup(
                request_id,
                prompt,
                message,
                followupRunNonce
            );
            followupRoute = str(result.get("route", route));
            followupHardware = followupRoute == "hardware";
            if followupHardware {
                hardware = result.get("hardware", {});
                activeHardwareJobId = str(hardware.get("job_id", ""));
            }
            events = result.get("events", events);
            status = build_status(events, hardware, followupRoute);
        } except Exception as error {
            events = events + [{
                "request_id": request_id,
                "node": "coordinator",
                "state": "failed",
                "summary": "Follow-up routing failed",
                "timestamp": "",
                "tool_count": 0,
                "revision": "",
                "hardware_job_id": "",
                "hardware_status": "",
                "error": str(error)
            }];
            status = "failed";
        }
    }

    useEffect(lambda {
        refresh();
        interval = setInterval(lambda { refresh(); }, 1000);
        return lambda { clearInterval(interval); };
    }, [request_id, activeHardwareJobId, followupRunNonce]);

    return <div className="h-full w-full flex flex-col bg-background text-foreground">
        <TopBar
            events={events}
            title={str(project.get("name", "WireJac build"))}
            status={status}
        />
        <div className="flex-1 flex flex-col lg:flex-row min-h-0">
            <div className="w-full h-[40%] lg:w-[70%] lg:h-full min-h-0 shrink-0">
                <GraphCanvas events={events} simple={simpleView} onSetSimple={set_simple} />
            </div>
            <div className="w-full h-[60%] lg:w-[30%] lg:h-full min-w-0 min-h-0">
                <ChatPanel
                    prompt={prompt}
                    events={events}
                    status={status}
                    hardware={hardware}
                    resolvingHardware={resolvingHardware}
                    onResolveHardware={resolve_hardware}
                    onFollowup={submit_followup}
                />
            </div>
        </div>
        <MonitoringBar events={events} />
    </div>;
}


def:pub app -> JsxElement {
    has projects: list[dict] = [];
    has activeId: str = "";

    async can with entry {
        document.documentElement.classList.add("dark");
        _ = await get_graph_snapshot();
        projects = await get_request_history();
    }

    def new_build() { activeId = ""; }
    def select_project(project_id: str) { activeId = project_id; }

    async def create_from_prompt(message: str, files: any) {
        pending_id = "pending-" + str(Date.now());
        pending = {
            "id": pending_id,
            "name": message,
            "prompt": message,
            "status": "running",
            "events": [],
            "hardware_job_id": "",
            "hardware": {}
        };
        projects = [pending] + projects;
        activeId = pending_id;
        try {
            result = await submit_build(message);
            projects = [result] + [
                project
                for project in projects
                if project["id"] != pending_id
            ];
            activeId = str(result["id"]);
        } except Exception as error {
            failed = {
                "id": pending_id,
                "name": message,
                "prompt": message,
                "status": "failed",
                "events": [{
                    "node": "coordinator",
                    "state": "failed",
                    "summary": "Build request failed",
                    "error": str(error)
                }],
                "hardware_job_id": "",
                "hardware": {}
            };
            projects = [failed] + [
                project
                for project in projects
                if project["id"] != pending_id
            ];
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

    return <div className="h-screen w-screen flex flex-col lg:flex-row bg-background text-foreground overflow-hidden">
        <Sidebar projects={projects} activeId={activeId} onNew={new_build} onSelect={select_project} />
        <div className="lg:hidden h-12 shrink-0 border-b border-border flex items-center gap-2 px-2 overflow-x-auto">
            <span className="font-semibold px-1 shrink-0">wirejac</span>
            <button
                title="New build"
                onClick={new_build}
                className="size-8 shrink-0 inline-flex items-center justify-center border border-border hover:bg-accent"
            ><Plus className="size-4" /></button>
            {for project in projects {
                <button
                    key={str(project["id"])}
                    title={str(project["name"])}
                    onClick={lambda -> None { select_project(str(project["id"])); }}
                    className={"h-8 max-w-40 shrink-0 inline-flex items-center gap-1.5 px-2 border text-xs " + ("border-primary bg-accent" if str(project["id"]) == activeId else "border-border")}
                >
                    <Folder className="size-3.5 shrink-0" />
                    <span className="truncate">{str(project["name"])}</span>
                    <span className={"size-1.5 rounded-full shrink-0 " + project_dot(str(project["status"]))}></span>
                </button>
            }}
        </div>
        <div className="flex-1 min-w-0 min-h-0 lg:h-full">
            {if found {
                <Dashboard key={str(active["id"])} project={active} />
            } else {
                <div className="h-full w-full flex flex-col items-center justify-center gap-8 p-6">
                    <div className="flex flex-col items-center gap-2 text-center">
                        <h1 className="text-4xl font-semibold">wirejac</h1>
                        <p className="text-muted-foreground max-w-md">
                            Describe what you want built. The Jac graph plans,
                            builds, validates, deploys, and records each activation.
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
