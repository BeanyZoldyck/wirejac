"""Persistent OSP graph for hardware jobs and their evidence."""

import from time { time }
import from hardware.contracts {
    ArtifactInput,
    ArtifactKind,
    ArtifactView,
    DeviceView,
    EventKind,
    EventView,
    ExecutionMode,
    GateInput,
    GateKind,
    GateStatus,
    GateView,
    HardwareRequest,
    IssueSeverity,
    IssueView,
    JobDetailView,
    JobPhase,
    JobStatus,
    JobView,
    RevisionView,
    VerificationStatus,
    VerificationView
}

node HardwareProjectNode {
    has project_id: str,
        created_at: float,
        updated_at: float;
}

node HardwareJobNode {
    has job_id: str,
        idempotency_key: str,
        project_id: str,
        workspace_id: str,
        current_revision_id: str,
        request: HardwareRequest,
        created_at: float,
        updated_at: float;
    has current_revision: int = 1,
        status: JobStatus = JobStatus.QUEUED,
        phase: JobPhase = JobPhase.INTAKE,
        progress_percent: int = 0,
        cancel_requested: bool = False,
        cancel_reason: str = "",
        error_code: str = "",
        error_message: str = "",
        next_event_sequence: int = 1,
        runner_active: bool = False,
        runner_token: str = "",
        runner_process_id: int = 0,
        runner_started_at: float = 0.0,
        resume_status: JobStatus = JobStatus.QUEUED;
}

node HardwareRevisionNode {
    has revision_id: str,
        number: int,
        idempotency_key: str,
        reason: str,
        request: HardwareRequest,
        created_at: float;
}

node JobEventNode {
    has event_id: str,
        sequence: int,
        kind: EventKind,
        status: JobStatus,
        phase: JobPhase,
        message: str,
        created_at: float;
    has data: dict[str, str] = {};
}

node GateNode {
    has gate_id: str,
        revision_id: str,
        kind: GateKind,
        title: str,
        instructions: str,
        resume_status: JobStatus,
        opened_at: float;
    has status: GateStatus = GateStatus.OPEN,
        resolved_at: float = 0.0,
        accepted: bool = False,
        resolution_note: str = "",
        resolution_idempotency_key: str = "",
        metadata: dict[str, str] = {};
}

node ArtifactNode {
    has artifact_id: str,
        revision_id: str,
        kind: ArtifactKind,
        name: str,
        uri: str,
        sha256: str,
        media_type: str,
        size_bytes: int,
        created_at: float;
    has metadata: dict[str, str] = {};
}

node BoardNode {
    has profile_id: str,
        display_name: str,
        spec_hash: str,
        created_at: float;
}

node ComponentNode {
    has instance_id: str,
        profile_id: str,
        display_name: str,
        created_at: float;
}

node PinNode {
    has pin_id: str,
        label: str,
        gpio: int,
        voltage_domain: str,
        created_at: float;
}

node ElectricalNetNode {
    has net_id: str,
        name: str,
        role: str,
        voltage_domain: str,
        created_at: float;
}

node PlacementNode {
    has placement_id: str,
        part_instance_id: str,
        breadboard_hole: str,
        orientation: int,
        created_at: float;
}

node AssemblyStepNode {
    has step_id: str,
        number: int,
        title: str,
        instruction: str,
        visual_artifact_id: str,
        created_at: float;
}

node DeviceNode {
    has device_id: str,
        stable_port: str,
        chip_family: str,
        mac_address: str,
        flash_size_bytes: int,
        firmware_kind: str,
        connected: bool,
        last_seen_at: float;
}

node SimulationRunNode {
    has simulation_id: str,
        status: VerificationStatus,
        provider: str,
        summary: str,
        started_at: float,
        finished_at: float;
}

node DeploymentNode {
    has deployment_id: str,
        status: VerificationStatus,
        operation_id: str,
        firmware_sha256: str,
        started_at: float,
        finished_at: float,
        rollback_artifact_id: str;
}

node VerificationNode {
    has verification_id: str,
        status: VerificationStatus,
        summary: str,
        created_at: float;
    has checks: dict[str, str] = {},
        evidence_artifact_ids: list[str] = [];
}

node IssueNode {
    has issue_id: str,
        code: str,
        severity: IssueSeverity,
        message: str,
        location: str,
        created_at: float;
    has resolved: bool = False;
}

edge OwnsProject: Root --> HardwareProjectNode {}
edge OwnsDevice: Root --> DeviceNode {}
edge ContainsJob: HardwareProjectNode --> HardwareJobNode {}
edge HasRevision: HardwareJobNode --> HardwareRevisionNode {}
edge HasEvent: HardwareJobNode --> JobEventNode {}
edge HasGate: HardwareJobNode --> GateNode {}
edge Supersedes: HardwareRevisionNode --> HardwareRevisionNode {}
edge HasBoard: HardwareRevisionNode --> BoardNode {}
edge HasComponent: HardwareRevisionNode --> ComponentNode {}
edge HasPin: ComponentNode --> PinNode {}
edge HasNet: HardwareRevisionNode --> ElectricalNetNode {}
edge Connects: ElectricalNetNode --> ComponentNode {
    has pin_id: str = "";
}
edge HasPlacement: HardwareRevisionNode --> PlacementNode {}
edge Occupies: ComponentNode --> PlacementNode {}
edge HasAssemblyStep: HardwareRevisionNode --> AssemblyStepNode {}
edge Produces: HardwareRevisionNode --> ArtifactNode {}
edge Targets: HardwareRevisionNode --> DeviceNode {}
edge HasSimulation: HardwareRevisionNode --> SimulationRunNode {}
edge HasDeployment: HardwareRevisionNode --> DeploymentNode {}
edge DeployedTo: ArtifactNode --> DeviceNode {}
edge HasVerification: HardwareRevisionNode --> VerificationNode {}
edge VerifiedBy: DeploymentNode --> VerificationNode {}
edge HasIssue: HardwareRevisionNode --> IssueNode {}


def _now -> float {
    return time();
}


def _owned_projects -> list[HardwareProjectNode] {
    return [root ->:OwnsProject:->];
}


def _find_project(project_id: str) -> HardwareProjectNode | None {
    for project in _owned_projects() {
        if project.project_id == project_id {
            return project;
        }
    }
    return None;
}


def _get_or_create_project(project_id: str) -> HardwareProjectNode {
    existing = _find_project(project_id);
    if existing is not None {
        return existing;
    }
    created_at = _now();
    project = HardwareProjectNode(
        project_id=project_id,
        created_at=created_at,
        updated_at=created_at
    );
    root +>:OwnsProject:+> project;
    return project;
}


def _owned_jobs -> list[HardwareJobNode] {
    jobs: list[HardwareJobNode] = [];
    for project in _owned_projects() {
        jobs.extend([project ->:ContainsJob:->]);
    }
    return jobs;
}


def _find_owned_job(job_id: str) -> HardwareJobNode | None {
    for job in _owned_jobs() {
        if job.job_id == job_id {
            return job;
        }
    }
    return None;
}


def _find_job_by_idempotency(idempotency_key: str) -> HardwareJobNode | None {
    for job in _owned_jobs() {
        if job.idempotency_key == idempotency_key {
            return job;
        }
    }
    return None;
}


def _job_revisions(job: HardwareJobNode) -> list[HardwareRevisionNode] {
    return [job ->:HasRevision:->];
}


def _find_revision(
    job: HardwareJobNode,
    revision_id: str
) -> HardwareRevisionNode | None {
    for revision in _job_revisions(job) {
        if revision.revision_id == revision_id {
            return revision;
        }
    }
    return None;
}


def _current_revision(job: HardwareJobNode) -> HardwareRevisionNode | None {
    return _find_revision(job, job.current_revision_id);
}


def _find_revision_by_idempotency(
    job: HardwareJobNode,
    idempotency_key: str
) -> HardwareRevisionNode | None {
    for revision in _job_revisions(job) {
        if revision.idempotency_key == idempotency_key {
            return revision;
        }
    }
    return None;
}


def _create_job(
    request: HardwareRequest,
    idempotency_key: str
) -> HardwareJobNode {
    project = _get_or_create_project(request.project_id);
    created_at = _now();
    job = HardwareJobNode(
        job_id="",
        idempotency_key=idempotency_key,
        project_id=request.project_id,
        workspace_id="",
        current_revision_id="",
        request=request,
        created_at=created_at,
        updated_at=created_at
    );
    project +>:ContainsJob:+> job;
    job.job_id = jid(job);
    job.workspace_id = f"jobs/{job.job_id}";
    revision = HardwareRevisionNode(
        revision_id="",
        number=1,
        idempotency_key=idempotency_key,
        reason="Initial coordinator request",
        request=request,
        created_at=created_at
    );
    job +>:HasRevision:+> revision;
    revision.revision_id = jid(revision);
    job.current_revision_id = revision.revision_id;
    _add_event(
        job,
        EventKind.JOB_CREATED,
        "Hardware job accepted",
        {"revision_id": revision.revision_id}
    );
    return job;
}


def _add_revision(
    job: HardwareJobNode,
    request: HardwareRequest,
    reason: str,
    idempotency_key: str
) -> HardwareRevisionNode {
    previous = _current_revision(job);
    revision = HardwareRevisionNode(
        revision_id="",
        number=job.current_revision + 1,
        idempotency_key=idempotency_key,
        reason=reason,
        request=request,
        created_at=_now()
    );
    job +>:HasRevision:+> revision;
    revision.revision_id = jid(revision);
    if previous is not None {
        for gate in _job_gates(job) {
            if (
                gate.revision_id == previous.revision_id
                and gate.status == GateStatus.OPEN
            ) {
                gate.status = GateStatus.REJECTED;
                gate.resolved_at = _now();
                gate.accepted = False;
                gate.resolution_note = "Superseded by a newer revision";
            }
        }
        revision +>:Supersedes:+> previous;
    }
    job.current_revision += 1;
    job.current_revision_id = revision.revision_id;
    job.request = request;
    job.updated_at = _now();
    _add_event(
        job,
        EventKind.REVISION_CREATED,
        f"Revision {revision.number} accepted",
        {"revision_id": revision.revision_id}
    );
    return revision;
}


def _job_events(job: HardwareJobNode) -> list[JobEventNode] {
    events = [job ->:HasEvent:->];
    events.sort(key=lambda (event: JobEventNode) { event.sequence; });
    return events;
}


def _add_event(
    job: HardwareJobNode,
    kind: EventKind,
    message: str,
    data: dict[str, str] | None = None
) -> JobEventNode {
    event_data = data or {};
    event = JobEventNode(
        event_id="",
        sequence=job.next_event_sequence,
        kind=kind,
        status=job.status,
        phase=job.phase,
        message=message,
        created_at=_now(),
        data=event_data
    );
    job +>:HasEvent:+> event;
    event.event_id = jid(event);
    job.next_event_sequence += 1;
    job.updated_at = event.created_at;
    return event;
}


def _job_gates(job: HardwareJobNode) -> list[GateNode] {
    return [job ->:HasGate:->];
}


def _find_gate(job: HardwareJobNode, gate_id: str) -> GateNode | None {
    for gate in _job_gates(job) {
        if (
            gate.gate_id == gate_id
            and gate.revision_id == job.current_revision_id
        ) {
            return gate;
        }
    }
    return None;
}


def _open_gate(job: HardwareJobNode, gate_input: GateInput) -> GateNode {
    gate = GateNode(
        gate_id="",
        revision_id=job.current_revision_id,
        kind=gate_input.kind,
        title=gate_input.title,
        instructions=gate_input.instructions,
        resume_status=gate_input.resume_status,
        opened_at=_now(),
        metadata=gate_input.metadata
    );
    job +>:HasGate:+> gate;
    gate.gate_id = jid(gate);
    _add_event(
        job,
        EventKind.GATE_OPENED,
        gate.title,
        {"gate_id": gate.gate_id, "kind": str(gate.kind)}
    );
    return gate;
}


def _revision_artifacts(
    revision: HardwareRevisionNode
) -> list[ArtifactNode] {
    return [revision ->:Produces:->];
}


def _add_artifact(
    revision: HardwareRevisionNode,
    artifact_input: ArtifactInput
) -> ArtifactNode {
    artifact = ArtifactNode(
        artifact_id="",
        revision_id=revision.revision_id,
        kind=artifact_input.kind,
        name=artifact_input.name,
        uri=artifact_input.uri,
        sha256=artifact_input.sha256,
        media_type=artifact_input.media_type,
        size_bytes=artifact_input.size_bytes,
        created_at=_now(),
        metadata=artifact_input.metadata
    );
    revision +>:Produces:+> artifact;
    artifact.artifact_id = jid(artifact);
    return artifact;
}


def _revision_issues(revision: HardwareRevisionNode) -> list[IssueNode] {
    return [revision ->:HasIssue:->];
}


def _add_issue(
    revision: HardwareRevisionNode,
    code: str,
    severity: IssueSeverity,
    message: str,
    location: str = ""
) -> IssueNode {
    issue = IssueNode(
        issue_id="",
        code=code,
        severity=severity,
        message=message,
        location=location,
        created_at=_now()
    );
    revision +>:HasIssue:+> issue;
    issue.issue_id = jid(issue);
    return issue;
}


def _revision_verifications(
    revision: HardwareRevisionNode
) -> list[VerificationNode] {
    return [revision ->:HasVerification:->];
}


def _add_verification(
    revision: HardwareRevisionNode,
    status: VerificationStatus,
    summary: str,
    checks: dict[str, str] | None = None,
    evidence_artifact_ids: list[str] | None = None
) -> VerificationNode {
    verification_checks = checks or {};
    verification_evidence = evidence_artifact_ids or [];
    verification = VerificationNode(
        verification_id="",
        status=status,
        summary=summary,
        created_at=_now(),
        checks=verification_checks,
        evidence_artifact_ids=verification_evidence
    );
    revision +>:HasVerification:+> verification;
    verification.verification_id = jid(verification);
    return verification;
}


def _add_simulation_run(
    revision: HardwareRevisionNode,
    status: VerificationStatus,
    provider: str,
    summary: str,
    started_at: float,
    finished_at: float
) -> SimulationRunNode {
    simulation = SimulationRunNode(
        simulation_id="",
        status=status,
        provider=provider,
        summary=summary,
        started_at=started_at,
        finished_at=finished_at
    );
    revision +>:HasSimulation:+> simulation;
    simulation.simulation_id = jid(simulation);
    return simulation;
}


def _add_deployment(
    revision: HardwareRevisionNode,
    status: VerificationStatus,
    operation_id: str,
    firmware_sha256: str,
    started_at: float,
    finished_at: float,
    rollback_artifact_id: str = ""
) -> DeploymentNode {
    deployment = DeploymentNode(
        deployment_id="",
        status=status,
        operation_id=operation_id,
        firmware_sha256=firmware_sha256,
        started_at=started_at,
        finished_at=finished_at,
        rollback_artifact_id=rollback_artifact_id
    );
    revision +>:HasDeployment:+> deployment;
    deployment.deployment_id = jid(deployment);
    return deployment;
}


def _owned_devices -> list[DeviceNode] {
    return [root ->:OwnsDevice:->];
}


def _upsert_device(view: DeviceView) -> DeviceNode {
    for device in _owned_devices() {
        if device.device_id == view.device_id {
            device.stable_port = view.stable_port;
            device.chip_family = view.chip_family;
            device.mac_address = view.mac_address;
            device.flash_size_bytes = view.flash_size_bytes;
            device.firmware_kind = view.firmware_kind;
            device.connected = view.connected;
            device.last_seen_at = view.last_seen_at;
            return device;
        }
    }
    device = DeviceNode(
        device_id=view.device_id,
        stable_port=view.stable_port,
        chip_family=view.chip_family,
        mac_address=view.mac_address,
        flash_size_bytes=view.flash_size_bytes,
        firmware_kind=view.firmware_kind,
        connected=view.connected,
        last_seen_at=view.last_seen_at
    );
    root +>:OwnsDevice:+> device;
    return device;
}


def _job_to_view(job: HardwareJobNode) -> JobView {
    return JobView(
        job_id=job.job_id,
        project_id=job.project_id,
        revision_id=job.current_revision_id,
        revision=job.current_revision,
        prompt=job.request.prompt,
        board_profile=job.request.board_profile,
        execution_mode=job.request.execution_mode,
        status=job.status,
        phase=job.phase,
        progress_percent=job.progress_percent,
        cancel_requested=job.cancel_requested,
        created_at=job.created_at,
        updated_at=job.updated_at,
        error_code=job.error_code,
        error_message=job.error_message
    );
}


def _revision_to_view(revision: HardwareRevisionNode) -> RevisionView {
    return RevisionView(
        revision_id=revision.revision_id,
        number=revision.number,
        reason=revision.reason,
        created_at=revision.created_at,
        request=revision.request
    );
}


def _gate_to_view(gate: GateNode) -> GateView {
    return GateView(
        gate_id=gate.gate_id,
        revision_id=gate.revision_id,
        kind=gate.kind,
        status=gate.status,
        title=gate.title,
        instructions=gate.instructions,
        resume_status=gate.resume_status,
        opened_at=gate.opened_at,
        resolved_at=gate.resolved_at,
        accepted=gate.accepted,
        resolution_note=gate.resolution_note,
        metadata=gate.metadata
    );
}


def _event_to_view(event: JobEventNode) -> EventView {
    return EventView(
        event_id=event.event_id,
        sequence=event.sequence,
        kind=event.kind,
        status=event.status,
        phase=event.phase,
        message=event.message,
        created_at=event.created_at,
        data=event.data
    );
}


def _artifact_to_view(artifact: ArtifactNode) -> ArtifactView {
    return ArtifactView(
        artifact_id=artifact.artifact_id,
        revision_id=artifact.revision_id,
        kind=artifact.kind,
        name=artifact.name,
        uri=artifact.uri,
        sha256=artifact.sha256,
        media_type=artifact.media_type,
        size_bytes=artifact.size_bytes,
        created_at=artifact.created_at,
        metadata=artifact.metadata
    );
}


def _verification_to_view(
    verification: VerificationNode
) -> VerificationView {
    return VerificationView(
        verification_id=verification.verification_id,
        status=verification.status,
        summary=verification.summary,
        checks=verification.checks,
        evidence_artifact_ids=verification.evidence_artifact_ids,
        created_at=verification.created_at
    );
}


def _device_to_view(device: DeviceNode) -> DeviceView {
    return DeviceView(
        device_id=device.device_id,
        stable_port=device.stable_port,
        chip_family=device.chip_family,
        mac_address=device.mac_address,
        flash_size_bytes=device.flash_size_bytes,
        firmware_kind=device.firmware_kind,
        connected=device.connected,
        last_seen_at=device.last_seen_at
    );
}


def _issue_to_view(issue: IssueNode) -> IssueView {
    return IssueView(
        issue_id=issue.issue_id,
        code=issue.code,
        severity=issue.severity,
        message=issue.message,
        location=issue.location,
        resolved=issue.resolved,
        created_at=issue.created_at
    );
}


def _job_detail_to_view(job: HardwareJobNode) -> JobDetailView {
    revisions = _job_revisions(job);
    revision_views = [_revision_to_view(revision) for revision in revisions];
    gate_views = [_gate_to_view(gate) for gate in _job_gates(job)];
    event_views = [_event_to_view(event) for event in _job_events(job)];
    current = _current_revision(job);
    artifact_views: list[ArtifactView] = [];
    issue_views: list[IssueView] = [];
    latest_verification: VerificationView | None = None;
    if current is not None {
        artifact_views = [
            _artifact_to_view(artifact)
            for artifact in _revision_artifacts(current)
        ];
        issue_views = [
            _issue_to_view(issue)
            for issue in _revision_issues(current)
        ];
        verifications = _revision_verifications(current);
        if verifications {
            latest_verification = _verification_to_view(verifications[-1]);
        }
    }
    return JobDetailView(
        job=_job_to_view(job),
        revisions=revision_views,
        gates=gate_views,
        artifacts=artifact_views,
        events=event_views,
        issues=issue_views,
        latest_verification=latest_verification
    );
}
