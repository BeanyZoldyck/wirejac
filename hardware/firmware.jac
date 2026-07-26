"""Jac-owned firmware validation and deterministic bundle generation."""

import hardware.firmware_tools as firmware_tools;
import from hardware.planning { FirmwareApplication }


obj FirmwareBundle {
    has build_id: str,
        slot: str,
        files: dict[str, str],
        manifest: str,
        archive: bytes,
        archive_sha256: str,
        expected_events: list[str],
        self_test_steps: list[str];
}


obj FirmwarePins {
    has sda: int = 21,
        scl: int = 22,
        led: int = 18,
        button: int = 19;
}


def validate_firmware(application: FirmwareApplication) -> list[str] {
    return firmware_tools.validate_application(application.app_source);
}


def compile_firmware(
    application: FirmwareApplication,
    build_id: str,
    ingest_url: str = "",
    slot: str = "A",
    pins: FirmwarePins | None = None
) -> FirmwareBundle {
    issues = validate_firmware(application);
    if issues {
        raise ValueError("; ".join(issues));
    }
    selected = pins or FirmwarePins();
    files = firmware_tools.compile_bundle(
        app_source=application.app_source,
        build_id=build_id,
        ingest_url=ingest_url,
        slot=slot,
        pin_sda=selected.sda,
        pin_scl=selected.scl,
        pin_led=selected.led,
        pin_button=selected.button
    );
    manifest = firmware_tools.manifest_json(files, build_id, slot);
    archive = firmware_tools.bundle_zip(files, manifest);
    return FirmwareBundle(
        build_id=build_id,
        slot=slot,
        files=files,
        manifest=manifest,
        archive=archive,
        archive_sha256=firmware_tools.sha256_bytes(archive),
        expected_events=application.expected_events,
        self_test_steps=application.self_test_steps
    );
}
