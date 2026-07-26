"""End-to-end deterministic tests for the registered production phase hooks."""

import os;
import from tempfile { mkdtemp }
import from uuid { uuid4 }
import from hardware.api { _get_artifact_content, _get_artifacts }
import from hardware.contracts {
    ArtifactKind,
    ExecutionMode,
    HardwareRequest,
    JobStatus
}
import from hardware.graph {
    HasAssemblyStep,
    HasBoard,
    HasComponent,
    HasNet,
    HasPlacement,
    _create_job,
    _current_revision
}
import from hardware.integration { _register_hardware_service }
import from hardware.orchestration { _execute_job }


test "phone snatch plan runs through production hooks" {
    workspace = mkdtemp(prefix="wirejac-integration-");
    os.environ["WIREJAC_WORKSPACE_ROOT"] = workspace;
    _register_hardware_service();
    request = HardwareRequest(
        project_id=f"phone-snatch-{str(uuid4())}",
        prompt=(
            "Create a phone-snatching data analytics platform for training "
            "with an ESP32 and accelerometer."
        ),
        allowed_inventory=[
            "doit-esp32-devkit-v1-30pin",
            "gy521-mpu6050",
            "led",
            "220-ohm-resistor",
            "button",
            "half-breadboard-400",
        ],
        execution_mode=ExecutionMode.PLAN,
        metadata={"generation": "fixture"}
    );
    job = _create_job(request, f"integration-{str(uuid4())}");
    _execute_job(job);

    assert job.status == JobStatus.SUCCEEDED;
    artifacts = _get_artifacts(job.job_id);
    names = {artifact.name for artifact in artifacts};
    assert "hardware-intent.json" in names;
    assert "hardware-spec.json" in names;
    assert "visualization.json" in names;
    assert "assembly.json" in names;
    assert "diagram.json" in names;
    assert "firmware-bundle.zip" in names;
    assert "firmware-manifest.json" in names;
    assert "step-01.svg" in names;
    assert "step-18.svg" in names;
    assert len([
        artifact
        for artifact in artifacts
        if artifact.kind == ArtifactKind.ASSEMBLY_STEP_SVG
    ]) == 18;

    spec_artifacts = [
        artifact
        for artifact in artifacts
        if artifact.name == "hardware-spec.json"
    ];
    assert len(spec_artifacts) == 1;
    content = _get_artifact_content(
        job.job_id,
        spec_artifacts[0].artifact_id
    );
    assert content is not None;
    assert content.sha256 == spec_artifacts[0].sha256;
    assert b'"gpio": 21' in content.content;
    revision = _current_revision(job);
    assert revision is not None;
    assert len([revision ->:HasBoard:->]) == 1;
    assert len([revision ->:HasComponent:->]) == 4;
    assert len([revision ->:HasNet:->]) == 7;
    assert len([revision ->:HasPlacement:->]) == 5;
    assert len([revision ->:HasAssemblyStep:->]) == 18;
}


test "motion capture test fixture omits optional LED hardware" {
    workspace = mkdtemp(prefix="wirejac-motion-test-");
    os.environ["WIREJAC_WORKSPACE_ROOT"] = workspace;
    _register_hardware_service();
    request = HardwareRequest(
        project_id=f"motion-test-{str(uuid4())}",
        prompt=(
            "For the phone-snatch example, record motion data with a button "
            "to start and stop recording."
        ),
        allowed_inventory=[
            "doit-esp32-devkit-v1-30pin",
            "gy521-mpu6050",
            "button",
            "half-breadboard-400",
        ],
        execution_mode=ExecutionMode.PLAN,
        metadata={"generation": "motion_test"}
    );
    job = _create_job(request, f"motion-test-{str(uuid4())}");
    _execute_job(job);

    assert job.status == JobStatus.SUCCEEDED;
    artifacts = _get_artifacts(job.job_id);
    names = {artifact.name for artifact in artifacts};
    assert "firmware-bundle.zip" in names;
    assert "step-14.svg" in names;
    assert "step-15.svg" not in names;
    revision = _current_revision(job);
    assert revision is not None;
    assert len([revision ->:HasComponent:->]) == 2;
    assert len([revision ->:HasNet:->]) == 5;
    assert len([revision ->:HasPlacement:->]) == 3;
    assert len([revision ->:HasAssemblyStep:->]) == 14;
}
