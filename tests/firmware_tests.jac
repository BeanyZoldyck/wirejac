"""Deterministic firmware compiler tests."""

import from hardware.contracts { HardwareRequest }
import from hardware.firmware { compile_firmware, validate_firmware }
import from hardware.intent_compiler { compile_hardware_intent }
import from hardware.circuit { validate_hardware }
import from hardware.planning {
    PlanningSource,
    default_motion_test_application,
    default_motion_test_intent,
    default_phone_snatch_application,
    default_phone_snatch_intent
}


test "reviewed phone snatch plan uses safe golden pins" {
    request = HardwareRequest(
        project_id="fixture-project",
        prompt="Create a phone-snatching data analytics platform for training."
    );
    intent = default_phone_snatch_intent(request);
    pins = {
        signal.name: signal.preferred_gpio
        for signal in intent.signals
    };
    assert intent.source == PlanningSource.REVIEWED_FIXTURE;
    assert intent.board_profile == "doit-esp32-devkit-v1-30pin";
    assert pins["imu_sda"] == 21;
    assert pins["imu_scl"] == 22;
    assert pins["status_led"] == 18;
    assert pins["test_button"] == 19;
    compiled = compile_hardware_intent(intent, request.project_id);
    validation = validate_hardware(compiled);
    assert validation.valid;
    assert len(compiled.components) == 4;
}


test "reviewed firmware compiles to reproducible A slot bundle" {
    application = default_phone_snatch_application();
    assert validate_firmware(application) == [];
    first = compile_firmware(
        application,
        "fixture-build-1",
        "http://127.0.0.1:8080/events"
    );
    second = compile_firmware(
        application,
        "fixture-build-1",
        "http://127.0.0.1:8080/events"
    );
    assert first.archive_sha256 == second.archive_sha256;
    assert first.manifest == second.manifest;
    assert first.files["config/active"] == "A\n";
    assert "releases/A/app.py" in first.files;
    assert "TRIGGER_WINDOW_MS" in first.files["releases/A/app.py"];
    assert len(first.archive) > 0;
}


test "motion test fixture uses only the imu and recording button" {
    request = HardwareRequest(
        project_id="motion-test-project",
        prompt=(
            "Test phone-snatch motion data with a button to start and stop "
            "recording."
        ),
        allowed_inventory=[
            "doit-esp32-devkit-v1-30pin",
            "gy521-mpu6050",
            "button",
            "half-breadboard-400",
        ]
    );
    intent = default_motion_test_intent(request);
    compiled = compile_hardware_intent(intent, request.project_id);
    validation = validate_hardware(compiled);
    profiles = {component.profile_id for component in compiled.components};

    assert validation.valid;
    assert len(compiled.components) == 2;
    assert "gy521-mpu6050" in profiles;
    assert "button-6mm" in profiles;
    assert "led-5mm-red" not in profiles;
    assert "motion.sample" in compiled.expected_events;
}


test "motion test firmware emits button-controlled motion telemetry" {
    application = default_motion_test_application();
    assert validate_firmware(application) == [];
    assert "recording.started" in application.expected_events;
    assert "motion.sample" in application.expected_events;
    assert "recording.stopped" in application.expected_events;
    bundle = compile_firmware(application, "motion-test-build");
    source = bundle.files["releases/A/app.py"];
    assert "recording = not recording" in source;
    assert '"motion.sample"' in source;
}
