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
            "Repair the rejected phone-snatch motion design and deploy it to "
            "the connected ESP32. The assembled circuit is fixed: GY-521 SDA "
            "is GPIO21, GY-521 SCL is GPIO22, and the active-low recording "
            "button is GPIO19 to GND using the internal pull-up. GY-521 VCC "
            "is ESP32 3V3, and GY-521 GND and the button ground share ESP32 "
            "GND. Preserve those assignments and do not use ESP32 "
            "boot-strapping GPIOs. "
            "The MicroPython application must emit sensor.detected after the "
            "MPU6050 responds at 0x68, wirejac.ready after self-test, periodic "
            "wirejac.heartbeat events, recording.started/recording.stopped on "
            "button presses, and motion.sample readings over serial while "
            "recording. The previous firmware revision was rejected for "
            "inventing HEARTBEAT_INTERVAL_S, SAMPLE_INTERVAL_MS, emit_event, "
            "and an events-module post_json, and for declaring global state. "
            "Use only the reviewed direct APIs supplied by the authoring "
            "contract and keep all mutable state inside run()."
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
        metadata={"expected_mac": expected_mac}
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
