from __future__ import annotations

import json
import hashlib
from pathlib import Path
import threading
import time

import pytest

from hardware.adapters.host_runtime import (
    HostRuntime,
    capabilities_json,
    configure_runtime,
    persist_artifact,
    read_artifact,
)
from hardware.adapters.models import (
    CommandResult,
    DeviceIdentity,
    FlashBackupResult,
    ResetResult,
    RestoreResult,
    SerialCaptureResult,
    StageResult,
)


def test_json_facade_configures_and_persists_artifacts(tmp_path: Path) -> None:
    configured = json.loads(configure_runtime(str(tmp_path)))
    artifact = json.loads(
        persist_artifact(
            "workspace-1",
            "revision-1",
            "hardware-spec.json",
            b"{}\n",
            "application/json",
        )
    )
    capabilities = json.loads(capabilities_json())

    assert configured["workspace_root"] == str(tmp_path)
    assert artifact["uri"].endswith(
        "workspace-1/revision-1/hardware-spec.json"
    )
    assert Path(artifact["absolute_path"]).read_bytes() == b"{}\n"
    assert read_artifact(artifact["uri"]) == b"{}\n"
    assert "capabilities" in capabilities


def test_runtime_rejects_workspace_external_input(tmp_path: Path) -> None:
    runtime = HostRuntime(tmp_path / "workspace")
    outside = tmp_path / "firmware.bin"
    outside.write_bytes(b"x")

    try:
        runtime._workspace_file(outside)
    except Exception as error:
        assert "configured workspace" in str(error)
    else:
        raise AssertionError("external workspace input was accepted")


def test_simulation_image_injects_bundle_into_pinned_firmware(
    tmp_path: Path,
) -> None:
    pytest.importorskip("littlefs")
    firmware = tmp_path / "base.bin"
    firmware.write_bytes(b"MPY")
    digest = hashlib.sha256(firmware.read_bytes()).hexdigest()
    runtime = HostRuntime(
        tmp_path / "workspace",
        micropython_firmware=firmware,
        micropython_sha256=digest,
    )
    result = runtime.build_simulation_image(
        "jobs/job-1",
        "revision-1",
        {"main.py": "print('ready')\n"},
    )

    image_path = Path(result["image"]["artifact"]["absolute_path"])
    image = image_path.read_bytes()
    assert len(image) == 4 * 1024 * 1024
    assert image[0x1000:0x1003] == b"MPY"
    assert result["image_uri"].startswith("artifact://")
    assert runtime.read_artifact(result["image_uri"]) == image


def test_deploy_release_stages_inactive_slot_before_activation(tmp_path: Path) -> None:
    workspace = tmp_path / "workspace"
    target = tmp_path / "ttyUSB0"
    target.write_bytes(b"")
    by_id = tmp_path / "by-id"
    by_id.mkdir()
    stable = by_id / "usb-test"
    stable.symlink_to(target)
    runtime = HostRuntime(workspace, by_id_dir=by_id, port_provider=lambda: ())

    app = runtime.store.put_bytes("source/releases/A/app.py", b"def run(): pass\n")
    main = runtime.store.put_bytes("source/main.py", b"print('boot')\n")

    class FakeMpremote:
        def __init__(self) -> None:
            self.stages = []
            self.reset_count = 0

        def read_text(self, *_args, **_kwargs):
            return "A\n"

        def stage_files(self, device, files, *, remote_root):
            self.stages.append((dict(files), remote_root))
            return StageResult(device.stable_path, remote_root, (), ())

        def hard_reset(self, device):
            self.reset_count += 1
            command = CommandResult(("reset",), 0, "", "", 0)
            return ResetResult(device.stable_path, command)

    fake = FakeMpremote()
    runtime.mpremote = fake
    result = runtime.deploy_release(
        str(stable),
        {
            "main.py": main.absolute_path,
            "releases/A/app.py": app.absolute_path,
            "config/active": app.absolute_path,
        },
        workspace_id="jobs/job-1",
        revision_id="revision-1",
    )

    assert result["active_before"] == "A"
    assert result["target_slot"] == "B"
    assert "releases/B/app.py" in fake.stages[0][0]
    assert not any(name.startswith("config/") for name in fake.stages[0][0])
    assert set(fake.stages[1][0]) == {
        "config/previous",
        "config/boot_failures.json",
    }
    assert set(fake.stages[2][0]) == {"config/active"}
    assert fake.reset_count == 1


def test_failed_provision_restores_full_flash_backup_once(tmp_path: Path) -> None:
    workspace = tmp_path / "workspace"
    target = tmp_path / "ttyUSB0"
    target.write_bytes(b"")
    by_id = tmp_path / "by-id"
    by_id.mkdir()
    stable = by_id / "usb-test"
    stable.symlink_to(target)
    firmware = tmp_path / "micropython.bin"
    firmware.write_bytes(b"MPY")
    digest = hashlib.sha256(firmware.read_bytes()).hexdigest()
    runtime = HostRuntime(
        workspace,
        by_id_dir=by_id,
        port_provider=lambda: (),
        micropython_firmware=firmware,
        micropython_sha256=digest,
    )
    identity = DeviceIdentity(
        str(stable),
        "ESP32",
        "revision 1",
        "8c:aa:b5:8b:44:5c",
        4096,
        "",
        "",
    )
    command = CommandResult(("esptool",), 0, "", "", 0)

    class FailingEspTool:
        def __init__(self) -> None:
            self.backup_count = 0
            self.provision_count = 0
            self.restore_count = 0

        def backup(self, _device, relative_path, **_kwargs):
            self.backup_count += 1
            artifact = runtime.store.put_bytes(relative_path, b"B" * 4096)
            return FlashBackupResult(identity, artifact, command)

        def provision(self, *_args, **_kwargs):
            self.provision_count += 1
            raise RuntimeError("injected write failure")

        def restore(self, _device, backup_ref, **_kwargs):
            self.restore_count += 1
            return RestoreResult(
                identity,
                backup_ref.sha256,
                backup_ref.size,
                True,
                command,
                command,
            )

    fake = FailingEspTool()
    runtime.esptool = fake
    first = runtime.backup_and_provision_configured_device(
        str(stable),
        workspace_id="jobs/job-1",
        revision_id="revision-1",
        flash_size_bytes=4096,
        expected_mac=identity.mac,
    )
    second = runtime.backup_and_provision_configured_device(
        str(stable),
        workspace_id="jobs/job-1",
        revision_id="revision-1",
        flash_size_bytes=4096,
        expected_mac=identity.mac,
    )

    assert not first["success"]
    assert not first["recovery_failed"]
    assert first["restore"]["backup_sha256"] == first["backup"]["artifact"]["sha256"]
    assert second["schema"] == first["schema"]
    assert second["success"] == first["success"]
    assert second["backup"]["artifact"]["sha256"] == first["backup"]["artifact"]["sha256"]
    assert fake.backup_count == 1
    assert fake.provision_count == 1
    assert fake.restore_count == 1


def test_device_transaction_prevents_interleaved_deployments(tmp_path: Path) -> None:
    workspace = tmp_path / "workspace"
    target = tmp_path / "ttyUSB0"
    target.write_bytes(b"")
    by_id = tmp_path / "by-id"
    by_id.mkdir()
    stable = by_id / "usb-test"
    stable.symlink_to(target)
    runtime = HostRuntime(workspace, by_id_dir=by_id, port_provider=lambda: ())
    identity = DeviceIdentity(
        str(stable),
        "ESP32",
        "revision 1",
        "8c:aa:b5:8b:44:5c",
        4 * 1024 * 1024,
        "",
        "",
    )
    trace: list[tuple[str, str]] = []
    trace_lock = threading.Lock()

    def record(action: str) -> None:
        with trace_lock:
            trace.append((threading.current_thread().name, action))
        time.sleep(0.005)

    class FakeEspTool:
        def identify(self, *_args, **_kwargs):
            record("identify")
            return identity

    class FakeMpremote:
        def read_text(self, *_args, **_kwargs):
            record("read")
            return "A\n"

        def stage_files(self, device, files, *, remote_root):
            record("stage")
            return StageResult(device.stable_path, remote_root, (), ())

        def hard_reset(self, device):
            record("reset")
            return ResetResult(
                device.stable_path,
                CommandResult(("reset",), 0, "", "", 0),
            )

        def capture_serial(self, device, *, expected_events, **_kwargs):
            record("verify")
            expected = tuple(expected_events)
            return SerialCaptureResult(
                device.stable_path,
                (),
                expected,
                expected,
                False,
            )

    runtime.esptool = FakeEspTool()
    runtime.mpremote = FakeMpremote()
    app = runtime.store.put_bytes("source/releases/A/app.py", b"def run(): pass\n")
    main = runtime.store.put_bytes("source/main.py", b"print('boot')\n")
    files = {
        "main.py": main.absolute_path,
        "releases/A/app.py": app.absolute_path,
    }
    results = []

    def deploy(revision_id: str) -> None:
        results.append(
            runtime.deploy_and_verify_release(
                str(stable),
                files,
                workspace_id="jobs/job-1",
                revision_id=revision_id,
                expected_mac=identity.mac,
                expected_events=("wirejac.ready",),
                duration_s=1,
            )
        )

    first = threading.Thread(target=deploy, args=("revision-1",), name="first")
    second = threading.Thread(target=deploy, args=("revision-2",), name="second")
    first.start()
    second.start()
    first.join()
    second.join()

    assert len(results) == 2
    assert all(result["success"] for result in results)
    owners = [owner for owner, _action in trace]
    assert sum(left != right for left, right in zip(owners, owners[1:])) <= 1


def test_interrupted_activated_deployment_resumes_at_verification(
    tmp_path: Path,
) -> None:
    workspace = tmp_path / "workspace"
    target = tmp_path / "ttyUSB0"
    target.write_bytes(b"")
    by_id = tmp_path / "by-id"
    by_id.mkdir()
    stable = by_id / "usb-test"
    stable.symlink_to(target)
    runtime = HostRuntime(workspace, by_id_dir=by_id, port_provider=lambda: ())
    identity = DeviceIdentity(
        str(stable),
        "ESP32",
        "revision 1",
        "8c:aa:b5:8b:44:5c",
        4 * 1024 * 1024,
        "",
        "",
    )

    class FakeEspTool:
        def identify(self, *_args, **_kwargs):
            return identity

    class VerifyOnlyMpremote:
        def __init__(self) -> None:
            self.stage_count = 0

        def stage_files(self, *_args, **_kwargs):
            self.stage_count += 1
            raise AssertionError("an activated journal must not redeploy")

        def capture_serial(self, device, *, expected_events, **_kwargs):
            expected = tuple(expected_events)
            return SerialCaptureResult(
                device.stable_path,
                (),
                expected,
                expected,
                False,
            )

    fake = VerifyOnlyMpremote()
    runtime.esptool = FakeEspTool()
    runtime.mpremote = fake
    runtime.store.put_json(
        "jobs/job-1/revision-1/device/deployment-journal.json",
        {
            "schema": "wirejac.deployment-journal/v1",
            "status": "activated",
            "stable_path": str(stable),
            "expected_mac": identity.mac,
            "active_before": "A",
            "deployment": {"active_before": "A", "target_slot": "B"},
        },
    )

    result = runtime.deploy_and_verify_release(
        str(stable),
        {},
        workspace_id="jobs/job-1",
        revision_id="revision-1",
        expected_mac=identity.mac,
        expected_events=("wirejac.ready",),
        duration_s=1,
    )

    assert result["success"]
    assert result["recovered_interrupted_attempt"]
    assert fake.stage_count == 0
