"""Local synchronous prompt runner for hardware-agent development."""

import json;
import os;
import sys;
import from uuid { uuid4 }
import from hardware.api { _get_job }
import from hardware.contracts {
    ExecutionMode,
    HardwareRequest,
    ProvisionPolicy
}
import from hardware.graph { _create_job }
import from hardware.integration { _register_hardware_service }
import from hardware.orchestration { _execute_job }


def _execution_mode(value: str) -> ExecutionMode {
    normalized = value.strip().lower();
    if normalized == "simulate" {
        return ExecutionMode.SIMULATE;
    }
    if normalized == "deploy" {
        return ExecutionMode.DEPLOY;
    }
    return ExecutionMode.PLAN;
}


with entry:__main__ {
    prompt = (
        " ".join(sys.argv[1:]).strip()
        or "Create a phone-snatching data analytics platform for training."
    );
    mode = _execution_mode(
        os.environ.get("WIREJAC_EXECUTION_MODE", "plan")
    );
    metadata: dict[str, str] = {
        "generation": os.environ.get("WIREJAC_GENERATION", "fixture")
    };
    fixture = os.environ.get("WIREJAC_FIXTURE", "");
    if fixture {
        metadata["fixture"] = fixture;
    }
    expected_mac = os.environ.get("WIREJAC_EXPECTED_MAC", "");
    if expected_mac {
        metadata["expected_mac"] = expected_mac;
    }
    policy = (
        ProvisionPolicy.ALLOW_IF_NEEDED
        if os.environ.get("WIREJAC_ALLOW_PROVISION", "") == "1"
        else ProvisionPolicy.NEVER
    );
    _register_hardware_service();
    request = HardwareRequest(
        project_id=f"local-{str(uuid4())}",
        prompt=prompt,
        allowed_inventory=(
            [
                "doit-esp32-devkit-v1-30pin",
                "gy521-mpu6050",
                "button",
                "half-breadboard-400",
            ]
            if fixture in ["phone_snatch_motion_test", "motion_test"]
            else [
                "doit-esp32-devkit-v1-30pin",
                "gy521-mpu6050",
                "led",
                "220-ohm-resistor",
                "button",
                "half-breadboard-400",
            ]
        ),
        execution_mode=mode,
        device_selector=os.environ.get("WIREJAC_DEVICE", ""),
        provision_policy=policy,
        metadata=metadata
    );
    job = _create_job(request, f"local-{str(uuid4())}");
    _execute_job(job);
    detail = _get_job(job.job_id);
    if detail is None {
        raise RuntimeError("Local hardware job disappeared");
    }
    print(
        json.dumps(
            {
                "job_id": detail.job.job_id,
                "project_id": detail.job.project_id,
                "revision_id": detail.job.revision_id,
                "status": detail.job.status,
                "phase": detail.job.phase,
                "error_code": detail.job.error_code,
                "error_message": detail.job.error_message,
                "artifacts": [
                    {
                        "artifact_id": artifact.artifact_id,
                        "kind": artifact.kind,
                        "name": artifact.name,
                        "uri": artifact.uri,
                        "sha256": artifact.sha256,
                        "media_type": artifact.media_type,
                        "size_bytes": artifact.size_bytes,
                    }
                    for artifact in detail.artifacts
                ],
                "gates": [
                    {
                        "gate_id": gate.gate_id,
                        "kind": gate.kind,
                        "title": gate.title,
                        "instructions": gate.instructions,
                    }
                    for gate in detail.gates
                ],
            },
            sort_keys=True,
            indent=2
        )
    );
}
