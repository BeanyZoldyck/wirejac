"""Jac-native WireJac project graph and request walkers."""

import from orchestrator.models {
    Activation,
    ActivationState,
    AgentResult,
    DeploymentResult,
    ImpactPlan,
    MonitorResult,
    WorkspaceKind
}
import from orchestrator.adapters {
    deploy,
    emit_activation,
    monitor,
    new_request_id,
    now,
    plan_change,
    run_workspace_agent
}
import from hardware.contracts { JobStatus }
import from orchestrator.hardware_bridge {
    HardwareDispatch,
    dispatch_hardware_job,
    hardware_dispatch_snapshot,
    refresh_hardware_job,
    resolve_hardware_gate
}


node Coordinator {
    has name: str = "coordinator",
        max_replans: int = 2;

    can invoke_planner with ChangeRequest entry {
        visitor.record(self.name, ActivationState.RUNNING, "Planning workspace impact");
        visitor.completed = [];
        visitor.results = {};
        visitor.failed = False;
        visitor.hardware_job_id = "";
        visitor.hardware_revision_id = "";
        visitor.hardware_status = "";
        visitor.hardware_event_sequence = 0;
        visitor.awaiting_hardware_gate = False;
        workspaces: list[dict] = [];
        for workspace in [self ->:Dispatch:->][?:Client] {
            workspaces.append(workspace_context(workspace));
        }
        for workspace in [self ->:Dispatch:->][?:Server] {
            workspaces.append(workspace_context(workspace));
        }
        for workspace in [self ->:Dispatch:->][?:Device] {
            workspaces.append(workspace_context(workspace));
        }
        try {
            visitor.plan = plan_change(visitor.prompt, workspaces);
            plan_error = validate_plan(visitor.plan, workspaces);
            if plan_error {
                visitor.failed = True;
                visitor.record(
                    self.name,
                    ActivationState.FAILED,
                    "Invalid impact plan",
                    error=plan_error
                );
            } else {
                for name in visitor.plan.selected {
                    visitor.record(
                        name,
                        ActivationState.PLANNED,
                        visitor.plan.tasks.get(name, visitor.prompt)
                    );
                }
                for (name, reason) in visitor.plan.skipped.items() {
                    visitor.record(name, ActivationState.SKIPPED, reason);
                }
                visitor.record(self.name, ActivationState.SUCCEEDED, "Impact plan ready");
            }
        } except Exception as error {
            visitor.failed = True;
            visitor.record(
                self.name,
                ActivationState.FAILED,
                "Coordinator agent failed",
                error=str(error)
            );
        }
    }
}


node Workspace {
    has name: str,
        kind: WorkspaceKind,
        path: str,
        skill_path: str,
        spec_path: str,
        allowed_commands: list[str] = [];

    can invoke_agent with ChangeRequest entry {
        if self.kind == WorkspaceKind.DEVICE {
            visitor.run_hardware_device(self);
            return;
        }
        visitor.record(self.name, ActivationState.RUNNING, "Running contained workspace agent");
        task = visitor.plan.tasks.get(self.name, visitor.prompt);
        try {
            result = run_workspace_agent(
                visitor.request_id,
                self.name,
                self.path,
                self.skill_path,
                self.spec_path,
                task,
                visitor.plan.acceptance,
                self.allowed_commands
            );
            visitor.results[self.name] = result;
            if result.success {
                visitor.completed.append(self.name);
                visitor.record(
                    self.name,
                    ActivationState.SUCCEEDED,
                    result.summary,
                    result.tool_count,
                    result.revision
                );
            } else {
                visitor.failed = True;
                visitor.record(
                    self.name,
                    ActivationState.FAILED,
                    result.summary,
                    result.tool_count,
                    result.revision,
                    result.error
                );
            }
        } except Exception as error {
            visitor.failed = True;
            visitor.record(
                self.name,
                ActivationState.FAILED,
                "Workspace agent failed",
                error=str(error)
            );
        }
    }
}


node Client(Workspace) {}
node Server(Workspace) {}
node Device(Workspace) {}


node Deployment {
    has name: str = "deployment";

    can execute with ChangeRequest entry {
        visitor.record(self.name, ActivationState.DEPLOYING, "Running deterministic deployment");
        try {
            deploy_workspaces = visitor.plan.selected;
            hardware_ready = True;
            if visitor.hardware_job_id {
                hardware = refresh_hardware_job(
                    visitor.hardware_job_id,
                    visitor.hardware_event_sequence
                );
                visitor.record_hardware_events(hardware);
                visitor.hardware_status = hardware.status.value;
                hardware_ready = hardware.success;
                if not hardware_ready {
                    visitor.deployment_result = DeploymentResult(
                        success=False,
                        summary="Hardware lifecycle is not ready for deployment",
                        artifact=visitor.hardware_job_id,
                        error=hardware.error or hardware.summary
                    );
                } else {
                    deploy_workspaces = [
                        name
                        for name in visitor.plan.selected
                        if name != "device"
                    ];
                }
            }
            if hardware_ready and not deploy_workspaces {
                visitor.deployment_result = DeploymentResult(
                    success=True,
                    summary=(
                        "Hardware lifecycle completed; no non-device deployment "
                        + "is required"
                    ),
                    artifact=visitor.hardware_job_id
                );
            } elif hardware_ready {
                visitor.deployment_result = deploy(
                    deploy_workspaces,
                    visitor.plan.deployment_intent,
                    visitor.request_id
                );
            }
            if visitor.deployment_result.awaiting_approval {
                visitor.record(
                    self.name,
                    ActivationState.AWAITING_APPROVAL,
                    visitor.deployment_result.summary,
                    revision=visitor.deployment_result.artifact
                );
            } elif visitor.deployment_result.success {
                visitor.record(
                    self.name,
                    ActivationState.SUCCEEDED,
                    visitor.deployment_result.summary
                );
            } else {
                visitor.failed = True;
                visitor.record(
                    self.name,
                    ActivationState.FAILED,
                    visitor.deployment_result.summary,
                    error=visitor.deployment_result.error
                );
            }
        } except Exception as error {
            visitor.failed = True;
            visitor.record(
                self.name,
                ActivationState.FAILED,
                "Deployment adapter failed",
                error=str(error)
            );
        }
    }
}


node Monitoring {
    has name: str = "monitoring";

    can observe with ChangeRequest entry {
        visitor.record(self.name, ActivationState.MONITORING, "Checking acceptance and runtime health");
        try {
            hardware_ready = True;
            if visitor.hardware_job_id {
                hardware = refresh_hardware_job(
                    visitor.hardware_job_id,
                    visitor.hardware_event_sequence
                );
                visitor.record_hardware_events(hardware);
                visitor.hardware_status = hardware.status.value;
                hardware_ready = hardware.success;
                if not hardware_ready {
                    visitor.monitor_result = MonitorResult(
                        success=False,
                        summary="Hardware lifecycle is not healthy",
                        errors=[hardware.error or hardware.summary]
                    );
                }
            }
            if hardware_ready {
                visitor.monitor_result = monitor(visitor.plan.acceptance);
            }
            if visitor.monitor_result.success {
                visitor.record(
                    self.name,
                    ActivationState.SUCCEEDED,
                    visitor.monitor_result.summary
                );
            } else {
                visitor.record(
                    self.name,
                    ActivationState.FAILED,
                    visitor.monitor_result.summary,
                    error="; ".join(visitor.monitor_result.errors)
                );
            }
        } except Exception as error {
            visitor.monitor_result = MonitorResult(
                success=False,
                summary="Monitoring adapter failed",
                errors=[str(error)]
            );
            visitor.record(
                self.name,
                ActivationState.FAILED,
                visitor.monitor_result.summary,
                error=str(error)
            );
        }
    }
}


edge Dispatch {}
edge ReadyToDeploy {}
edge Verify {}
edge Feedback {}
edge Project {}

walker ChangeRequest {
    has prompt: str,
        request_id: str = "",
        emit_reports: bool = True,
        plan: ImpactPlan = ImpactPlan(),
        activations: list[Activation] = [],
        results: dict[str, AgentResult] = {},
        completed: list[str] = [],
        replan_count: int = 0,
        failed: bool = False,
        hardware_job_id: str = "",
        hardware_revision_id: str = "",
        hardware_status: str = "",
        hardware_event_sequence: int = 0,
        awaiting_hardware_gate: bool = False,
        deployment_result: DeploymentResult = DeploymentResult(),
        monitor_result: MonitorResult = MonitorResult();

    def record(
        node_name: str,
        state: ActivationState,
        summary: str = "",
        tool_count: int = 0,
        revision: str = "",
        error: str = ""
    ) {
        activation = Activation(
            request_id=self.request_id,
            node_name=node_name,
            state=state,
            summary=summary,
            timestamp=now(),
            tool_count=tool_count,
            revision=revision,
            hardware_job_id=(
                self.hardware_job_id if node_name == "device" else ""
            ),
            hardware_status=(
                self.hardware_status if node_name == "device" else ""
            ),
            error=error
        );
        self.activations.append(activation);
        emit_activation(activation);
    }

    def hardware_activation_state(status: JobStatus) -> ActivationState {
        if status == JobStatus.QUEUED {
            return ActivationState.QUEUED;
        }
        if status == JobStatus.VALIDATING {
            return ActivationState.VALIDATING;
        }
        if status in [JobStatus.ASSEMBLY_REQUIRED, JobStatus.BLOCKED] {
            return ActivationState.AWAITING_APPROVAL;
        }
        if status in [JobStatus.PROVISIONING, JobStatus.DEPLOYING] {
            return ActivationState.DEPLOYING;
        }
        if status == JobStatus.VERIFYING {
            return ActivationState.MONITORING;
        }
        if status == JobStatus.SUCCEEDED {
            return ActivationState.SUCCEEDED;
        }
        if status in [
            JobStatus.FAILED,
            JobStatus.CANCELLED,
            JobStatus.INTERRUPTED,
            JobStatus.ROLLED_BACK,
        ] {
            return ActivationState.FAILED;
        }
        return ActivationState.RUNNING;
    }

    def record_hardware_events(result: HardwareDispatch) {
        for event in result.events {
            if event.sequence <= self.hardware_event_sequence {
                continue;
            }
            event_error = "";
            if event.status in [
                JobStatus.FAILED,
                JobStatus.CANCELLED,
                JobStatus.INTERRUPTED,
                JobStatus.ROLLED_BACK,
            ] {
                event_error = event.message;
            }
            self.record(
                "device",
                self.hardware_activation_state(event.status),
                event.message,
                revision=result.revision_id,
                error=event_error
            );
            self.hardware_event_sequence = event.sequence;
        }
    }

    def run_hardware_device(workspace: Workspace) {
        self.record(workspace.name, ActivationState.RUNNING, "Running guarded hardware lifecycle");
        task = self.plan.tasks.get(workspace.name, self.prompt);
        hardware = dispatch_hardware_job(
            self.request_id,
            self.prompt,
            task,
            self.replan_count
        );
        self.hardware_job_id = hardware.job_id;
        self.hardware_revision_id = hardware.revision_id;
        self.hardware_status = hardware.status.value;
        self.record_hardware_events(hardware);
        gate_ids = [gate.gate_id for gate in hardware.open_gates];
        self.results[workspace.name] = AgentResult(
            success=hardware.success,
            summary=hardware.summary,
            revision=hardware.revision_id,
            hardware_job_id=hardware.job_id,
            hardware_status=hardware.status.value,
            hardware_gate_ids=gate_ids,
            error=hardware.error
        );
        if hardware.awaiting_gate {
            self.awaiting_hardware_gate = True;
            for gate in hardware.open_gates {
                self.record(
                    workspace.name,
                    ActivationState.AWAITING_APPROVAL,
                    "Hardware gate " + gate.gate_id + ": " + gate.title
                    + " - " + gate.instructions,
                    revision=hardware.revision_id
                );
            }
        } elif hardware.success {
            if workspace.name not in self.completed {
                self.completed.append(workspace.name);
            }
            self.record(
                workspace.name,
                ActivationState.SUCCEEDED,
                hardware.summary,
                revision=hardware.revision_id
            );
        } else {
            self.failed = True;
            self.record(
                workspace.name,
                ActivationState.FAILED,
                hardware.summary,
                revision=hardware.revision_id,
                error=hardware.error
            );
        }
    }

    can begin with Root entry {
        if not self.request_id {
            self.request_id = new_request_id();
        }
        visit ensure_graph();
    }

    can route_plan with Coordinator exit {
        if self.failed or self.replan_count > here.max_replans {
            if self.replan_count > here.max_replans {
                self.record(here.name, ActivationState.FAILED, "Replan limit exceeded");
            }
            if self.emit_reports {
                report self.activations;
            }
            disengage;
        }
        for workspace in [here ->:Dispatch:->][?:Client] {
            if workspace.name in self.plan.selected and workspace.name not in self.completed {
                self.record(workspace.name, ActivationState.QUEUED, "Selected by Coordinator");
                visit workspace;
            }
        }
        for workspace in [here ->:Dispatch:->][?:Server] {
            if workspace.name in self.plan.selected and workspace.name not in self.completed {
                self.record(workspace.name, ActivationState.QUEUED, "Selected by Coordinator");
                visit workspace;
            }
        }
        for workspace in [here ->:Dispatch:->][?:Device] {
            if workspace.name in self.plan.selected and workspace.name not in self.completed {
                self.record(workspace.name, ActivationState.QUEUED, "Selected by Coordinator");
                visit workspace;
            }
        }
    }

    can route_workspace with Workspace exit {
        result = self.results.get(here.name);
        if self.awaiting_hardware_gate {
            if self.emit_reports {
                report self.activations;
            }
            disengage;
        } elif result and result.contract_changed {
            self.replan_count += 1;
            self.record(
                here.name,
                ActivationState.REPLANNING,
                "Local API specification changed"
            );
            self.prompt = (
                self.prompt
                + f"\nReplan because {here.name}/api-spec.md changed. "
                + "Select every workspace required by the revised contract."
            );
            visit [here <-:Dispatch:<-][?:Coordinator];
        } elif self.failed {
            if self.emit_reports {
                report self.activations;
            }
            disengage;
        } elif len(self.completed) == len(self.plan.selected) {
            visit [here ->:ReadyToDeploy:->][?:Deployment];
        }
    }

    can route_deployment with Deployment exit {
        if self.deployment_result.awaiting_approval {
            if self.emit_reports {
                report self.activations;
            }
            disengage;
        }
        if self.failed or not self.deployment_result.success {
            self.failed = True;
            if self.emit_reports {
                report self.activations;
            }
            disengage;
        }
        visit [here ->:Verify:->][?:Monitoring];
    }

    can route_monitoring with Monitoring exit {
        if self.monitor_result.success {
            if self.emit_reports {
                report self.activations;
            }
            disengage;
        }
        self.replan_count += 1;
        self.record(
            here.name,
            ActivationState.REPLANNING,
            "Monitoring requested repair"
        );
        self.prompt = (
            self.prompt
            + "\nRepair these monitoring failures: "
            + "; ".join(self.monitor_result.errors)
        );
        visit [here ->:Feedback:->][?:Coordinator];
    }
}


walker:pub SubmitChange {
    has prompt: str;

    can submit with Root entry {
        request = ChangeRequest(prompt=self.prompt);
        root spawn request;
        disengage;
    }
}


walker:pub GraphSnapshot {
    has reports: list[dict] = [];

    can begin with Root entry {
        visit ensure_graph();
    }

    can collect with Coordinator entry {
        nodes: list[dict] = [{"id": here.name, "kind": "coordinator", "agentic": True}];
        for workspace in [here ->:Dispatch:->][?:Client] {
            nodes.append(workspace_snapshot(workspace));
        }
        for workspace in [here ->:Dispatch:->][?:Server] {
            nodes.append(workspace_snapshot(workspace));
        }
        for workspace in [here ->:Dispatch:->][?:Device] {
            nodes.append(workspace_snapshot(workspace));
        }
        deployments = [here ->:Dispatch:-> ->:ReadyToDeploy:->][?:Deployment];
        monitors = [here ->:Dispatch:-> ->:ReadyToDeploy:-> ->:Verify:->][?:Monitoring];
        if deployments {
            nodes.append({"id": deployments[0].name, "kind": "deployment", "agentic": False});
        }
        if monitors {
            nodes.append({"id": monitors[0].name, "kind": "monitoring", "agentic": False});
        }
        report {
            "initialized": True,
            "nodes": nodes,
            "edges": [
                {"source": "coordinator", "target": "client", "type": "Dispatch"},
                {"source": "coordinator", "target": "server", "type": "Dispatch"},
                {"source": "coordinator", "target": "device", "type": "Dispatch"},
                {"source": "client", "target": "deployment", "type": "ReadyToDeploy"},
                {"source": "server", "target": "deployment", "type": "ReadyToDeploy"},
                {"source": "device", "target": "deployment", "type": "ReadyToDeploy"},
                {"source": "deployment", "target": "monitoring", "type": "Verify"},
                {"source": "monitoring", "target": "coordinator", "type": "Feedback"}
            ]
        };
        disengage;
    }
}


walker:pub HardwareJobStatus {
    has job_id: str,
        after_sequence: int = 0,
        reports: list[dict] = [];

    can status with Root entry {
        report hardware_dispatch_snapshot(
            refresh_hardware_job(self.job_id, self.after_sequence)
        );
        disengage;
    }
}


walker:pub ResolveHardwareGate {
    has job_id: str,
        gate_id: str,
        accepted: bool,
        resolution_note: str = "",
        prompt: str = "",
        request_id: str = "",
        reports: list[dict] = [];

    can resolve with Root entry {
        result = resolve_hardware_gate(
            self.job_id,
            self.gate_id,
            self.accepted,
            self.resolution_note,
            "graph-gate:" + self.job_id + ":" + self.gate_id + ":" + str(self.accepted)
        );
        report hardware_dispatch_snapshot(result);
        if self.accepted and result.success and self.prompt and self.request_id {
            request = ChangeRequest(
                prompt=self.prompt,
                request_id=self.request_id,
                emit_reports=False
            );
            root spawn request;
        }
        disengage;
    }
}


def validate_plan(plan: ImpactPlan, workspaces: list[dict]) -> str {
    known = [workspace["name"] for workspace in workspaces];
    if not plan.selected {
        return "At least one workspace must be selected";
    }
    for name in plan.selected {
        if name not in known {
            return f"Unknown workspace: {name}";
        }
        if name not in plan.tasks {
            return f"Missing task for selected workspace: {name}";
        }
    }
    for name in known {
        if name not in plan.selected and name not in plan.skipped {
            return f"Missing skip reason for workspace: {name}";
        }
    }
    return "";
}


def workspace_context(workspace: Workspace) -> dict {
    return {
        "name": workspace.name,
        "path": workspace.path,
        "skill_path": workspace.skill_path,
        "spec_path": workspace.spec_path
    };
}


def workspace_snapshot(workspace: Workspace) -> dict {
    return {
        "id": workspace.name,
        "kind": workspace.kind.value,
        "agentic": True,
        "path": workspace.path
    };
}


def graph_complete(coordinator: Coordinator) -> bool {
    clients = [coordinator ->:Dispatch:->][?:Client];
    servers = [coordinator ->:Dispatch:->][?:Server];
    devices = [coordinator ->:Dispatch:->][?:Device];
    return bool(clients) and bool(servers) and bool(devices);
}


def ensure_graph() -> Coordinator {
    graph_root = root;
    try {
        existing = [graph_root ->:Project:->][?:Coordinator];
        if existing and graph_complete(existing[0]) {
            return existing[0];
        }
    } except Exception {
        # Development schema changes can leave stale anchors in a local store.
    }
    coordinator = graph_root +>:Project():+> Coordinator();
    client = Client(
        name="client",
        kind=WorkspaceKind.CLIENT,
        path="workspace/client",
        skill_path="workspace/client/client.md",
        spec_path="workspace/client/api-spec.md",
        allowed_commands=["jac", "npm", "pnpm", "npx"]
    );
    server = Server(
        name="server",
        kind=WorkspaceKind.SERVER,
        path="workspace/server",
        skill_path="workspace/server/server.md",
        spec_path="workspace/server/api-spec.md",
        allowed_commands=["jac"]
    );
    device = Device(
        name="device",
        kind=WorkspaceKind.DEVICE,
        path="workspace/device",
        skill_path="workspace/device/device.md",
        spec_path="workspace/device/api-spec.md",
        allowed_commands=["jac"]
    );
    deployment = Deployment();
    monitoring = Monitoring();

    coordinator +>:Dispatch():+> client;
    coordinator +>:Dispatch():+> server;
    coordinator +>:Dispatch():+> device;
    client +>:ReadyToDeploy():+> deployment;
    server +>:ReadyToDeploy():+> deployment;
    device +>:ReadyToDeploy():+> deployment;
    deployment +>:Verify():+> monitoring;
    monitoring +>:Feedback():+> coordinator;
    return coordinator;
}
