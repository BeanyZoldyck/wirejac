"""Focused tests for the Jac-native hardware service core."""

import from uuid { uuid4 }
import from hardware.contracts {
    ArtifactInput,
    ArtifactKind,
    ExecutionMode,
    GateInput,
    GateKind,
    GateStatus,
    HardwareRequest,
    JobStatus,
    PhaseContext,
    PhaseOutcome,
    PhaseResult,
    VerificationStatus
}
import from hardware.graph {
    HasDeployment,
    HasSimulation,
    HardwareJobNode,
    _add_deployment,
    _add_revision,
    _add_simulation_run,
    _create_job,
    _current_revision,
    _find_owned_job,
    _job_detail_to_view,
    _job_events,
    _job_gates,
    _open_gate
}
import from hardware.orchestration {
    _clear_phase_hooks,
    _execute_job,
    _register_phase_hook,
    _run_job,
    _transition_allowed
}


def _project_id(label: str) -> str {
    return f"{label}-{str(uuid4())}";
}


def _request(
    project_id: str,
    mode: ExecutionMode = ExecutionMode.PLAN
) -> HardwareRequest {
    return HardwareRequest(
        project_id=project_id,
        prompt="Build an ESP32 motion detector",
        allowed_inventory=["esp32", "mpu6050", "led", "button"],
        execution_mode=mode
    );
}


def _successful_phase(_context: PhaseContext) -> PhaseResult {
    return PhaseResult(
        outcome=PhaseOutcome.CONTINUE,
        message="Phase completed"
    );
}


def _artifact_phase(context: PhaseContext) -> PhaseResult {
    artifacts: list[ArtifactInput] = [];
    if context.status == JobStatus.GENERATING {
        artifacts.append(
            ArtifactInput(
                kind=ArtifactKind.HARDWARE_SPEC,
                name="hardware-spec.json",
                uri=f"artifact://{context.revision_id}/hardware-spec.json",
                sha256="abc123",
                media_type="application/json",
                size_bytes=42
            )
        );
    }
    return PhaseResult(
        outcome=PhaseOutcome.CONTINUE,
        message="Phase completed",
        artifacts=artifacts
    );
}


def _register_plan_hooks(
    generation_hook: Callable[[PhaseContext], PhaseResult]
) {
    _clear_phase_hooks();
    _register_phase_hook(JobStatus.PLANNING, _successful_phase);
    _register_phase_hook(JobStatus.VALIDATING, _successful_phase);
    _register_phase_hook(JobStatus.GENERATING, generation_hook);
}


test "job graph is reachable and projected as views" {
    job = _create_job(
        _request(_project_id("graph")),
        f"submit-{str(uuid4())}"
    );
    found = _find_owned_job(job.job_id);
    assert isinstance(found, HardwareJobNode);
    detail = _job_detail_to_view(job);
    assert detail.job.job_id == job.job_id;
    assert detail.job.status == JobStatus.QUEUED;
    assert len(detail.revisions) == 1;
    assert len(detail.events) == 1;
    assert detail.events[0].sequence == 1;
}


test "plan lifecycle records artifacts and succeeds" {
    _register_plan_hooks(_artifact_phase);
    job = _create_job(
        _request(_project_id("plan")),
        f"submit-{str(uuid4())}"
    );
    _execute_job(job);
    assert job.status == JobStatus.SUCCEEDED;
    assert job.progress_percent == 100;
    detail = _job_detail_to_view(job);
    assert len(detail.artifacts) == 1;
    assert detail.artifacts[0].kind == ArtifactKind.HARDWARE_SPEC;
    assert detail.artifacts[0].sha256 == "abc123";
    events = _job_events(job);
    assert len(events) >= 8;
    for index in range(1, len(events)) {
        assert events[index].sequence == events[index - 1].sequence + 1;
    }
    _clear_phase_hooks();
}


test "missing phase hook blocks without side effects" {
    _clear_phase_hooks();
    job = _create_job(
        _request(_project_id("blocked")),
        f"submit-{str(uuid4())}"
    );
    _execute_job(job);
    assert job.status == JobStatus.BLOCKED;
    assert job.error_code == "PHASE_HOOK_UNAVAILABLE";
    assert job.resume_status == JobStatus.PLANNING;
}


test "deploy lifecycle opens deterministic assembly gate" {
    _register_plan_hooks(_successful_phase);
    job = _create_job(
        _request(_project_id("deploy"), ExecutionMode.DEPLOY),
        f"submit-{str(uuid4())}"
    );
    _execute_job(job);
    assert job.status == JobStatus.ASSEMBLY_REQUIRED;
    gates = _job_gates(job);
    assert len(gates) == 1;
    assert gates[0].kind == GateKind.ASSEMBLY_CONFIRMATION;
    assert gates[0].revision_id == job.current_revision_id;
    assert gates[0].status == GateStatus.OPEN;
    assert gates[0].resume_status == JobStatus.SIMULATING;
    _clear_phase_hooks();
}


test "new revision rejects stale gates" {
    job = _create_job(
        _request(_project_id("stale-gate"), ExecutionMode.DEPLOY),
        f"submit-{str(uuid4())}"
    );
    stale = _open_gate(
        job,
        GateInput(
            kind=GateKind.ASSEMBLY_CONFIRMATION,
            title="Old assembly gate",
            instructions="Confirm old wiring",
            resume_status=JobStatus.SIMULATING
        )
    );
    old_revision_id = job.current_revision_id;
    _ = _add_revision(
        job,
        _request(job.project_id, ExecutionMode.DEPLOY),
        "Replace old wiring",
        f"revision-{str(uuid4())}"
    );
    assert stale.revision_id == old_revision_id;
    assert stale.status == GateStatus.REJECTED;
    assert stale.resolution_note == "Superseded by a newer revision";
    assert stale.revision_id != job.current_revision_id;
}


test "runner recovers state left by a dead process" {
    _register_plan_hooks(_successful_phase);
    job = _create_job(
        _request(_project_id("runner-recovery")),
        f"submit-{str(uuid4())}"
    );
    job.runner_active = True;
    job.runner_process_id = 99999999;
    job.runner_started_at = 1.0;
    assert _run_job(job.job_id);
    assert job.status == JobStatus.SUCCEEDED;
    assert not job.runner_active;
    assert job.runner_process_id == 0;
    _clear_phase_hooks();
}


test "simulation and deployment evidence are graph-native nodes" {
    job = _create_job(
        _request(_project_id("execution-nodes")),
        f"submit-{str(uuid4())}"
    );
    revision = _current_revision(job);
    assert revision is not None;
    _ = _add_simulation_run(
        revision,
        VerificationStatus.PASSED,
        "wokwi",
        "Simulation passed",
        1.0,
        2.0
    );
    _ = _add_deployment(
        revision,
        VerificationStatus.PASSED,
        "operation-1",
        "abc123",
        2.0,
        3.0
    );
    assert len([revision ->:HasSimulation:->]) == 1;
    assert len([revision ->:HasDeployment:->]) == 1;
}


test "transition table rejects unsafe phase jumps" {
    assert _transition_allowed(JobStatus.QUEUED, JobStatus.PLANNING);
    assert not _transition_allowed(JobStatus.QUEUED, JobStatus.DEPLOYING);
    assert _transition_allowed(JobStatus.DEPLOYING, JobStatus.ROLLED_BACK);
    assert not _transition_allowed(JobStatus.SUCCEEDED, JobStatus.DEPLOYING);
}
