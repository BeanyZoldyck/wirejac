"""Annex tests for private coordinator endpoints."""

import from uuid { uuid4 }
import from hashlib { sha256 }
import from hardware.api {
    _get_artifact_content,
    _get_artifacts,
    _get_capabilities,
    _get_events,
    _get_job,
    _revise_job,
    _submit_job
}
import from hardware.contracts {
    ArtifactInput,
    ArtifactKind,
    ArtifactView,
    ExecutionMode,
    HardwareRequest,
    JobStatus,
    PhaseContext,
    PhaseOutcome,
    PhaseResult
}
import from hardware.graph {
    _create_job,
    _find_owned_job
}
import from hardware.orchestration {
    _clear_phase_hooks,
    _execute_job,
    _register_artifact_read_hook,
    _register_phase_hook
}


def _api_request(project_id: str) -> HardwareRequest {
    return HardwareRequest(
        project_id=project_id,
        prompt="Build an ESP32 motion detector",
        allowed_inventory=["esp32", "mpu6050", "led", "button"],
        execution_mode=ExecutionMode.PLAN
    );
}


def _api_success(_context: PhaseContext) -> PhaseResult {
    return PhaseResult(
        outcome=PhaseOutcome.CONTINUE,
        message="Phase completed"
    );
}


def _api_artifact(context: PhaseContext) -> PhaseResult {
    artifacts: list[ArtifactInput] = [];
    if context.status == JobStatus.GENERATING {
        artifacts.append(
            ArtifactInput(
                kind=ArtifactKind.HARDWARE_SPEC,
                name="hardware-spec.json",
                uri=f"artifact://{context.revision_id}/hardware-spec.json",
                sha256=sha256(b"artifact").hexdigest(),
                media_type="application/json",
                size_bytes=64
            )
        );
    }
    return PhaseResult(
        outcome=PhaseOutcome.CONTINUE,
        message="Phase completed",
        artifacts=artifacts
    );
}


def _api_read_artifact(_view: ArtifactView) -> bytes {
    return b"artifact";
}


def _api_register_hooks(
    generation_hook: Callable[[PhaseContext], PhaseResult]
) {
    _clear_phase_hooks();
    _register_phase_hook(JobStatus.PLANNING, _api_success);
    _register_phase_hook(JobStatus.VALIDATING, _api_success);
    _register_phase_hook(JobStatus.GENERATING, generation_hook);
}


test "submit endpoint is idempotent and returns views" {
    _clear_phase_hooks();
    key = f"submit-{str(uuid4())}";
    request = _api_request(f"api-idempotency-{str(uuid4())}");
    first = _submit_job(request, key);
    second = _submit_job(request, key);
    assert first.created;
    assert not first.idempotent_replay;
    assert not second.created;
    assert second.idempotent_replay;
    assert first.job.job_id == second.job.job_id;
    detail = _get_job(first.job.job_id);
    assert detail is not None;
    assert detail.job.job_id == first.job.job_id;
}


test "revision endpoint is immutable and idempotent" {
    _api_register_hooks(_api_success);
    job = _create_job(
        _api_request(f"api-revision-{str(uuid4())}"),
        f"submit-{str(uuid4())}"
    );
    _execute_job(job);
    assert job.status == JobStatus.SUCCEEDED;
    revised_request = HardwareRequest(
        project_id=job.project_id,
        prompt="Use a higher snatch acceleration threshold",
        allowed_inventory=["esp32", "mpu6050", "led", "button"],
        execution_mode=ExecutionMode.PLAN
    );
    revision_key = f"revision-{str(uuid4())}";
    first = _revise_job(
        job.job_id,
        revised_request,
        "Tune the detection threshold",
        revision_key
    );
    second = _revise_job(
        job.job_id,
        revised_request,
        "Tune the detection threshold",
        revision_key
    );
    assert first.accepted;
    assert not first.idempotent_replay;
    assert second.accepted;
    assert second.idempotent_replay;
    assert second.job is not None;
    assert second.job.revision == 2;
    _clear_phase_hooks();
}


test "artifact and event endpoints return projected data" {
    _api_register_hooks(_api_artifact);
    job = _create_job(
        _api_request(f"api-views-{str(uuid4())}"),
        f"submit-{str(uuid4())}"
    );
    _execute_job(job);
    artifacts = _get_artifacts(job.job_id);
    events = _get_events(job.job_id, 0);
    assert len(artifacts) == 1;
    assert artifacts[0].artifact_id;
    assert len(events) >= 8;
    assert events[-1].status == JobStatus.SUCCEEDED;
    _register_artifact_read_hook(_api_read_artifact);
    content = _get_artifact_content(
        job.job_id,
        artifacts[0].artifact_id
    );
    assert content is not None;
    assert content.content == b"artifact";
    capabilities = _get_capabilities();
    artifact_capabilities = [
        capability
        for capability in capabilities
        if capability.name == "artifact_content"
    ];
    assert len(artifact_capabilities) == 1;
    assert artifact_capabilities[0].available;
    _clear_phase_hooks();
}
