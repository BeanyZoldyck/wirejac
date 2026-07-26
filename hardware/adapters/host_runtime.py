"""Small JSON facade intended for Jac's Python interoperability boundary."""

from __future__ import annotations

import contextlib
from dataclasses import asdict
import hashlib
import json
import os
from pathlib import Path
import sys
import threading
from collections.abc import Mapping, Sequence
from typing import Any

from .artifacts import ArtifactStore
from .commands import SubprocessRunner
from .discovery import DeviceDiscovery, discover_capabilities
from .esptool import EspToolAdapter
from .micropython_image import MicroPythonImageBuilder
from .models import (
    ArtifactRef,
    Capability,
    DeviceSelectionError,
    LittleFSProfile,
    SafetyError,
    VerificationError,
    WokwiControl,
)
from .mpremote import DeviceFileLock, MpremoteAdapter
from .wokwi import WokwiAdapter


_DEFAULT_MICROPYTHON_NAME = "ESP32_GENERIC-20260406-v1.28.0.bin"
_DEFAULT_MICROPYTHON_SHA256 = (
    "cd7820d02c35d34dd403b44263129c6a511b350aea8446c229890753fe240784"
)
_ARTIFACT_URI_PREFIX = "artifact://"


def _json(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


def _mapping_json(value: str, name: str) -> dict[str, Any]:
    try:
        decoded = json.loads(value)
    except (TypeError, ValueError) as error:
        raise SafetyError(f"{name} must be valid JSON") from error
    if not isinstance(decoded, dict):
        raise SafetyError(f"{name} must be a JSON object")
    return decoded


def _sequence_json(value: str, name: str) -> list[Any]:
    try:
        decoded = json.loads(value)
    except (TypeError, ValueError) as error:
        raise SafetyError(f"{name} must be valid JSON") from error
    if not isinstance(decoded, list):
        raise SafetyError(f"{name} must be a JSON array")
    return decoded


class HostRuntime:
    """Configured host services; methods accept no executable or shell input."""

    def __init__(
        self,
        workspace_root: str | os.PathLike[str],
        *,
        by_id_dir: str | os.PathLike[str] = "/dev/serial/by-id",
        store_dir: str = "artifacts",
        command_prefix: Sequence[str] | None = None,
        port_provider=None,
        serial_factory=None,
        wokwi_client_factory=None,
        micropython_firmware: str | os.PathLike[str] | None = None,
        micropython_sha256: str | None = None,
    ) -> None:
        self.store = ArtifactStore(workspace_root, store_dir)
        self.images = MicroPythonImageBuilder(self.store)
        self.discovery = DeviceDiscovery(by_id_dir, port_provider=port_provider)
        prefix = tuple(command_prefix or (sys.executable,))
        self.runner = SubprocessRunner(
            [prefix[0]],
            cwd_root=self.store.workspace_root,
        )
        self.esptool = EspToolAdapter(
            self.runner,
            self.store,
            command_prefix=prefix + ("-m", "esptool"),
        )
        self.mpremote = MpremoteAdapter(
            self.runner,
            self.store.root / ".locks",
            command_prefix=prefix + ("-m", "mpremote"),
            serial_factory=serial_factory,
        )
        self.wokwi = WokwiAdapter(client_factory=wokwi_client_factory)
        configured_firmware = (
            os.fspath(micropython_firmware)
            if micropython_firmware is not None
            else os.environ.get(
                "WIREJAC_MICROPYTHON_FIRMWARE",
                str(
                    Path.home()
                    / ".wirejac"
                    / "firmware"
                    / _DEFAULT_MICROPYTHON_NAME
                ),
            )
        )
        self.micropython_firmware = Path(configured_firmware).expanduser()
        self.micropython_sha256 = (
            micropython_sha256
            or os.environ.get("WIREJAC_MICROPYTHON_SHA256")
            or _DEFAULT_MICROPYTHON_SHA256
        ).lower()

    def _device(self, stable_path: str):
        device = self.discovery.get(stable_path)
        if device is None:
            raise DeviceSelectionError(
                "device selector does not match a connected stable serial identity"
            )
        return device

    @contextlib.contextmanager
    def _device_transaction(self, device, *, timeout_s: float = 30):
        """Serialize every multi-command physical operation by stable identity."""

        with DeviceFileLock(
            self.store.root / ".device-transactions",
            device.stable_path,
            timeout_s=timeout_s,
        ):
            yield

    def _workspace_file(self, value: str | os.PathLike[str]) -> Path:
        path = Path(value).expanduser().resolve(strict=True)
        if not path.is_file() or not path.is_relative_to(self.store.workspace_root):
            raise SafetyError("host input file must be inside the configured workspace")
        return path

    def _firmware_asset(self) -> Path:
        path = self.micropython_firmware.resolve(strict=True)
        if not path.is_file():
            raise SafetyError("configured MicroPython firmware is not a regular file")
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if digest != self.micropython_sha256:
            raise VerificationError(
                "configured MicroPython firmware SHA-256 does not match"
            )
        return path

    @staticmethod
    def _artifact_ref(value: Mapping[str, Any]) -> ArtifactRef:
        required = {"relative_path", "absolute_path", "sha256", "size", "created"}
        if set(value) != required:
            raise SafetyError("artifact reference has an invalid shape")
        return ArtifactRef(
            relative_path=str(value["relative_path"]),
            absolute_path=str(value["absolute_path"]),
            sha256=str(value["sha256"]),
            size=int(value["size"]),
            created=bool(value["created"]),
        )

    def _artifact_relative_from_uri(self, uri: str) -> str:
        if not uri.startswith(_ARTIFACT_URI_PREFIX):
            raise SafetyError("unsupported artifact URI")
        relative = uri[len(_ARTIFACT_URI_PREFIX) :]
        self.store.path_for(relative)
        return relative

    def capabilities(self) -> dict[str, Any]:
        report = asdict(discover_capabilities(self.discovery))
        firmware_available = self.micropython_firmware.expanduser().is_file()
        report["capabilities"] = list(report["capabilities"])
        report["capabilities"].append(
            asdict(
                Capability(
                    "micropython_firmware",
                    firmware_available,
                    detail=(
                        f"{_DEFAULT_MICROPYTHON_NAME} configured"
                        if firmware_available
                        else "configured MicroPython firmware is missing"
                    ),
                    version="1.28.0" if firmware_available else None,
                )
            )
        )
        return report

    def discover_devices(self) -> list[dict[str, Any]]:
        return [asdict(item) for item in self.discovery.list_devices()]

    def persist_artifact(
        self,
        workspace_id: str,
        revision_id: str,
        name: str,
        payload: bytes,
        media_type: str = "application/octet-stream",
    ) -> dict[str, Any]:
        if not isinstance(payload, bytes):
            raise TypeError("artifact payload must be bytes")
        if (
            not media_type
            or len(media_type) > 255
            or any(item in media_type for item in ("\r", "\n", "\x00"))
        ):
            raise SafetyError("artifact media type is invalid")
        relative_path = f"{workspace_id}/{revision_id}/{name}"
        artifact = self.store.put_bytes(relative_path, payload)
        result = asdict(artifact)
        result.update(
            {
                "uri": f"artifact://{relative_path}",
                "media_type": media_type,
                "size_bytes": artifact.size,
            }
        )
        return result

    def read_artifact(self, uri: str, *, max_bytes: int = 16 * 1024 * 1024) -> bytes:
        if max_bytes <= 0 or max_bytes > 64 * 1024 * 1024:
            raise SafetyError("artifact read limit must be in (0, 64 MiB]")
        payload = self.store.read_bytes(self._artifact_relative_from_uri(uri))
        if len(payload) > max_bytes:
            raise SafetyError("artifact exceeds the configured read limit")
        return payload

    def artifact_path(self, uri: str) -> str:
        path = self.store.path_for(self._artifact_relative_from_uri(uri))
        if not path.is_file():
            raise FileNotFoundError(path)
        return str(path)

    def build_simulation_image(
        self,
        workspace_id: str,
        revision_id: str,
        files: Mapping[str, str],
    ) -> dict[str, Any]:
        if not files or not all(
            isinstance(path, str) and isinstance(source, str)
            for path, source in files.items()
        ):
            raise SafetyError("simulation files must map paths to UTF-8 source")
        prefix = f"{workspace_id}/{revision_id}/images"
        filesystem = self.images.build_littlefs_image(
            {
                path: source.encode("utf-8")
                for path, source in files.items()
            },
            f"{prefix}/filesystem.lfs",
            profile=LittleFSProfile(block_size=4096, block_count=512),
        )
        merged = self.images.merge_flash_image(
            self._firmware_asset(),
            filesystem.artifact.absolute_path,
            f"{prefix}/wokwi-flash.bin",
            base_flash_offset=0x1000,
            filesystem_flash_offset=0x200000,
            flash_size_bytes=4 * 1024 * 1024,
        )
        return {
            "filesystem": asdict(filesystem),
            "image": asdict(merged),
            "image_uri": (
                f"{_ARTIFACT_URI_PREFIX}{merged.artifact.relative_path}"
            ),
        }

    def identify_device(
        self,
        stable_path: str,
        *,
        expected_mac: str | None = None,
    ) -> dict[str, Any]:
        device = self._device(stable_path)
        with self._device_transaction(device):
            return asdict(
                self.esptool.identify(
                    device,
                    expected_mac=expected_mac or None,
                )
            )

    def probe_micropython(self, stable_path: str) -> dict[str, Any]:
        device = self._device(stable_path)
        with self._device_transaction(device):
            result = self.mpremote.exec_code(
                device,
                (
                    "import json,sys\n"
                    "print(json.dumps({'runtime':sys.implementation.name,"
                    "'version':list(sys.implementation.version)}))\n"
                ),
                check=False,
            )
        return {
            "available": result.ok and "micropython" in result.stdout.lower(),
            "result": asdict(result),
        }

    def simulate_bundle(
        self,
        diagram: Mapping[str, Any],
        firmware_path: str | os.PathLike[str],
        *,
        controls: Sequence[WokwiControl] = (),
        run_seconds: float = 5,
        expected_events: Sequence[str] = (),
    ) -> dict[str, Any]:
        firmware = self._workspace_file(firmware_path)
        return asdict(
            self.wokwi.run(
                diagram,
                firmware,
                controls=controls,
                run_seconds=run_seconds,
                expected_events=expected_events,
            )
        )

    def backup_device(
        self,
        stable_path: str,
        relative_path: str,
        *,
        flash_size_bytes: int,
        expected_mac: str,
    ) -> dict[str, Any]:
        device = self._device(stable_path)
        with self._device_transaction(device):
            return asdict(
                self.esptool.backup(
                    device,
                    relative_path,
                    size_bytes=flash_size_bytes,
                    expected_mac=expected_mac,
                )
            )

    def provision_device(
        self,
        stable_path: str,
        firmware_path: str | os.PathLike[str],
        backup_ref: Mapping[str, Any],
        *,
        expected_mac: str,
        expected_sha256: str,
        offset: int = 0x1000,
    ) -> dict[str, Any]:
        reference = self._artifact_ref(backup_ref)
        device = self._device(stable_path)
        with self._device_transaction(device, timeout_s=30):
            return asdict(
                self.esptool.provision(
                    device,
                    self._workspace_file(firmware_path),
                    backup_ref=reference,
                    expected_mac=expected_mac,
                    expected_sha256=expected_sha256,
                    offset=offset,
                )
            )

    def provision_configured_device(
        self,
        stable_path: str,
        backup_ref: Mapping[str, Any],
        *,
        expected_mac: str,
    ) -> dict[str, Any]:
        firmware = self._firmware_asset()
        reference = self._artifact_ref(backup_ref)
        device = self._device(stable_path)
        with self._device_transaction(device, timeout_s=30):
            return asdict(
                self.esptool.provision(
                    device,
                    firmware,
                    backup_ref=reference,
                    expected_mac=expected_mac,
                    expected_sha256=self.micropython_sha256,
                )
            )

    def backup_and_provision_configured_device(
        self,
        stable_path: str,
        *,
        workspace_id: str,
        revision_id: str,
        flash_size_bytes: int,
        expected_mac: str,
    ) -> dict[str, Any]:
        """Journal, provision, and recover one ESP32 as a single transaction."""

        device = self._device(stable_path)
        prefix = f"{workspace_id}/{revision_id}/device"
        result_path = f"{prefix}/provision-transaction.json"
        result_file = self.store.path_for(result_path)
        if result_file.is_file():
            result = json.loads(self.store.read_bytes(result_path))
            if (
                result.get("stable_path") != stable_path
                or result.get("expected_mac") != expected_mac
            ):
                raise SafetyError("persisted provisioning transaction target mismatch")
            return result

        with self._device_transaction(device, timeout_s=30):
            if result_file.is_file():
                return json.loads(self.store.read_bytes(result_path))

            backup_path = f"{prefix}/flash-backup.bin"
            intent_path = f"{prefix}/provision-intent.json"
            recovered_interrupted_attempt = False
            if self.store.path_for(intent_path).is_file():
                intent = json.loads(self.store.read_bytes(intent_path))
                reference = self._artifact_ref(intent["backup"])
                try:
                    recovery = asdict(
                        self.esptool.restore(
                            device,
                            reference,
                            expected_mac=expected_mac,
                        )
                    )
                    recovered_interrupted_attempt = True
                except Exception as error:
                    result = {
                        "schema": "wirejac.provision-transaction/v1",
                        "success": False,
                        "stable_path": stable_path,
                        "expected_mac": expected_mac,
                        "backup": intent["backup_result"],
                        "provision": None,
                        "restore": None,
                        "recovered_interrupted_attempt": False,
                        "error": f"interrupted provisioning recovery failed: {error}",
                        "recovery_failed": True,
                    }
                    self.store.put_json(result_path, result)
                    return result
            else:
                backup = self.esptool.backup(
                    device,
                    backup_path,
                    size_bytes=flash_size_bytes,
                    expected_mac=expected_mac,
                )
                backup_result = asdict(backup)
                reference = backup.artifact
                recovery = None
                self.store.put_json(
                    intent_path,
                    {
                        "schema": "wirejac.provision-intent/v1",
                        "stable_path": stable_path,
                        "expected_mac": expected_mac,
                        "backup": asdict(reference),
                        "backup_result": backup_result,
                        "firmware_sha256": self.micropython_sha256,
                    },
                )

            intent = json.loads(self.store.read_bytes(intent_path))
            backup_result = intent["backup_result"]
            reference = self._artifact_ref(intent["backup"])
            try:
                provision = asdict(
                    self.esptool.provision(
                        device,
                        self._firmware_asset(),
                        backup_ref=reference,
                        expected_mac=expected_mac,
                        expected_sha256=self.micropython_sha256,
                    )
                )
                result = {
                    "schema": "wirejac.provision-transaction/v1",
                    "success": True,
                    "stable_path": stable_path,
                    "expected_mac": expected_mac,
                    "backup": backup_result,
                    "provision": provision,
                    "restore": recovery,
                    "recovered_interrupted_attempt": recovered_interrupted_attempt,
                    "error": "",
                    "recovery_failed": False,
                }
            except Exception as error:
                try:
                    restore = asdict(
                        self.esptool.restore(
                            device,
                            reference,
                            expected_mac=expected_mac,
                        )
                    )
                    recovery_failed = False
                    error_text = str(error)
                except Exception as restore_error:
                    restore = None
                    recovery_failed = True
                    error_text = (
                        f"{error}; full-flash recovery also failed: {restore_error}"
                    )
                result = {
                    "schema": "wirejac.provision-transaction/v1",
                    "success": False,
                    "stable_path": stable_path,
                    "expected_mac": expected_mac,
                    "backup": backup_result,
                    "provision": None,
                    "restore": restore,
                    "recovered_interrupted_attempt": recovered_interrupted_attempt,
                    "error": error_text,
                    "recovery_failed": recovery_failed,
                }
            self.store.put_json(result_path, result)
            return result

    def _deploy_bundle_unlocked(
        self,
        device,
        files: Mapping[str, str],
        *,
        remote_root: str,
    ) -> dict[str, Any]:
        local_files = {
            remote: self._workspace_file(local)
            for remote, local in files.items()
        }
        return asdict(
            self.mpremote.stage_files(
                device,
                local_files,
                remote_root=remote_root,
            )
        )

    def deploy_bundle(
        self,
        stable_path: str,
        files: Mapping[str, str],
        *,
        remote_root: str,
    ) -> dict[str, Any]:
        device = self._device(stable_path)
        with self._device_transaction(device):
            return self._deploy_bundle_unlocked(
                device,
                files,
                remote_root=remote_root,
            )

    def _deploy_release_unlocked(
        self,
        device,
        files: Mapping[str, str],
        *,
        workspace_id: str,
        revision_id: str,
    ) -> dict[str, Any]:
        active_text = self.mpremote.read_text(
            device,
            "/config/active",
            missing_ok=True,
        )
        active = (active_text or "").strip()
        if active not in {"A", "B"}:
            active = ""
        target = "B" if active == "A" else "A"

        staged_files: dict[str, str] = {}
        release_prefixes = ("releases/A/", "releases/B/")
        for remote, local in files.items():
            if remote.startswith("config/"):
                continue
            remapped = remote
            for prefix in release_prefixes:
                if remote.startswith(prefix):
                    remapped = f"releases/{target}/{remote[len(prefix):]}"
                    break
            staged_files[remapped] = local
        if not staged_files:
            raise SafetyError("release contains no deployable files")
        stage = self._deploy_bundle_unlocked(
            device,
            staged_files,
            remote_root="/",
        )

        config_prefix = f"{workspace_id}/{revision_id}/activation"
        previous = active or ("B" if target == "A" else "A")
        previous_ref = self.store.put_bytes(
            f"{config_prefix}/previous",
            (previous + "\n").encode("ascii"),
        )
        failures_ref = self.store.put_bytes(
            f"{config_prefix}/boot_failures.json",
            b"{}\n",
        )
        active_ref = self.store.put_bytes(
            f"{config_prefix}/active",
            (target + "\n").encode("ascii"),
        )
        config_stage = self._deploy_bundle_unlocked(
            device,
            {
                "config/previous": previous_ref.absolute_path,
                "config/boot_failures.json": failures_ref.absolute_path,
            },
            remote_root="/",
        )
        activation_stage = self._deploy_bundle_unlocked(
            device,
            {"config/active": active_ref.absolute_path},
            remote_root="/",
        )
        reset = asdict(self.mpremote.hard_reset(device))
        return {
            "active_before": active,
            "target_slot": target,
            "stage": stage,
            "config_stage": config_stage,
            "activation_stage": activation_stage,
            "reset": reset,
        }

    def deploy_release(
        self,
        stable_path: str,
        files: Mapping[str, str],
        *,
        workspace_id: str,
        revision_id: str,
        expected_mac: str = "",
    ) -> dict[str, Any]:
        device = self._device(stable_path)
        with self._device_transaction(device):
            if expected_mac:
                self.esptool.identify(device, expected_mac=expected_mac)
            return self._deploy_release_unlocked(
                device,
                files,
                workspace_id=workspace_id,
                revision_id=revision_id,
            )

    def _rollback_release_unlocked(
        self,
        device,
        *,
        workspace_id: str,
        revision_id: str,
        previous_slot: str,
    ) -> dict[str, Any]:
        if previous_slot not in {"A", "B"}:
            raise SafetyError("rollback slot must be A or B")
        reference = self.store.put_bytes(
            f"{workspace_id}/{revision_id}/rollback/active",
            (previous_slot + "\n").encode("ascii"),
        )
        stage = self._deploy_bundle_unlocked(
            device,
            {"config/active": reference.absolute_path},
            remote_root="/",
        )
        reset = asdict(self.mpremote.hard_reset(device))
        return {"active_slot": previous_slot, "stage": stage, "reset": reset}

    def rollback_release(
        self,
        stable_path: str,
        *,
        workspace_id: str,
        revision_id: str,
        previous_slot: str,
        expected_mac: str = "",
    ) -> dict[str, Any]:
        device = self._device(stable_path)
        with self._device_transaction(device):
            if expected_mac:
                self.esptool.identify(device, expected_mac=expected_mac)
            return self._rollback_release_unlocked(
                device,
                workspace_id=workspace_id,
                revision_id=revision_id,
                previous_slot=previous_slot,
            )

    def verify_device(
        self,
        stable_path: str,
        *,
        expected_events: Sequence[str],
        duration_s: float,
        baudrate: int = 115200,
    ) -> dict[str, Any]:
        device = self._device(stable_path)
        with self._device_transaction(device):
            return asdict(
                self.mpremote.capture_serial(
                    device,
                    duration_s=duration_s,
                    expected_events=expected_events,
                    baudrate=baudrate,
                )
            )

    def deploy_and_verify_release(
        self,
        stable_path: str,
        files: Mapping[str, str],
        *,
        workspace_id: str,
        revision_id: str,
        expected_mac: str,
        expected_events: Sequence[str],
        duration_s: float,
        baudrate: int = 115200,
    ) -> dict[str, Any]:
        """Deploy, verify, and if needed roll back under one device lock."""

        device = self._device(stable_path)
        prefix = f"{workspace_id}/{revision_id}/device"
        result_path = f"{prefix}/deployment-transaction.json"
        journal_path = f"{prefix}/deployment-journal.json"
        result_file = self.store.path_for(result_path)
        if result_file.is_file():
            result = json.loads(self.store.read_bytes(result_path))
            if (
                result.get("stable_path") != stable_path
                or result.get("expected_mac") != expected_mac
            ):
                raise SafetyError("persisted deployment transaction target mismatch")
            return result

        with self._device_transaction(device, timeout_s=30):
            if result_file.is_file():
                return json.loads(self.store.read_bytes(result_path))
            identity = asdict(
                self.esptool.identify(device, expected_mac=expected_mac)
            )
            journal_file = self.store.path_for(journal_path)
            journal = (
                json.loads(self.store.read_bytes(journal_path))
                if journal_file.is_file()
                else None
            )
            deployment = None
            recovered_interrupted_attempt = journal is not None
            if journal is not None and journal.get("status") == "activated":
                deployment = journal.get("deployment")
            else:
                active_text = self.mpremote.read_text(
                    device,
                    "/config/active",
                    missing_ok=True,
                )
                active_before = (active_text or "").strip()
                if active_before not in {"A", "B"}:
                    active_before = ""
                prepared = {
                    "schema": "wirejac.deployment-journal/v1",
                    "status": "prepared",
                    "stable_path": stable_path,
                    "expected_mac": expected_mac,
                    "active_before": active_before,
                }
                self.store.put_json(
                    journal_path,
                    prepared,
                    overwrite=journal_file.is_file(),
                )
                try:
                    deployment = self._deploy_release_unlocked(
                        device,
                        files,
                        workspace_id=workspace_id,
                        revision_id=revision_id,
                    )
                except Exception as error:
                    rollback = None
                    if active_before in {"A", "B"}:
                        rollback = self._rollback_release_unlocked(
                            device,
                            workspace_id=workspace_id,
                            revision_id=revision_id,
                            previous_slot=active_before,
                        )
                    result = {
                        "schema": "wirejac.deployment-transaction/v1",
                        "success": False,
                        "stable_path": stable_path,
                        "expected_mac": expected_mac,
                        "identity": identity,
                        "deployment": None,
                        "verification": None,
                        "rollback": rollback,
                        "rolled_back": rollback is not None,
                        "recovered_interrupted_attempt": recovered_interrupted_attempt,
                        "error": str(error),
                    }
                    self.store.put_json(result_path, result)
                    return result
                self.store.put_json(
                    journal_path,
                    {
                        **prepared,
                        "status": "activated",
                        "deployment": deployment,
                    },
                    overwrite=True,
                )

            verification = asdict(
                self.mpremote.capture_serial(
                    device,
                    duration_s=duration_s,
                    expected_events=expected_events,
                    baudrate=baudrate,
                )
            )
            observed = set(verification.get("observed_events") or ())
            passed = all(event in observed for event in expected_events)
            previous = str((deployment or {}).get("active_before") or "")
            rollback = None
            if not passed and previous in {"A", "B"}:
                rollback = self._rollback_release_unlocked(
                    device,
                    workspace_id=workspace_id,
                    revision_id=revision_id,
                    previous_slot=previous,
                )
            result = {
                "schema": "wirejac.deployment-transaction/v1",
                "success": passed,
                "stable_path": stable_path,
                "expected_mac": expected_mac,
                "identity": identity,
                "deployment": deployment,
                "verification": verification,
                "rollback": rollback,
                "rolled_back": rollback is not None,
                "recovered_interrupted_attempt": recovered_interrupted_attempt,
                "error": "" if passed else "required serial events were not observed",
            }
            self.store.put_json(result_path, result)
            self.store.put_json(
                journal_path,
                {
                    "schema": "wirejac.deployment-journal/v1",
                    "status": "completed",
                    "stable_path": stable_path,
                    "expected_mac": expected_mac,
                    "active_before": previous,
                    "deployment": deployment,
                },
                overwrite=True,
            )
            return result


_runtime_lock = threading.Lock()
_runtime_instance: HostRuntime | None = None


def configure_runtime(
    workspace_root: str,
    store_dir: str = "artifacts",
) -> str:
    """Configure the process facade once Jac knows its workspace root."""

    global _runtime_instance
    runtime = HostRuntime(workspace_root, store_dir=store_dir)
    with _runtime_lock:
        _runtime_instance = runtime
    return _json(
        {
            "workspace_root": str(runtime.store.workspace_root),
            "artifact_root": str(runtime.store.root),
        }
    )


def _runtime() -> HostRuntime:
    with _runtime_lock:
        runtime = _runtime_instance
    if runtime is None:
        configured = os.environ.get("WIREJAC_WORKSPACE_ROOT")
        if not configured:
            raise SafetyError(
                "host runtime is not configured; call configure_runtime() or set "
                "WIREJAC_WORKSPACE_ROOT"
            )
        configure_runtime(configured)
        with _runtime_lock:
            runtime = _runtime_instance
    assert runtime is not None
    return runtime


def capabilities_json() -> str:
    runtime = _runtime_instance
    report = (
        runtime.capabilities()
        if runtime is not None
        else asdict(discover_capabilities(DeviceDiscovery()))
    )
    return _json(report)


def discover_devices_json() -> str:
    runtime = _runtime_instance
    devices = (
        runtime.discover_devices()
        if runtime is not None
        else [asdict(item) for item in DeviceDiscovery().list_devices()]
    )
    return _json(devices)


def persist_artifact(
    workspace_id: str,
    revision_id: str,
    name: str,
    payload: bytes,
    media_type: str = "application/octet-stream",
) -> str:
    return _json(
        _runtime().persist_artifact(
            workspace_id,
            revision_id,
            name,
            payload,
            media_type,
        )
    )

def read_artifact(uri: str) -> bytes:
    return _runtime().read_artifact(uri)


def artifact_path(uri: str) -> str:
    return _runtime().artifact_path(uri)


def build_simulation_image(
    workspace_id: str,
    revision_id: str,
    files_json: str,
) -> str:
    files = _mapping_json(files_json, "files_json")
    if not all(
        isinstance(path, str) and isinstance(source, str)
        for path, source in files.items()
    ):
        raise SafetyError("simulation files must map paths to UTF-8 source")
    return _json(
        _runtime().build_simulation_image(
            workspace_id,
            revision_id,
            files,
        )
    )


def identify_device(stable_path: str, expected_mac: str = "") -> str:
    return _json(
        _runtime().identify_device(
            stable_path,
            expected_mac=expected_mac or None,
        )
    )


def probe_micropython(stable_path: str) -> str:
    return _json(_runtime().probe_micropython(stable_path))


def simulate_bundle(
    diagram_json: str,
    firmware_path: str,
    controls_json: str = "[]",
    run_seconds: float = 5,
    expected_events_json: str = "[]",
) -> str:
    controls = []
    for raw in _sequence_json(controls_json, "controls_json"):
        if not isinstance(raw, dict):
            raise SafetyError("each Wokwi control must be a JSON object")
        try:
            controls.append(
                WokwiControl(
                    at_seconds=float(raw["at_seconds"]),
                    part=str(raw["part"]),
                    control=str(raw["control"]),
                    value=raw["value"],
                )
            )
        except (KeyError, TypeError, ValueError) as error:
            raise SafetyError("Wokwi control has an invalid shape") from error
    expected = _sequence_json(expected_events_json, "expected_events_json")
    if not all(isinstance(item, str) for item in expected):
        raise SafetyError("expected Wokwi events must be strings")
    return _json(
        _runtime().simulate_bundle(
            _mapping_json(diagram_json, "diagram_json"),
            firmware_path,
            controls=controls,
            run_seconds=run_seconds,
            expected_events=expected,
        )
    )


def backup_device(
    stable_path: str,
    relative_path: str,
    flash_size_bytes: int,
    expected_mac: str,
) -> str:
    return _json(
        _runtime().backup_device(
            stable_path,
            relative_path,
            flash_size_bytes=flash_size_bytes,
            expected_mac=expected_mac,
        )
    )


def provision_device(
    stable_path: str,
    firmware_path: str,
    backup_ref_json: str,
    expected_mac: str,
    expected_sha256: str,
    offset: int = 0x1000,
) -> str:
    return _json(
        _runtime().provision_device(
            stable_path,
            firmware_path,
            _mapping_json(backup_ref_json, "backup_ref_json"),
            expected_mac=expected_mac,
            expected_sha256=expected_sha256,
            offset=offset,
        )
    )

def provision_configured_device(
    stable_path: str,
    backup_ref_json: str,
    expected_mac: str,
) -> str:
    return _json(
        _runtime().provision_configured_device(
            stable_path,
            _mapping_json(backup_ref_json, "backup_ref_json"),
            expected_mac=expected_mac,
        )
    )


def backup_and_provision_configured_device(
    stable_path: str,
    workspace_id: str,
    revision_id: str,
    flash_size_bytes: int,
    expected_mac: str,
) -> str:
    return _json(
        _runtime().backup_and_provision_configured_device(
            stable_path,
            workspace_id=workspace_id,
            revision_id=revision_id,
            flash_size_bytes=flash_size_bytes,
            expected_mac=expected_mac,
        )
    )


def deploy_bundle(
    stable_path: str,
    files_json: str,
    remote_root: str,
) -> str:
    files = _mapping_json(files_json, "files_json")
    if not all(isinstance(key, str) and isinstance(value, str) for key, value in files.items()):
        raise SafetyError("deployment files must map remote names to local paths")
    return _json(
        _runtime().deploy_bundle(
            stable_path,
            files,
            remote_root=remote_root,
        )
    )

def deploy_release(
    stable_path: str,
    files_json: str,
    workspace_id: str,
    revision_id: str,
    expected_mac: str = "",
) -> str:
    files = _mapping_json(files_json, "files_json")
    if not all(
        isinstance(key, str) and isinstance(value, str)
        for key, value in files.items()
    ):
        raise SafetyError("deployment files must map remote names to local paths")
    return _json(
        _runtime().deploy_release(
            stable_path,
            files,
            workspace_id=workspace_id,
            revision_id=revision_id,
            expected_mac=expected_mac,
        )
    )


def deploy_and_verify_release(
    stable_path: str,
    files_json: str,
    workspace_id: str,
    revision_id: str,
    expected_mac: str,
    expected_events_json: str,
    duration_s: float,
    baudrate: int = 115200,
) -> str:
    files = _mapping_json(files_json, "files_json")
    if not all(
        isinstance(key, str) and isinstance(value, str)
        for key, value in files.items()
    ):
        raise SafetyError("deployment files must map remote names to local paths")
    expected = _sequence_json(expected_events_json, "expected_events_json")
    if not all(isinstance(item, str) for item in expected):
        raise SafetyError("expected device events must be strings")
    return _json(
        _runtime().deploy_and_verify_release(
            stable_path,
            files,
            workspace_id=workspace_id,
            revision_id=revision_id,
            expected_mac=expected_mac,
            expected_events=expected,
            duration_s=duration_s,
            baudrate=baudrate,
        )
    )


def rollback_release(
    stable_path: str,
    workspace_id: str,
    revision_id: str,
    previous_slot: str,
) -> str:
    return _json(
        _runtime().rollback_release(
            stable_path,
            workspace_id=workspace_id,
            revision_id=revision_id,
            previous_slot=previous_slot,
        )
    )


def verify_device(
    stable_path: str,
    expected_events_json: str,
    duration_s: float,
    baudrate: int = 115200,
) -> str:
    expected = _sequence_json(expected_events_json, "expected_events_json")
    if not all(isinstance(item, str) for item in expected):
        raise SafetyError("expected device events must be strings")
    return _json(
        _runtime().verify_device(
            stable_path,
            expected_events=expected,
            duration_s=duration_s,
            baudrate=baudrate,
        )
    )
