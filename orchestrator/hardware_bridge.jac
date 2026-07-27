"""Coordinator bridge for the guarded Jac hardware lifecycle."""

import os;
import from base64 { b64encode }
import from time { sleep }
import from hardware.api {
    _get_artifact_content,
    _get_events,
    _get_job,
    _resolve_gate,
    _submit_job
}
import from hardware.contracts {
    EventView,
    ExecutionMode,
    GateStatus,
    GateView,
    HardwareRequest,
    JobDetailView,
    JobStatus,
    ProvisionPolicy
}
import from hardware.integration { _register_hardware_service }
import from hardware.orchestration { _run_job }


glob DEFAULT_HARDWARE_INVENTORY: list[str] = [
    "doit-esp32-devkit-v1-30pin",
    "gy521-mpu6050",
    "led-5mm-red",
    "resistor-220ohm",
    "button-6mm",
    "half-breadboard-400",
];


def _artifact_snapshots(detail: JobDetailView) -> list[dict] {
    artifacts: list[dict] = [];
    for artifact in detail.artifacts {
        data_url = "";
        if artifact.kind.value == "assembly_step_svg" {
            content = _get_artifact_content(
                detail.job.job_id,
                artifact.artifact_id
            );
            if content is not None {
                encoded = b64encode(content.content).decode("ascii");
                data_url = "data:" + content.media_type + ";base64," + encoded;
            }
        }
        artifacts.append({
            "artifact_id": artifact.artifact_id,
            "kind": artifact.kind.value,
            "name": artifact.name,
            "media_type": artifact.media_type,
            "size_bytes": artifact.size_bytes,
            "data_url": data_url
        });
    }
    return artifacts;
}


obj HardwareDispatch {
    has job_id: str = "",
        revision_id: str = "",
        status: JobStatus = JobStatus.QUEUED,
        summary: str = "",
        error: str = "",
        success: bool = False,
        awaiting_gate: bool = False,
        timed_out: bool = False,
        artifact_count: int = 0,
        artifacts: list[dict] = [],
        events: list[EventView] = [],
        open_gates: list[GateView] = [];
}


def _terminal(status: JobStatus) -> bool {
    return status in [
        JobStatus.SUCCEEDED,
        JobStatus.FAILED,
        JobStatus.CANCELLED,
        JobStatus.INTERRUPTED,
        JobStatus.ROLLED_BACK,
    ];
}


def _requires_physical_deploy(prompt: str) -> bool {
    text = prompt.lower();
    return any(
        phrase in text
        for phrase in [
            "flash ",
            "flash the",
            "deploy to esp32",
            "deploy the esp32",
            "provision the esp32",
            "write it to the esp32",
        ]
    );
}


def _execution_mode(prompt: str) -> ExecutionMode {
    requested = os.environ.get("WIREJAC_HARDWARE_MODE", "").lower().strip();
    if requested == "deploy" {
        return ExecutionMode.DEPLOY;
    }
    if requested == "simulate" {
        return ExecutionMode.SIMULATE;
    }
    if requested == "plan" {
        return ExecutionMode.PLAN;
    }
    if "simulate" in prompt.lower() {
        return ExecutionMode.SIMULATE;
    }
    if _requires_physical_deploy(prompt) {
        return ExecutionMode.DEPLOY;
    }
    return ExecutionMode.PLAN;
}


def _provision_policy() -> ProvisionPolicy {
    requested = os.environ.get(
        "WIREJAC_HARDWARE_PROVISION",
        "never"
    ).lower().strip();
    if requested == "force" {
        return ProvisionPolicy.FORCE;
    }
    if requested in ["allow", "allow_if_needed"] {
        return ProvisionPolicy.ALLOW_IF_NEEDED;
    }
    return ProvisionPolicy.NEVER;
}


def hardware_request_for_change(
    request_id: str,
    prompt: str,
    device_task: str
) -> HardwareRequest {
    full_prompt = prompt + "\n\nDevice task: " + device_task;
    metadata: dict[str, str] = {
        "graph_request_id": request_id,
    };
    expected_mac = os.environ.get("WIREJAC_EXPECTED_MAC", "").strip();
    if expected_mac {
        metadata["expected_mac"] = expected_mac;
    }
    return HardwareRequest(
        project_id="graph-" + request_id,
        prompt=full_prompt,
        allowed_inventory=DEFAULT_HARDWARE_INVENTORY,
        execution_mode=_execution_mode(full_prompt),
        device_selector=os.environ.get("WIREJAC_DEVICE_SELECTOR", ""),
        provision_policy=_provision_policy(),
        metadata=metadata
    );
}


def _dispatch_from_detail(
    detail: JobDetailView,
    after_sequence: int = 0
) -> HardwareDispatch {
    events = _get_events(detail.job.job_id, after_sequence);
    open_gates = [
        gate
        for gate in detail.gates
        if gate.status == GateStatus.OPEN
    ];
    status = detail.job.status;
    awaiting_gate = status in [
        JobStatus.ASSEMBLY_REQUIRED,
        JobStatus.BLOCKED,
    ];
    summary = detail.job.error_message;
    if events {
        summary = events[-1].message;
    }
    if not summary {
        summary = "Hardware job is " + status.value;
    }
    return HardwareDispatch(
        job_id=detail.job.job_id,
        revision_id=detail.job.revision_id,
        status=status,
        summary=summary,
        error=detail.job.error_message,
        success=status == JobStatus.SUCCEEDED,
        awaiting_gate=awaiting_gate,
        artifact_count=len(detail.artifacts),
        artifacts=_artifact_snapshots(detail),
        events=events,
        open_gates=open_gates
    );
}


def refresh_hardware_job(
    job_id: str,
    after_sequence: int = 0
) -> HardwareDispatch {
    detail = _get_job(job_id);
    if detail is None {
        return HardwareDispatch(
            job_id=job_id,
            status=JobStatus.FAILED,
            summary="Hardware job was not found",
            error="HARDWARE_JOB_NOT_FOUND"
        );
    }
    return _dispatch_from_detail(detail, after_sequence);
}


def wait_for_hardware_job(
    job_id: str,
    after_sequence: int = 0,
    max_polls: int = 200
) -> HardwareDispatch {
    polls = max(1, min(max_polls, 600));
    latest = refresh_hardware_job(job_id, after_sequence);
    for _ in range(polls) {
        if _terminal(latest.status) {
            return latest;
        }
        if latest.awaiting_gate and (
            latest.status != JobStatus.ASSEMBLY_REQUIRED
            or latest.open_gates
        ) {
            return latest;
        }
        sleep(0.05);
        latest = refresh_hardware_job(job_id, after_sequence);
    }
    latest.timed_out = True;
    latest.summary = "Timed out waiting for the hardware lifecycle";
    return latest;
}


def dispatch_hardware_job(
    request_id: str,
    prompt: str,
    device_task: str,
    attempt: int = 0
) -> HardwareDispatch {
    _register_hardware_service();
    request = hardware_request_for_change(request_id, prompt, device_task);
    response = _submit_job(
        request,
        "graph:" + request_id + ":device:" + str(attempt),
        launch_job=False
    );
    # A server request owns the guest graph transaction until it returns, so a
    # background flow cannot advance this graph-owned job while we poll it.
    _ = _run_job(response.job.job_id);
    return wait_for_hardware_job(response.job.job_id);
}


"""Queue a real hardware run and return before its LLM phases finish."""
def start_hardware_job(
    request_id: str,
    prompt: str,
    device_task: str,
    attempt: int = 0
) -> HardwareDispatch {
    _register_hardware_service();
    request = hardware_request_for_change(request_id, prompt, device_task);
    response = _submit_job(
        request,
        "graph:" + request_id + ":device:" + str(attempt),
        launch_job=True
    );
    return HardwareDispatch(
        job_id=response.job.job_id,
        revision_id=response.job.revision_id,
        status=response.job.status,
        summary="Hardware job queued",
        success=False,
        awaiting_gate=False
    );
}


def resolve_hardware_gate(
    job_id: str,
    gate_id: str,
    accepted: bool,
    resolution_note: str,
    idempotency_key: str
) -> HardwareDispatch {
    _register_hardware_service();
    mutation = _resolve_gate(
        job_id,
        gate_id,
        accepted,
        resolution_note,
        idempotency_key,
        launch_job=False
    );
    if mutation.job is None {
        return HardwareDispatch(
            job_id=job_id,
            status=JobStatus.FAILED,
            summary=mutation.message,
            error=mutation.message
        );
    }
    _ = _run_job(mutation.job.job_id);
    return wait_for_hardware_job(mutation.job.job_id);
}


def hardware_dispatch_snapshot(result: HardwareDispatch) -> dict[str, object] {
    return {
        "job_id": result.job_id,
        "revision_id": result.revision_id,
        "status": result.status.value,
        "summary": result.summary,
        "error": result.error,
        "success": result.success,
        "awaiting_gate": result.awaiting_gate,
        "timed_out": result.timed_out,
        "artifact_count": result.artifact_count,
        "artifacts": result.artifacts,
        "events": [
            {
                "sequence": event.sequence,
                "kind": event.kind.value,
                "status": event.status.value,
                "phase": event.phase.value,
                "message": event.message,
                "data": event.data,
            }
            for event in result.events
        ],
        "open_gates": [
            {
                "gate_id": gate.gate_id,
                "kind": gate.kind.value,
                "title": gate.title,
                "instructions": gate.instructions,
                "resume_status": gate.resume_status.value,
            }
            for gate in result.open_gates
        ],
    };
}
