"""Typed, serializable results shared by WireJac host adapters."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Mapping


class AdapterError(RuntimeError):
    """Base error for an adapter failure."""


class SafetyError(AdapterError):
    """Raised when an operation violates a host safety boundary."""


class ArtifactConflictError(AdapterError):
    """Raised when immutable artifact content would be replaced."""


class CommandNotAllowedError(SafetyError):
    """Raised when a subprocess is outside the configured command policy."""


class CommandExecutionError(AdapterError):
    """Raised when an allowed subprocess fails."""

    def __init__(self, result: CommandResult):
        self.result = result
        super().__init__(
            f"command failed with exit code {result.returncode}: "
            f"{' '.join(result.argv)}"
        )


class CapabilityUnavailableError(AdapterError):
    """Raised when an optional host capability is unavailable."""


class DeviceSelectionError(SafetyError):
    """Raised when a physical device was not selected safely."""


class DeviceLockError(AdapterError):
    """Raised when another operation owns a device lock."""


class IdentityMismatchError(SafetyError):
    """Raised when a connected device does not match its expected identity."""


class VerificationError(AdapterError):
    """Raised when generated or deployed content cannot be verified."""


@dataclass(frozen=True, slots=True)
class ArtifactRef:
    relative_path: str
    absolute_path: str
    sha256: str
    size: int
    created: bool


@dataclass(frozen=True, slots=True)
class CommandResult:
    argv: tuple[str, ...]
    returncode: int
    stdout: str
    stderr: str
    duration_s: float
    timed_out: bool = False
    dry_run: bool = False

    @property
    def ok(self) -> bool:
        return self.returncode == 0 and not self.timed_out


@dataclass(frozen=True, slots=True)
class Capability:
    name: str
    available: bool
    detail: str | None = None
    version: str | None = None
    executable: str | None = None


@dataclass(frozen=True, slots=True)
class SerialDevice:
    stable_path: str
    target_path: str
    accessible: bool
    access_error: str | None = None
    vid: int | None = None
    pid: int | None = None
    serial_number: str | None = None
    manufacturer: str | None = None
    product: str | None = None


@dataclass(frozen=True, slots=True)
class CapabilityReport:
    capabilities: tuple[Capability, ...]
    devices: tuple[SerialDevice, ...]

    def get(self, name: str) -> Capability | None:
        return next((item for item in self.capabilities if item.name == name), None)


@dataclass(frozen=True, slots=True)
class DeviceIdentity:
    port: str
    chip: str
    revision: str | None
    mac: str
    flash_size_bytes: int | None
    chip_id_output: str = field(repr=False)
    flash_id_output: str = field(repr=False)


@dataclass(frozen=True, slots=True)
class FlashBackupResult:
    identity: DeviceIdentity
    artifact: ArtifactRef
    command: CommandResult


@dataclass(frozen=True, slots=True)
class ProvisionResult:
    identity: DeviceIdentity
    firmware_sha256: str
    firmware_size: int
    flash_offset: int
    backup_sha256: str
    erased: bool
    write: CommandResult
    verify: CommandResult


@dataclass(frozen=True, slots=True)
class RestoreResult:
    identity: DeviceIdentity
    backup_sha256: str
    backup_size: int
    erased: bool
    write: CommandResult
    verify: CommandResult


@dataclass(frozen=True, slots=True)
class RemoteHashResult:
    remote_path: str
    sha256: str
    command: CommandResult


@dataclass(frozen=True, slots=True)
class StagedFile:
    local_path: str
    remote_path: str
    sha256: str
    size: int


@dataclass(frozen=True, slots=True)
class StageResult:
    port: str
    remote_root: str
    files: tuple[StagedFile, ...]
    commands: tuple[CommandResult, ...]


@dataclass(frozen=True, slots=True)
class ResetResult:
    port: str
    command: CommandResult


@dataclass(frozen=True, slots=True)
class SerialEvent:
    monotonic_s: float
    text: str
    payload: Mapping[str, Any] | None = None


@dataclass(frozen=True, slots=True)
class SerialCaptureResult:
    port: str
    events: tuple[SerialEvent, ...]
    expected_events: tuple[str, ...]
    observed_events: tuple[str, ...]
    timed_out: bool

    @property
    def success(self) -> bool:
        return all(item in self.observed_events for item in self.expected_events)


@dataclass(frozen=True, slots=True)
class WokwiControl:
    at_seconds: float
    part: str
    control: str
    value: int | bool | float


@dataclass(frozen=True, slots=True)
class WokwiSimulationResult:
    server_info: Mapping[str, Any]
    serial_lines: tuple[str, ...]
    expected_events: tuple[str, ...]
    observed_events: tuple[str, ...]
    controls_applied: tuple[WokwiControl, ...]

    @property
    def success(self) -> bool:
        return all(item in self.observed_events for item in self.expected_events)


@dataclass(frozen=True, slots=True)
class LittleFSProfile:
    block_size: int
    block_count: int
    read_size: int = 16
    prog_size: int = 16
    cache_size: int = 64
    lookahead_size: int = 16

    @property
    def image_size(self) -> int:
        return self.block_size * self.block_count


@dataclass(frozen=True, slots=True)
class MicroPythonImageResult:
    artifact: ArtifactRef
    files: tuple[str, ...]
    filesystem: str
    filesystem_offset: int | None = None
    flash_size_bytes: int | None = None
