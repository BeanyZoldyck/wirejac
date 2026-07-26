"""Narrow, identity-checked esptool operations for ESP32 provisioning."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import re
import sys
from collections.abc import Sequence

from .artifacts import ArtifactStore
from .commands import SubprocessRunner
from .models import (
    ArtifactRef,
    DeviceIdentity,
    DeviceSelectionError,
    FlashBackupResult,
    IdentityMismatchError,
    ProvisionResult,
    RestoreResult,
    SafetyError,
    SerialDevice,
    VerificationError,
)


_MAC_PATTERN = re.compile(r"\b([0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5})\b")
_CHIP_PATTERN = re.compile(
    r"(?:Chip type|Chip is)\s*:\s*([^\r\n(]+?)(?:\s*\(([^)\r\n]+)\))?\s*$",
    re.MULTILINE | re.IGNORECASE,
)
_FLASH_PATTERN = re.compile(
    r"(?:Detected flash size|Flash size)\s*:\s*(\d+)\s*(KB|MB)",
    re.IGNORECASE,
)


def _sha256_file(path: Path) -> tuple[str, int]:
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
            size += len(chunk)
    return digest.hexdigest(), size


def normalize_mac(mac: str) -> str:
    compact = re.sub(r"[^0-9a-fA-F]", "", mac).lower()
    if len(compact) != 12 or re.fullmatch(r"[0-9a-f]{12}", compact) is None:
        raise ValueError(f"invalid MAC address: {mac!r}")
    return ":".join(compact[index : index + 2] for index in range(0, 12, 2))


class EspToolAdapter:
    """Expose only identify, full backup, and guarded provisioning operations."""

    def __init__(
        self,
        runner: SubprocessRunner,
        store: ArtifactStore,
        *,
        command_prefix: Sequence[str] | None = None,
        require_stable_symlink: bool = True,
    ) -> None:
        self.runner = runner
        self.store = store
        self.command_prefix = tuple(
            command_prefix or (sys.executable, "-m", "esptool")
        )
        if not self.command_prefix:
            raise ValueError("esptool command prefix cannot be empty")
        self.require_stable_symlink = require_stable_symlink

    def _port(self, device: SerialDevice) -> str:
        stable = Path(device.stable_path)
        if not stable.is_absolute():
            raise DeviceSelectionError("device path must be absolute")
        if self.require_stable_symlink:
            if not stable.is_symlink():
                raise DeviceSelectionError(
                    "physical operations require a stable serial symlink"
                )
            target = Path(os.path.realpath(stable))
            if target != Path(device.target_path).resolve(strict=False):
                raise DeviceSelectionError("stable device link target changed")
        if not device.accessible:
            raise DeviceSelectionError(
                f"device is not accessible: {device.access_error or 'unknown error'}"
            )
        return device.stable_path

    def _command(self, device: SerialDevice, *arguments: str) -> tuple[str, ...]:
        return self.command_prefix + ("--port", self._port(device), *arguments)

    def plan_identify(
        self, device: SerialDevice
    ) -> tuple[tuple[str, ...], tuple[str, ...]]:
        return (
            self._command(device, "chip-id"),
            self._command(device, "flash-id"),
        )

    def identify(
        self,
        device: SerialDevice,
        *,
        expected_mac: str | None = None,
    ) -> DeviceIdentity:
        chip_command, flash_command = self.plan_identify(device)
        chip_result = self.runner.run(chip_command, timeout_s=30)
        flash_result = self.runner.run(flash_command, timeout_s=30)
        chip_output = chip_result.stdout + "\n" + chip_result.stderr
        flash_output = flash_result.stdout + "\n" + flash_result.stderr

        mac_match = _MAC_PATTERN.search(chip_output)
        chip_match = _CHIP_PATTERN.search(chip_output)
        if mac_match is None or chip_match is None:
            raise VerificationError("esptool output did not contain chip and MAC identity")
        mac = normalize_mac(mac_match.group(1))
        if expected_mac is not None and mac != normalize_mac(expected_mac):
            raise IdentityMismatchError(
                f"expected ESP32 {normalize_mac(expected_mac)}, found {mac}"
            )
        flash_size = None
        flash_match = _FLASH_PATTERN.search(flash_output)
        if flash_match is not None:
            amount = int(flash_match.group(1))
            unit = flash_match.group(2).upper()
            flash_size = amount * (1024 if unit == "KB" else 1024 * 1024)
        revision = chip_match.group(2)
        return DeviceIdentity(
            port=device.stable_path,
            chip=chip_match.group(1).strip(),
            revision=revision.strip() if revision else None,
            mac=mac,
            flash_size_bytes=flash_size,
            chip_id_output=chip_output.strip(),
            flash_id_output=flash_output.strip(),
        )

    def plan_backup(
        self,
        device: SerialDevice,
        output_path: str | os.PathLike[str],
        *,
        size_bytes: int,
    ) -> tuple[str, ...]:
        if size_bytes <= 0:
            raise SafetyError("backup size must be positive")
        return self._command(
            device,
            "read-flash",
            "0x0",
            hex(size_bytes),
            os.fspath(output_path),
        )

    def backup(
        self,
        device: SerialDevice,
        relative_path: str,
        *,
        size_bytes: int,
        expected_mac: str | None = None,
    ) -> FlashBackupResult:
        identity = self.identify(device, expected_mac=expected_mac)
        if (
            identity.flash_size_bytes is not None
            and size_bytes != identity.flash_size_bytes
        ):
            raise VerificationError(
                f"requested {size_bytes} byte backup does not match detected "
                f"{identity.flash_size_bytes} byte flash"
            )
        with self.store.staging_path(suffix=".bin") as temporary:
            command = self.runner.run(
                self.plan_backup(device, temporary, size_bytes=size_bytes),
                timeout_s=600,
            )
            if not temporary.is_file() or temporary.stat().st_size != size_bytes:
                raise VerificationError("esptool backup is missing or has the wrong size")
            artifact = self.store.put_file(relative_path, temporary)
        return FlashBackupResult(identity, artifact, command)

    def plan_provision(
        self,
        device: SerialDevice,
        firmware_path: str | os.PathLike[str],
        *,
        offset: int = 0x1000,
        erase_first: bool = True,
    ) -> tuple[tuple[str, ...], ...]:
        if offset < 0:
            raise SafetyError("flash offset cannot be negative")
        firmware = str(Path(firmware_path).expanduser().resolve(strict=True))
        commands: list[tuple[str, ...]] = []
        if erase_first:
            commands.append(self._command(device, "erase-flash"))
        commands.append(self._command(device, "write-flash", hex(offset), firmware))
        commands.append(self._command(device, "verify-flash", hex(offset), firmware))
        return tuple(commands)

    def provision(
        self,
        device: SerialDevice,
        firmware_path: str | os.PathLike[str],
        *,
        backup_ref: ArtifactRef,
        offset: int = 0x1000,
        erase_first: bool = True,
        expected_mac: str,
        expected_sha256: str | None = None,
    ) -> ProvisionResult:
        identity = self.identify(device, expected_mac=expected_mac)
        firmware = Path(firmware_path).expanduser().resolve(strict=True)
        if not firmware.is_file():
            raise SafetyError("MicroPython firmware must be a regular file")
        firmware_sha, firmware_size = _sha256_file(firmware)
        if expected_sha256 is not None and firmware_sha != expected_sha256.lower():
            raise VerificationError("MicroPython firmware SHA-256 mismatch")

        backup_path = Path(backup_ref.absolute_path).resolve(strict=True)
        if not backup_path.is_relative_to(self.store.root):
            raise SafetyError("provisioning backup is outside the artifact store")
        backup_sha, backup_size = _sha256_file(backup_path)
        if (
            backup_sha != backup_ref.sha256
            or backup_size != backup_ref.size
            or backup_size <= 0
        ):
            raise VerificationError("provisioning backup artifact failed verification")

        commands = self.plan_provision(
            device, firmware, offset=offset, erase_first=erase_first
        )
        index = 0
        if erase_first:
            self.runner.run(commands[0], timeout_s=180)
            index = 1
        write = self.runner.run(commands[index], timeout_s=600)
        verify = self.runner.run(commands[index + 1], timeout_s=600)
        return ProvisionResult(
            identity=identity,
            firmware_sha256=firmware_sha,
            firmware_size=firmware_size,
            flash_offset=offset,
            backup_sha256=backup_sha,
            erased=erase_first,
            write=write,
            verify=verify,
        )

    def restore(
        self,
        device: SerialDevice,
        backup_ref: ArtifactRef,
        *,
        expected_mac: str,
    ) -> RestoreResult:
        """Restore and verify an immutable full-flash backup."""

        identity = self.identify(device, expected_mac=expected_mac)
        backup_path = Path(backup_ref.absolute_path).resolve(strict=True)
        if not backup_path.is_relative_to(self.store.root):
            raise SafetyError("restore backup is outside the artifact store")
        backup_sha, backup_size = _sha256_file(backup_path)
        if (
            backup_sha != backup_ref.sha256
            or backup_size != backup_ref.size
            or backup_size <= 0
        ):
            raise VerificationError("restore backup artifact failed verification")
        if (
            identity.flash_size_bytes is not None
            and identity.flash_size_bytes != backup_size
        ):
            raise VerificationError(
                "restore backup size does not match the connected ESP32 flash"
            )
        commands = self.plan_provision(
            device,
            backup_path,
            offset=0,
            erase_first=True,
        )
        self.runner.run(commands[0], timeout_s=180)
        write = self.runner.run(commands[1], timeout_s=900)
        verify = self.runner.run(commands[2], timeout_s=900)
        return RestoreResult(
            identity=identity,
            backup_sha256=backup_sha,
            backup_size=backup_size,
            erased=True,
            write=write,
            verify=verify,
        )
