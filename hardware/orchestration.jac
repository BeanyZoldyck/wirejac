"""Lifecycle engine and phase-hook boundary for hardware work."""

import os;
import uuid;
import from concurrent.futures { Future }
import from time { time }
import from hardware.contracts {
    ArtifactView,
    CapabilityView,
    DeviceView,
    EventKind,
    ExecutionMode,
    GateInput,
    GateKind,
    JobPhase,
    JobStatus,
    PhaseContext,
    PhaseOutcome,
    PhaseResult
}
import from hardware.graph {
    HardwareJobNode,
    _add_artifact,
    _add_event,
    _current_revision,
    _device_to_view,
    _open_gate,
    _owned_devices,
    _upsert_device
}

glob _phase_hooks: dict[
    JobStatus,
    Callable[[PhaseContext], PhaseResult]
] = {};
glob _device_discovery_hook: Callable[[], list[DeviceView]] | None = None;
glob _artifact_read_hook: Callable[[ArtifactView], bytes] | None = None;
glob _external_capabilities_hook: Callable[[], list[CapabilityView]] | None = None;


def _register_phase_hook(
    status: JobStatus,
    hook: Callable[[PhaseContext], PhaseResult]
) {
    if status not in [
        JobStatus.PLANNING,
        JobStatus.VALIDATING,
        JobStatus.GENERATING,
        JobStatus.SIMULATING,
        JobStatus.PROVISIONING,
        JobStatus.DEPLOYING,
        JobStatus.VERIFYING
    ] {
        raise ValueError(f"{status} is not an executable phase");
    }
    _phase_hooks[status] = hook;
}


def _clear_phase_hooks {
    _phase_hooks.clear();
}


def _register_device_discovery_hook(
    hook: Callable[[], list[DeviceView]]
) {
    _device_discovery_hook = hook;
}


def _clear_device_discovery_hook {
    _device_discovery_hook = None;
}


def _register_artifact_read_hook(
    hook: Callable[[ArtifactView], bytes]
) {
    _artifact_read_hook = hook;
}


def _clear_artifact_read_hook {
    _artifact_read_hook = None;
}


def _register_capabilities_hook(
    hook: Callable[[], list[CapabilityView]]
) {
    _external_capabilities_hook = hook;
}


def _clear_capabilities_hook {
    _external_capabilities_hook = None;
}


def _read_artifact(view: ArtifactView) -> bytes {
    if _artifact_read_hook is None {
        raise RuntimeError("Artifact content reader is not configured");
    }
    return _artifact_read_hook(view);
}


def _capability_views -> list[CapabilityView] {
    capabilities: list[CapabilityView] = [
        CapabilityView(
            name=f"phase:{status}",
            available=status in _phase_hooks,
            detail=(
                "registered"
                if status in _phase_hooks
                else "phase hook unavailable"
            )
        )
        for status in [
            JobStatus.PLANNING,
            JobStatus.VALIDATING,
            JobStatus.GENERATING,
            JobStatus.SIMULATING,
            JobStatus.PROVISIONING,
            JobStatus.DEPLOYING,
            JobStatus.VERIFYING
        ]
    ];
    capabilities.append(
        CapabilityView(
            name="device_discovery",
            available=_device_discovery_hook is not None,
            detail=(
                "registered"
                if _device_discovery_hook is not None
                else "device discovery hook unavailable"
            )
        )
    );
    capabilities.append(
        CapabilityView(
            name="artifact_content",
            available=_artifact_read_hook is not None,
            detail=(
                "registered"
                if _artifact_read_hook is not None
                else "artifact content reader unavailable"
            )
        )
    );
    if _external_capabilities_hook is not None {
        capabilities.extend(_external_capabilities_hook());
    }
    return capabilities;
}


def _is_terminal(status: JobStatus) -> bool {
    return status in [
        JobStatus.SUCCEEDED,
        JobStatus.FAILED,
        JobStatus.CANCELLED,
        JobStatus.INTERRUPTED,
        JobStatus.ROLLED_BACK
    ];
}


def _phase_for_status(status: JobStatus) -> JobPhase {
    if status == JobStatus.QUEUED {
        return JobPhase.INTAKE;
    }
    if status == JobStatus.PLANNING {
        return JobPhase.PLANNING;
    }
    if status == JobStatus.VALIDATING {
        return JobPhase.VALIDATION;
    }
    if status == JobStatus.GENERATING {
        return JobPhase.GENERATION;
    }
    if status == JobStatus.ASSEMBLY_REQUIRED {
        return JobPhase.ASSEMBLY;
    }
    if status == JobStatus.SIMULATING {
        return JobPhase.SIMULATION;
    }
    if status == JobStatus.PROVISIONING {
        return JobPhase.PROVISIONING;
    }
    if status == JobStatus.DEPLOYING {
        return JobPhase.DEPLOYMENT;
    }
    if status == JobStatus.VERIFYING {
        return JobPhase.VERIFICATION;
    }
    return JobPhase.COMPLETE;
}


def _progress_for_status(status: JobStatus) -> int {
    if status == JobStatus.QUEUED {
        return 0;
    }
    if status == JobStatus.PLANNING {
        return 10;
    }
    if status == JobStatus.VALIDATING {
        return 25;
    }
    if status == JobStatus.GENERATING {
        return 40;
    }
    if status == JobStatus.ASSEMBLY_REQUIRED {
        return 55;
    }
    if status == JobStatus.SIMULATING {
        return 65;
    }
    if status == JobStatus.PROVISIONING {
        return 75;
    }
    if status == JobStatus.DEPLOYING {
        return 85;
    }
    if status == JobStatus.VERIFYING {
        return 95;
    }
    if status == JobStatus.SUCCEEDED {
        return 100;
    }
    return 0;
}


def _transition_allowed(
    current: JobStatus,
    target: JobStatus
) -> bool {
    if current == target {
        return True;
    }
    if (
        target == JobStatus.QUEUED
        and current == JobStatus.ASSEMBLY_REQUIRED
    ) {
        return True;
    }
    if target in [
        JobStatus.BLOCKED,
        JobStatus.FAILED,
        JobStatus.CANCELLED,
        JobStatus.INTERRUPTED
    ] and not _is_terminal(current) {
        return True;
    }
    if current == JobStatus.QUEUED {
        return target == JobStatus.PLANNING;
    }
    if current == JobStatus.PLANNING {
        return target == JobStatus.VALIDATING;
    }
    if current == JobStatus.VALIDATING {
        return target == JobStatus.GENERATING;
    }
    if current == JobStatus.GENERATING {
        return target in [
            JobStatus.ASSEMBLY_REQUIRED,
            JobStatus.SIMULATING,
            JobStatus.SUCCEEDED
        ];
    }
    if current == JobStatus.ASSEMBLY_REQUIRED {
        return target in [
            JobStatus.SIMULATING,
            JobStatus.PROVISIONING,
            JobStatus.DEPLOYING
        ];
    }
    if current == JobStatus.SIMULATING {
        return target in [
            JobStatus.PROVISIONING,
            JobStatus.DEPLOYING,
            JobStatus.VERIFYING,
            JobStatus.SUCCEEDED
        ];
    }
    if current == JobStatus.PROVISIONING {
        return target == JobStatus.DEPLOYING;
    }
    if current == JobStatus.DEPLOYING {
        return target in [
            JobStatus.VERIFYING,
            JobStatus.ROLLED_BACK
        ];
    }
    if current == JobStatus.VERIFYING {
        return target in [
            JobStatus.SUCCEEDED,
            JobStatus.ROLLED_BACK
        ];
    }
    if current == JobStatus.BLOCKED {
        return target in [
            JobStatus.QUEUED,
            JobStatus.PLANNING,
            JobStatus.VALIDATING,
            JobStatus.GENERATING,
            JobStatus.SIMULATING,
            JobStatus.PROVISIONING,
            JobStatus.DEPLOYING,
            JobStatus.VERIFYING
        ];
    }
    if current in [
        JobStatus.SUCCEEDED,
        JobStatus.FAILED,
        JobStatus.CANCELLED,
        JobStatus.INTERRUPTED,
        JobStatus.ROLLED_BACK
    ] {
        return target == JobStatus.QUEUED;
    }
    return False;
}


def _set_status(
    job: HardwareJobNode,
    status: JobStatus,
    message: str,
    event_kind: EventKind = EventKind.STATUS_CHANGED
) {
    if not _transition_allowed(job.status, status) {
        raise ValueError(
            f"Invalid hardware job transition: {job.status} -> {status}"
        );
    }
    if status == JobStatus.BLOCKED and job.status != JobStatus.BLOCKED {
        job.resume_status = job.status;
    }
    job.status = status;
    job.phase = _phase_for_status(status);
    next_progress = _progress_for_status(status);
    if next_progress > job.progress_percent or status == JobStatus.QUEUED {
        job.progress_percent = next_progress;
    }
    _add_event(job, event_kind, message);
}


def _reset_for_revision(job: HardwareJobNode) {
    if not _transition_allowed(job.status, JobStatus.QUEUED) {
        raise ValueError("A revision cannot replace an active hardware job");
    }
    job.status = JobStatus.QUEUED;
    job.phase = JobPhase.INTAKE;
    job.progress_percent = 0;
    job.cancel_requested = False;
    job.cancel_reason = "";
    job.error_code = "";
    job.error_message = "";
    job.runner_active = False;
    job.runner_token = "";
    job.runner_process_id = 0;
    job.runner_started_at = 0.0;
    job.resume_status = JobStatus.QUEUED;
    _add_event(job, EventKind.STATUS_CHANGED, "Revision queued");
}


def _next_status(job: HardwareJobNode) -> JobStatus | None {
    if job.status == JobStatus.PLANNING {
        return JobStatus.VALIDATING;
    }
    if job.status == JobStatus.VALIDATING {
        return JobStatus.GENERATING;
    }
    if job.status == JobStatus.GENERATING {
        if job.request.execution_mode == ExecutionMode.PLAN {
            return JobStatus.SUCCEEDED;
        }
        if job.request.execution_mode == ExecutionMode.SIMULATE {
            return JobStatus.SIMULATING;
        }
        return JobStatus.ASSEMBLY_REQUIRED;
    }
    if job.status == JobStatus.ASSEMBLY_REQUIRED {
        return JobStatus.SIMULATING;
    }
    if job.status == JobStatus.SIMULATING {
        if job.request.execution_mode == ExecutionMode.SIMULATE {
            return JobStatus.VERIFYING;
        }
        return JobStatus.PROVISIONING;
    }
    if job.status == JobStatus.PROVISIONING {
        return JobStatus.DEPLOYING;
    }
    if job.status == JobStatus.DEPLOYING {
        return JobStatus.VERIFYING;
    }
    if job.status == JobStatus.VERIFYING {
        return JobStatus.SUCCEEDED;
    }
    return None;
}


def _phase_context(job: HardwareJobNode) -> PhaseContext {
    revision = _current_revision(job);
    if revision is None {
        raise ValueError("Hardware job has no current revision");
    }
    return PhaseContext(
        operation_id=f"{job.job_id}:{revision.revision_id}:{job.status}",
        job_id=job.job_id,
        revision_id=revision.revision_id,
        workspace_id=job.workspace_id,
        status=job.status,
        request=revision.request
    );
}


def _missing_hook_result(status: JobStatus) -> PhaseResult {
    return PhaseResult(
        outcome=PhaseOutcome.BLOCKED,
        message=f"No phase hook registered for {status}",
        error_code="PHASE_HOOK_UNAVAILABLE"
    );
}


def _invoke_phase(job: HardwareJobNode) -> PhaseResult {
    hook = _phase_hooks.get(job.status);
    if hook is None {
        return _missing_hook_result(job.status);
    }
    context = _phase_context(job);
    return hook(context);
}


def _record_phase_output(job: HardwareJobNode, result: PhaseResult) {
    revision = _current_revision(job);
    if revision is None {
        raise ValueError("Hardware job has no current revision");
    }
    for artifact_input in result.artifacts {
        artifact = _add_artifact(revision, artifact_input);
        _add_event(
            job,
            EventKind.ARTIFACT_READY,
            f"Artifact ready: {artifact.name}",
            {
                "artifact_id": artifact.artifact_id,
                "kind": str(artifact.kind),
                "sha256": artifact.sha256
            }
        );
    }
    if result.message {
        _add_event(job, EventKind.PROGRESS, result.message, result.data);
    }
}


def _wait_on_gate(job: HardwareJobNode, gate_input: GateInput) {
    target = (
        JobStatus.ASSEMBLY_REQUIRED
        if gate_input.kind == GateKind.ASSEMBLY_CONFIRMATION
        else JobStatus.BLOCKED
    );
    _set_status(job, target, gate_input.title);
    _open_gate(job, gate_input);
}


def _default_assembly_gate -> GateInput {
    return GateInput(
        kind=GateKind.ASSEMBLY_CONFIRMATION,
        title="Breadboard assembly confirmation required",
        instructions=(
            "Complete the generated assembly steps with USB power disconnected, "
            "then confirm the wiring before simulation and deployment continue."
        ),
        resume_status=JobStatus.SIMULATING
    );
}


def _apply_phase_result(job: HardwareJobNode, result: PhaseResult) -> bool {
    _record_phase_output(job, result);
    if result.outcome == PhaseOutcome.FAILED {
        job.error_code = result.error_code or "PHASE_FAILED";
        job.error_message = result.message;
        _set_status(job, JobStatus.FAILED, result.message, EventKind.ERROR);
        return False;
    }
    if result.outcome == PhaseOutcome.BLOCKED {
        job.error_code = result.error_code or "PHASE_BLOCKED";
        job.error_message = result.message;
        _set_status(job, JobStatus.BLOCKED, result.message, EventKind.WARNING);
        return False;
    }
    if result.outcome == PhaseOutcome.WAITING {
        if result.gate is None {
            job.error_code = "INVALID_PHASE_RESULT";
            job.error_message = "Waiting phase result did not provide a gate";
            _set_status(
                job,
                JobStatus.FAILED,
                job.error_message,
                EventKind.ERROR
            );
            return False;
        }
        _wait_on_gate(job, result.gate);
        return False;
    }
    if result.gate is not None {
        _wait_on_gate(job, result.gate);
        return False;
    }
    if result.outcome == PhaseOutcome.COMPLETE {
        _set_status(
            job,
            JobStatus.SUCCEEDED,
            result.message or "Hardware job completed",
            EventKind.COMPLETED
        );
        return False;
    }
    next_status = result.next_status or _next_status(job);
    if next_status is None {
        _set_status(
            job,
            JobStatus.SUCCEEDED,
            "Hardware job completed",
            EventKind.COMPLETED
        );
        return False;
    }
    if next_status == JobStatus.ASSEMBLY_REQUIRED {
        _wait_on_gate(job, _default_assembly_gate());
        return False;
    }
    if next_status == job.status {
        job.error_code = "PHASE_DID_NOT_ADVANCE";
        job.error_message = f"Phase hook left job at {job.status}";
        _set_status(
            job,
            JobStatus.FAILED,
            job.error_message,
            EventKind.ERROR
        );
        return False;
    }
    _set_status(job, next_status, f"Entering {next_status}");
    return True;
}


def _execute_job(job: HardwareJobNode) {
    if job.status == JobStatus.QUEUED {
        _set_status(job, JobStatus.PLANNING, "Hardware planning started");
    }
    steps = 0;
    while not _is_terminal(job.status) and job.status != JobStatus.BLOCKED {
        if job.cancel_requested {
            _set_status(
                job,
                JobStatus.CANCELLED,
                job.cancel_reason or "Hardware job cancelled"
            );
            break;
        }
        if job.status == JobStatus.ASSEMBLY_REQUIRED {
            break;
        }
        if steps >= 16 {
            job.error_code = "PHASE_LIMIT_EXCEEDED";
            job.error_message = "Hardware job exceeded the phase limit";
            _set_status(
                job,
                JobStatus.FAILED,
                job.error_message,
                EventKind.ERROR
            );
            break;
        }
        # Persist the operation id and phase before a hook performs side effects.
        commit();
        try {
            result = _invoke_phase(job);
        } except Exception as error {
            result = PhaseResult(
                outcome=PhaseOutcome.FAILED,
                message=str(error),
                error_code="PHASE_EXCEPTION"
            );
        }
        should_continue = _apply_phase_result(job, result);
        commit();
        steps += 1;
        if not should_continue {
            break;
        }
    }
}


def _run_job(job_id: str) -> bool {
    target = jobj(job_id);
    if not isinstance(target, HardwareJobNode) {
        return False;
    }
    current_process = os.getpid();
    if target.runner_active {
        same_process = target.runner_process_id == current_process;
        process_alive = False;
        if target.runner_process_id > 0 {
            try {
                os.kill(target.runner_process_id, 0);
                process_alive = True;
            } except ProcessLookupError {
                process_alive = False;
            } except PermissionError {
                process_alive = True;
            }
        }
        if same_process or (
            process_alive and time() - target.runner_started_at < 1800.0
        ) {
            return False;
        }
        _add_event(
            target,
            EventKind.WARNING,
            "Recovered a stale hardware runner after process interruption"
        );
    }
    target.runner_active = True;
    target.runner_token = str(uuid.uuid4());
    target.runner_process_id = current_process;
    target.runner_started_at = time();
    commit();
    try {
        _execute_job(target);
    } except Exception as error {
        target.error_code = "RUNNER_EXCEPTION";
        target.error_message = str(error);
        if not _is_terminal(target.status) {
            _set_status(
                target,
                JobStatus.FAILED,
                target.error_message,
                EventKind.ERROR
            );
        }
    } finally {
        target.runner_active = False;
        target.runner_token = "";
        target.runner_process_id = 0;
        target.runner_started_at = 0.0;
        commit();
    }
    return True;
}


def _launch_job(job_id: str) -> Future[bool] {
    return (flow _run_job(job_id)) as Future[bool];  # jac:ignore[W1051]
}


def _recover_job(job: HardwareJobNode) {
    if (
        not _is_terminal(job.status)
        and job.status not in [
            JobStatus.BLOCKED,
            JobStatus.ASSEMBLY_REQUIRED
        ]
    ) {
        _ = _launch_job(job.job_id);
    }
}


def _discover_device_views -> list[DeviceView] {
    if _device_discovery_hook is not None {
        discovered = _device_discovery_hook();
        for view in discovered {
            _upsert_device(view);
        }
    }
    return [_device_to_view(device) for device in _owned_devices()];
}
