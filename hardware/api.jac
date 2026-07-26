"""Authenticated coordinator-facing hardware service API."""

import from time { sleep, time }
import from typing { Generator }
import from hashlib { sha256 }
import from hardware.contracts {
    ArtifactContentView,
    ArtifactView,
    CapabilityView,
    DeviceView,
    EventKind,
    EventView,
    GateStatus,
    HardwareRequest,
    JobDetailView,
    JobStatus,
    JobView,
    MutationResult,
    SubmitJobResponse
}
import from hardware.graph {
    HardwareJobNode,
    _add_event,
    _add_revision,
    _artifact_to_view,
    _create_job,
    _current_revision,
    _event_to_view,
    _find_gate,
    _find_job_by_idempotency,
    _find_owned_job,
    _find_revision,
    _find_revision_by_idempotency,
    _job_detail_to_view,
    _job_events,
    _job_gates,
    _job_revisions,
    _job_to_view,
    _owned_jobs,
    _revision_artifacts
}
import from hardware.orchestration {
    _capability_views,
    _discover_device_views,
    _is_terminal,
    _launch_job,
    _read_artifact,
    _recover_job,
    _reset_for_revision,
    _set_status
}


def _validate_idempotency_key(idempotency_key: str) {
    if not idempotency_key.strip() {
        raise ValueError("idempotency_key is required");
    }
    if len(idempotency_key) > 200 {
        raise ValueError("idempotency_key must be 200 characters or fewer");
    }
}


def _validate_secret_refs(request: HardwareRequest) {
    for name in request.secret_refs {
        reference = request.secret_refs[name];
        if not name.strip() or not reference.strip() {
            raise ValueError("Secret reference names and values cannot be empty");
        }
        if not (
            reference.startswith("env:")
            or reference.startswith("keyring:")
            or reference.startswith("vault:")
        ) {
            raise ValueError(
                f"Secret '{name}' must be an env:, keyring:, or vault: reference"
            );
        }
    }
    if (
        request.integration is not None
        and request.integration.backend_secret_ref
        and not (
            request.integration.backend_secret_ref.startswith("env:")
            or request.integration.backend_secret_ref.startswith("keyring:")
            or request.integration.backend_secret_ref.startswith("vault:")
        )
    ) {
        raise ValueError(
            "integration.backend_secret_ref must be an env:, keyring:, "
            "or vault: reference"
        );
    }
}


def _validate_request(request: HardwareRequest) {
    if not request.project_id.strip() {
        raise ValueError("request.project_id is required");
    }
    if not request.prompt.strip() {
        raise ValueError("request.prompt is required");
    }
    if not request.board_profile.strip() {
        raise ValueError("request.board_profile is required");
    }
    _validate_secret_refs(request);
}


def _may_revise(status: JobStatus) -> bool {
    return status in [
        JobStatus.ASSEMBLY_REQUIRED,
        JobStatus.BLOCKED,
        JobStatus.SUCCEEDED,
        JobStatus.FAILED,
        JobStatus.CANCELLED,
        JobStatus.INTERRUPTED,
        JobStatus.ROLLED_BACK
    ];
}


def _submit_job(
    request: HardwareRequest,
    idempotency_key: str
) -> SubmitJobResponse {
    _validate_request(request);
    _validate_idempotency_key(idempotency_key);
    existing = _find_job_by_idempotency(idempotency_key);
    if existing is not None {
        return SubmitJobResponse(
            job=_job_to_view(existing),
            created=False,
            idempotent_replay=True
        );
    }
    job = _create_job(request, idempotency_key);
    commit();
    response = SubmitJobResponse(
        job=_job_to_view(job),
        created=True,
        idempotent_replay=False
    );
    _ = _launch_job(job.job_id);
    return response;
}


def _revise_job(
    job_id: str,
    request: HardwareRequest,
    reason: str,
    idempotency_key: str
) -> MutationResult {
    _validate_request(request);
    _validate_idempotency_key(idempotency_key);
    job = _find_owned_job(job_id);
    if job is None {
        return MutationResult(
            accepted=False,
            idempotent_replay=False,
            message="Hardware job not found",
            job=None
        );
    }
    existing = _find_revision_by_idempotency(job, idempotency_key);
    if existing is not None {
        return MutationResult(
            accepted=True,
            idempotent_replay=True,
            message=f"Revision {existing.number} already exists",
            job=_job_to_view(job)
        );
    }
    if request.project_id != job.project_id {
        raise ValueError("A revision cannot change project_id");
    }
    if not _may_revise(job.status) {
        return MutationResult(
            accepted=False,
            idempotent_replay=False,
            message="Wait for the active phase to finish before revising",
            job=_job_to_view(job)
        );
    }
    _ = _add_revision(
        job,
        request,
        reason.strip() or "Coordinator revision",
        idempotency_key
    );
    _reset_for_revision(job);
    commit();
    view = _job_to_view(job);
    _ = _launch_job(job.job_id);
    return MutationResult(
        accepted=True,
        idempotent_replay=False,
        message="Revision queued",
        job=view
    );
}


def _get_job(job_id: str) -> JobDetailView | None {
    job = _find_owned_job(job_id);
    if job is None {
        return None;
    }
    _recover_job(job);
    return _job_detail_to_view(job);
}


def _list_jobs(project_id: str = "") -> list[JobView] {
    jobs = [
        job
        for job in _owned_jobs()
        if not project_id or job.project_id == project_id
    ];
    jobs.sort(
        key=lambda (job: HardwareJobNode) {
            job.updated_at;
        },
        reverse=True
    );
    for job in jobs {
        _recover_job(job);
    }
    return [_job_to_view(job) for job in jobs];
}


def _cancel_job(
    job_id: str,
    reason: str = "Cancelled by coordinator"
) -> MutationResult {
    job = _find_owned_job(job_id);
    if job is None {
        return MutationResult(
            accepted=False,
            idempotent_replay=False,
            message="Hardware job not found",
            job=None
        );
    }
    if job.status == JobStatus.CANCELLED {
        return MutationResult(
            accepted=True,
            idempotent_replay=True,
            message="Hardware job is already cancelled",
            job=_job_to_view(job)
        );
    }
    if _is_terminal(job.status) {
        return MutationResult(
            accepted=False,
            idempotent_replay=False,
            message=f"Cannot cancel a terminal {job.status} job",
            job=_job_to_view(job)
        );
    }
    job.cancel_requested = True;
    job.cancel_reason = reason.strip() or "Cancelled by coordinator";
    _add_event(
        job,
        EventKind.WARNING,
        "Cancellation requested at the next safe phase boundary"
    );
    if job.status in [
        JobStatus.QUEUED,
        JobStatus.ASSEMBLY_REQUIRED,
        JobStatus.BLOCKED
    ] {
        _set_status(job, JobStatus.CANCELLED, job.cancel_reason);
    }
    commit();
    return MutationResult(
        accepted=True,
        idempotent_replay=False,
        message="Cancellation accepted",
        job=_job_to_view(job)
    );
}


def _resolve_gate(
    job_id: str,
    gate_id: str,
    accepted: bool,
    resolution_note: str,
    idempotency_key: str
) -> MutationResult {
    _validate_idempotency_key(idempotency_key);
    job = _find_owned_job(job_id);
    if job is None {
        return MutationResult(
            accepted=False,
            idempotent_replay=False,
            message="Hardware job not found",
            job=None
        );
    }
    gate = _find_gate(job, gate_id);
    if gate is None {
        return MutationResult(
            accepted=False,
            idempotent_replay=False,
            message="Hardware gate not found",
            job=_job_to_view(job)
        );
    }
    if gate.resolution_idempotency_key == idempotency_key {
        return MutationResult(
            accepted=gate.accepted,
            idempotent_replay=True,
            message="Gate resolution already recorded",
            job=_job_to_view(job)
        );
    }
    if gate.status != GateStatus.OPEN {
        return MutationResult(
            accepted=False,
            idempotent_replay=False,
            message="Hardware gate is already closed",
            job=_job_to_view(job)
        );
    }
    gate.accepted = accepted;
    gate.resolution_note = resolution_note;
    gate.resolution_idempotency_key = idempotency_key;
    gate.resolved_at = time();
    gate.status = GateStatus.RESOLVED if accepted else GateStatus.REJECTED;
    _add_event(
        job,
        EventKind.GATE_RESOLVED,
        "Gate accepted" if accepted else "Gate rejected",
        {"gate_id": gate.gate_id, "accepted": str(accepted)}
    );
    if not accepted {
        job.error_code = "GATE_REJECTED";
        job.error_message = resolution_note or "Coordinator rejected the gate";
        _set_status(
            job,
            JobStatus.BLOCKED,
            job.error_message,
            EventKind.WARNING
        );
        commit();
        return MutationResult(
            accepted=False,
            idempotent_replay=False,
            message="Gate rejected; hardware job blocked",
            job=_job_to_view(job)
        );
    }
    job.error_code = "";
    job.error_message = "";
    _set_status(job, gate.resume_status, "Gate accepted; job resumed");
    commit();
    view = _job_to_view(job);
    _ = _launch_job(job.job_id);
    return MutationResult(
        accepted=True,
        idempotent_replay=False,
        message="Gate accepted; hardware job resumed",
        job=view
    );
}


def _resume_job(job_id: str) -> MutationResult {
    job = _find_owned_job(job_id);
    if job is None {
        return MutationResult(
            accepted=False,
            idempotent_replay=False,
            message="Hardware job not found",
            job=None
        );
    }
    if job.status != JobStatus.BLOCKED {
        return MutationResult(
            accepted=False,
            idempotent_replay=False,
            message="Only a blocked job can be resumed without a revision",
            job=_job_to_view(job)
        );
    }
    for gate in _job_gates(job) {
        if (
            gate.revision_id == job.current_revision_id
            and gate.status == GateStatus.OPEN
        ) {
            return MutationResult(
                accepted=False,
                idempotent_replay=False,
                message="Resolve the open hardware gate before resuming",
                job=_job_to_view(job)
            );
        }
    }
    job.error_code = "";
    job.error_message = "";
    _set_status(job, job.resume_status, "Blocked phase queued for retry");
    commit();
    view = _job_to_view(job);
    _ = _launch_job(job.job_id);
    return MutationResult(
        accepted=True,
        idempotent_replay=False,
        message="Hardware job resumed",
        job=view
    );
}


def _discover_devices -> list[DeviceView] {
    devices = _discover_device_views();
    commit();
    return devices;
}


def _get_artifacts(
    job_id: str,
    revision_id: str = ""
) -> list[ArtifactView] {
    job = _find_owned_job(job_id);
    if job is None {
        return [];
    }
    revision = (
        _find_revision(job, revision_id)
        if revision_id
        else _current_revision(job)
    );
    if revision is None {
        return [];
    }
    return [
        _artifact_to_view(artifact)
        for artifact in _revision_artifacts(revision)
    ];
}


def _get_events(
    job_id: str,
    after_sequence: int = 0
) -> list[EventView] {
    job = _find_owned_job(job_id);
    if job is None {
        return [];
    }
    return [
        _event_to_view(event)
        for event in _job_events(job)
        if event.sequence > after_sequence
    ];
}


def _get_capabilities -> list[CapabilityView] {
    return _capability_views();
}


def _get_artifact_content(
    job_id: str,
    artifact_id: str
) -> ArtifactContentView | None {
    job = _find_owned_job(job_id);
    if job is None {
        return None;
    }
    for revision in _job_revisions(job) {
        for artifact in _revision_artifacts(revision) {
            if artifact.artifact_id == artifact_id {
                view = _artifact_to_view(artifact);
                content = _read_artifact(view);
                digest = sha256(content).hexdigest();
                if digest != view.sha256 {
                    raise ValueError(
                        f"Artifact integrity check failed for {artifact_id}"
                    );
                }
                return ArtifactContentView(
                    artifact_id=view.artifact_id,
                    name=view.name,
                    media_type=view.media_type,
                    sha256=view.sha256,
                    content=content
                );
            }
        }
    }
    return None;
}


def:priv stream_events(
    job_id: str,
    after_sequence: int = 0,
    idle_timeout_seconds: float = 30.0,
    poll_interval_seconds: float = 0.25
) -> Generator[EventView, None, None] {
    job = _find_owned_job(job_id);
    if job is None {
        raise ValueError("Hardware job not found");
    }
    safe_timeout = max(1.0, min(idle_timeout_seconds, 300.0));
    safe_poll = max(0.05, min(poll_interval_seconds, 2.0));

    def stream -> Generator[EventView, None, None] {
        cursor = after_sequence;
        deadline = time() + safe_timeout;
        while time() < deadline {
            current = _find_owned_job(job_id);
            if current is None {
                return;
            }
            emitted = False;
            for event in _job_events(current) {
                if event.sequence > cursor {
                    cursor = event.sequence;
                    emitted = True;
                    yield _event_to_view(event);
                }
            }
            if emitted {
                deadline = time() + safe_timeout;
            }
            if (
                _is_terminal(current.status)
                or current.status == JobStatus.ASSEMBLY_REQUIRED
                or current.status == JobStatus.BLOCKED
            ) {
                return;
            }
            sleep(safe_poll);
        }
    }

    report stream();
}


def:priv submit_job(
    hardware_request: HardwareRequest,
    idempotency_key: str
) -> SubmitJobResponse {
    return _submit_job(hardware_request, idempotency_key);
}


def:priv revise_job(
    job_id: str,
    hardware_request: HardwareRequest,
    reason: str,
    idempotency_key: str
) -> MutationResult {
    return _revise_job(
        job_id,
        hardware_request,
        reason,
        idempotency_key
    );
}


def:priv get_job(job_id: str) -> JobDetailView | None {
    return _get_job(job_id);
}


def:priv list_jobs(project_id: str = "") -> list[JobView] {
    return _list_jobs(project_id);
}


def:priv cancel_job(
    job_id: str,
    reason: str = "Cancelled by coordinator"
) -> MutationResult {
    return _cancel_job(job_id, reason);
}


def:priv resolve_gate(
    job_id: str,
    gate_id: str,
    accepted: bool,
    resolution_note: str,
    idempotency_key: str
) -> MutationResult {
    return _resolve_gate(
        job_id,
        gate_id,
        accepted,
        resolution_note,
        idempotency_key
    );
}


def:priv resume_job(job_id: str) -> MutationResult {
    return _resume_job(job_id);
}


def:priv discover_devices -> list[DeviceView] {
    return _discover_devices();
}


def:priv get_artifacts(
    job_id: str,
    revision_id: str = ""
) -> list[ArtifactView] {
    return _get_artifacts(job_id, revision_id);
}


def:priv get_events(
    job_id: str,
    after_sequence: int = 0
) -> list[EventView] {
    return _get_events(job_id, after_sequence);
}


def:priv get_capabilities -> list[CapabilityView] {
    return _get_capabilities();
}


def:priv get_artifact_content(
    job_id: str,
    artifact_id: str
) -> ArtifactContentView | None {
    return _get_artifact_content(job_id, artifact_id);
}
