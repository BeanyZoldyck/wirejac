"""Run the guarded physical phone-snatch motion-test deployment."""

import json;
import os;
import from time { sleep }
import from uuid { uuid4 }
import from hardware.api { _get_job, _resolve_gate }
import from hardware.contracts {
    ExecutionMode,
    HardwareRequest,
    JobStatus,
    ProvisionPolicy
}
import from hardware.graph { _create_job, _job_gates }
import from hardware.integration { _register_hardware_service }
import from hardware.orchestration { _execute_job }


with entry:__main__ {
    stable_port = os.environ.get(
        "WIREJAC_DEVICE",
        "/dev/serial/by-id/usb-Silicon_Labs_CP2102_USB_to_UART_Bridge_Controller_0001-if00-port0"
    );
    expected_mac = os.environ.get("WIREJAC_EXPECTED_MAC", "8c:aa:b5:8b:44:5c");
    _register_hardware_service();
    request = HardwareRequest(
        project_id=f"live-motion-{str(uuid4())}",
        prompt=(
            "Phone-snatch motion test: use the GY-521 and a button to start "
            "and stop recording, then emit motion data over serial."
        ),
        allowed_inventory=[
            "doit-esp32-devkit-v1-30pin",
            "gy521-mpu6050",
            "button",
            "half-breadboard-400",
        ],
        execution_mode=ExecutionMode.DEPLOY,
        device_selector=stable_port,
        provision_policy=ProvisionPolicy.ALLOW_IF_NEEDED,
        metadata={
            "generation": "fixture",
            "fixture": "phone_snatch_motion_test",
            "expected_mac": expected_mac,
        }
    );
    job = _create_job(request, f"live-motion-{str(uuid4())}");
    _execute_job(job);
    gates = _job_gates(job);
    if len(gates) > 0 and job.status == JobStatus.ASSEMBLY_REQUIRED {
        gate = gates[-1];
        result = _resolve_gate(
            job.job_id,
            gate.gate_id,
            True,
            "User confirmed the breadboard assembly.",
            f"resolve-live-motion-{str(uuid4())}"
        );
        if not result.accepted {
            raise RuntimeError(result.message);
        }
    }
    for _ in range(900) {
        detail = _get_job(job.job_id);
        if detail is None {
            raise RuntimeError("Live deployment job disappeared");
        }
        if detail.job.status in [
            JobStatus.SUCCEEDED,
            JobStatus.FAILED,
            JobStatus.BLOCKED,
            JobStatus.ROLLED_BACK
        ] {
            print(json.dumps({
                "job_id": detail.job.job_id,
                "status": detail.job.status,
                "phase": detail.job.phase,
                "error_code": detail.job.error_code,
                "error_message": detail.job.error_message,
                "gates": [
                    {"kind": gate.kind, "title": gate.title}
                    for gate in detail.gates
                ],
            }, sort_keys=True, indent=2));
            break;
        }
        sleep(1);
    }
}
