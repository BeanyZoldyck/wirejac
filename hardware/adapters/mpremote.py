"""Locked mpremote deployment and serial verification operations."""

from __future__ import annotations

from collections.abc import Callable, Mapping, Sequence
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import sys
import time
from typing import Any

from .commands import SubprocessRunner
from .models import (
    DeviceLockError,
    DeviceSelectionError,
    RemoteHashResult,
    ResetResult,
    SafetyError,
    SerialCaptureResult,
    SerialDevice,
    SerialEvent,
    StageResult,
    StagedFile,
    VerificationError,
)


SerialFactory = Callable[..., Any]
_SHA_PATTERN = re.compile(r"\b([0-9a-fA-F]{64})\b")


def _sha256_file(path: Path) -> tuple[str, int]:
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
            size += len(chunk)
    return digest.hexdigest(), size


class DeviceFileLock:
    """An advisory, process-wide lock keyed by stable device identity."""

    def __init__(
        self,
        lock_dir: str | os.PathLike[str],
        device_key: str,
        *,
        timeout_s: float = 5,
    ) -> None:
        self.lock_dir = Path(lock_dir).expanduser().resolve()
        self.key = hashlib.sha256(device_key.encode("utf-8")).hexdigest()
        self.timeout_s = timeout_s
        self._file: Any | None = None

    def __enter__(self) -> DeviceFileLock:
        self.lock_dir.mkdir(parents=True, exist_ok=True)
        path = self.lock_dir / f"{self.key}.lock"
        self._file = path.open("a+", encoding="ascii")
        deadline = time.monotonic() + self.timeout_s
        while True:
            try:
                fcntl.flock(self._file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    self._file.close()
                    self._file = None
                    raise DeviceLockError("device is busy with another WireJac operation")
                time.sleep(0.05)
        self._file.seek(0)
        self._file.truncate()
        self._file.write(str(os.getpid()))
        self._file.flush()
        return self

    def __exit__(self, *_: object) -> None:
        if self._file is not None:
            fcntl.flock(self._file.fileno(), fcntl.LOCK_UN)
            self._file.close()
            self._file = None


class MpremoteAdapter:
    """Stage, verify, reset, and observe MicroPython on an explicit device."""

    def __init__(
        self,
        runner: SubprocessRunner,
        lock_dir: str | os.PathLike[str],
        *,
        command_prefix: Sequence[str] | None = None,
        serial_factory: SerialFactory | None = None,
        require_stable_symlink: bool = True,
        lock_timeout_s: float = 5,
    ) -> None:
        self.runner = runner
        self.lock_dir = Path(lock_dir).expanduser().resolve()
        self.command_prefix = tuple(
            command_prefix or (sys.executable, "-m", "mpremote")
        )
        if not self.command_prefix:
            raise ValueError("mpremote command prefix cannot be empty")
        self.serial_factory = serial_factory
        self.require_stable_symlink = require_stable_symlink
        self.lock_timeout_s = lock_timeout_s

    def _port(self, device: SerialDevice) -> str:
        stable = Path(device.stable_path)
        if not stable.is_absolute():
            raise DeviceSelectionError("device path must be absolute")
        if self.require_stable_symlink:
            if not stable.is_symlink():
                raise DeviceSelectionError(
                    "physical operations require a stable serial symlink"
                )
            if Path(os.path.realpath(stable)) != Path(device.target_path).resolve(
                strict=False
            ):
                raise DeviceSelectionError("stable device link target changed")
        if not device.accessible:
            raise DeviceSelectionError(
                f"device is not accessible: {device.access_error or 'unknown error'}"
            )
        return device.stable_path

    def _locked(self, device: SerialDevice) -> DeviceFileLock:
        port = self._port(device)
        return DeviceFileLock(
            self.lock_dir, port, timeout_s=self.lock_timeout_s
        )

    def _command(self, device: SerialDevice, *arguments: str) -> tuple[str, ...]:
        return self.command_prefix + ("connect", self._port(device), *arguments)

    @staticmethod
    def _remote_path(value: str, *, allow_root: bool = False) -> str:
        if not value or "\x00" in value or "\\" in value:
            raise SafetyError(f"invalid remote path: {value!r}")
        path = PurePosixPath(value)
        if not path.is_absolute() or ".." in path.parts:
            raise SafetyError("remote paths must be clean absolute POSIX paths")
        normalized = str(path)
        if normalized == "/" and not allow_root:
            raise SafetyError("remote root path is not valid for this operation")
        return normalized

    @staticmethod
    def _mkdir_script(directories: Sequence[str]) -> str:
        quoted = repr(tuple(directories))
        return (
            "import os\n"
            f"for _wirejac_dir in {quoted}:\n"
            "    try:\n"
            "        os.mkdir(_wirejac_dir)\n"
            "    except OSError:\n"
            "        pass\n"
        )

    @classmethod
    def _parent_directories(cls, paths: Sequence[str]) -> tuple[str, ...]:
        result: set[str] = set()
        for value in paths:
            parent = PurePosixPath(value).parent
            chain: list[str] = []
            while str(parent) != "/":
                chain.append(str(parent))
                parent = parent.parent
            result.update(chain)
        return tuple(sorted(result, key=lambda item: (item.count("/"), item)))

    def plan_stage_files(
        self,
        device: SerialDevice,
        files: Mapping[str, str | os.PathLike[str]],
        *,
        remote_root: str,
    ) -> tuple[tuple[str, ...], ...]:
        root = self._remote_path(remote_root, allow_root=True)
        resolved: list[tuple[str, Path]] = []
        for remote_relative, local_value in files.items():
            relative = PurePosixPath(remote_relative)
            if (
                relative.is_absolute()
                or not relative.parts
                or any(part in {"", ".", ".."} for part in relative.parts)
            ):
                raise SafetyError(
                    f"staged filename must be a clean relative path: {remote_relative!r}"
                )
            local = Path(local_value).expanduser().resolve(strict=True)
            if not local.is_file():
                raise SafetyError(f"staged source is not a regular file: {local}")
            remote = self._remote_path(str(PurePosixPath(root) / relative))
            resolved.append((remote, local))
        remote_paths = [item[0] for item in resolved]
        commands: list[tuple[str, ...]] = []
        directories = self._parent_directories(remote_paths)
        if directories:
            commands.append(
                self._command(device, "exec", self._mkdir_script(directories))
            )
        for remote, local in sorted(resolved):
            commands.append(
                self._command(device, "fs", "cp", str(local), f":{remote}")
            )
            commands.append(
                self._command(device, "fs", "sha256sum", f":{remote}")
            )
        return tuple(commands)

    def stage_files(
        self,
        device: SerialDevice,
        files: Mapping[str, str | os.PathLike[str]],
        *,
        remote_root: str,
    ) -> StageResult:
        root = self._remote_path(remote_root, allow_root=True)
        expected: list[tuple[str, Path, str, int]] = []
        for relative, source in files.items():
            local = Path(source).expanduser().resolve(strict=True)
            remote = self._remote_path(str(PurePosixPath(root) / relative))
            sha256, size = _sha256_file(local)
            expected.append((remote, local, sha256, size))
        commands = self.plan_stage_files(device, files, remote_root=root)
        results = []
        hashes: dict[str, str] = {}
        with self._locked(device):
            command_index = 0
            if commands and "exec" in commands[0]:
                results.append(self.runner.run(commands[0], timeout_s=30))
                command_index = 1
            while command_index < len(commands):
                copy_result = self.runner.run(commands[command_index], timeout_s=120)
                hash_result = self.runner.run(
                    commands[command_index + 1], timeout_s=30
                )
                results.extend((copy_result, hash_result))
                match = _SHA_PATTERN.search(hash_result.stdout + hash_result.stderr)
                if match is None:
                    raise VerificationError("mpremote did not return a SHA-256")
                remote = commands[command_index + 1][-1][1:]
                hashes[remote] = match.group(1).lower()
                command_index += 2

        staged: list[StagedFile] = []
        for remote, local, sha256, size in sorted(expected):
            if hashes.get(remote) != sha256:
                raise VerificationError(f"remote hash mismatch for {remote}")
            staged.append(StagedFile(str(local), remote, sha256, size))
        return StageResult(device.stable_path, root, tuple(staged), tuple(results))

    def hash_remote(
        self,
        device: SerialDevice,
        remote_path: str,
    ) -> RemoteHashResult:
        remote = self._remote_path(remote_path)
        command = self._command(device, "fs", "sha256sum", f":{remote}")
        with self._locked(device):
            result = self.runner.run(command, timeout_s=30)
        match = _SHA_PATTERN.search(result.stdout + result.stderr)
        if match is None:
            raise VerificationError("mpremote did not return a SHA-256")
        return RemoteHashResult(remote, match.group(1).lower(), result)

    def read_text(
        self,
        device: SerialDevice,
        remote_path: str,
        *,
        missing_ok: bool = False,
        max_bytes: int = 4096,
    ) -> str | None:
        remote = self._remote_path(remote_path)
        if max_bytes <= 0 or max_bytes > 1024 * 1024:
            raise SafetyError("remote text limit must be in (0, 1 MiB]")
        command = self._command(device, "fs", "cat", f":{remote}")
        with self._locked(device):
            result = self.runner.run(command, timeout_s=30, check=not missing_ok)
        if not result.ok:
            return None
        encoded = result.stdout.encode("utf-8")
        if len(encoded) > max_bytes:
            raise VerificationError(f"remote file exceeds {max_bytes} bytes: {remote}")
        return result.stdout

    def exec_code(
        self,
        device: SerialDevice,
        source: str,
        *,
        timeout_s: float = 30,
        check: bool = True,
    ):
        if (
            not source
            or len(source.encode("utf-8")) > 16 * 1024
            or "\x00" in source
        ):
            raise SafetyError("MicroPython probe source is invalid")
        command = self._command(device, "exec", source)
        with self._locked(device):
            return self.runner.run(command, timeout_s=timeout_s, check=check)

    def run_local(
        self,
        device: SerialDevice,
        local_script: str | os.PathLike[str],
        *,
        timeout_s: float = 60,
    ):
        script = Path(local_script).expanduser().resolve(strict=True)
        if not script.is_file():
            raise SafetyError("MicroPython test script must be a regular file")
        command = self._command(device, "run", str(script))
        with self._locked(device):
            return self.runner.run(command, timeout_s=timeout_s)

    def hard_reset(self, device: SerialDevice) -> ResetResult:
        command = self._command(device, "reset")
        with self._locked(device):
            result = self.runner.run(command, timeout_s=30)
        return ResetResult(device.stable_path, result)

    def capture_serial(
        self,
        device: SerialDevice,
        *,
        duration_s: float,
        expected_events: Sequence[str] = (),
        baudrate: int = 115200,
        stop_when_expected: bool = True,
    ) -> SerialCaptureResult:
        if duration_s <= 0 or duration_s > 900:
            raise SafetyError("serial capture duration must be in (0, 900] seconds")
        if baudrate <= 0:
            raise SafetyError("serial baudrate must be positive")
        factory = self.serial_factory
        if factory is None:
            try:
                import serial
            except ImportError as error:
                raise VerificationError("pyserial is unavailable") from error
            factory = serial.Serial

        events: list[SerialEvent] = []
        observed: list[str] = []
        expected = tuple(expected_events)
        deadline = time.monotonic() + duration_s
        with self._locked(device):
            serial_port = factory(
                port=device.stable_path,
                baudrate=baudrate,
                timeout=min(0.2, duration_s),
            )
            try:
                while time.monotonic() < deadline:
                    raw = serial_port.readline()
                    if not raw:
                        continue
                    text = (
                        raw.decode("utf-8", errors="replace")
                        if isinstance(raw, bytes)
                        else str(raw)
                    ).strip()
                    payload = None
                    try:
                        decoded = json.loads(text)
                        if isinstance(decoded, dict):
                            payload = decoded
                    except (TypeError, ValueError):
                        pass
                    event_name = payload.get("event") if payload is not None else None
                    if isinstance(event_name, str) and event_name not in observed:
                        observed.append(event_name)
                    for required in expected:
                        if required in text and required not in observed:
                            observed.append(required)
                    events.append(SerialEvent(time.monotonic(), text, payload))
                    if (
                        stop_when_expected
                        and expected
                        and all(item in observed for item in expected)
                    ):
                        break
            finally:
                with contextlib.suppress(Exception):
                    serial_port.close()
        success = all(item in observed for item in expected)
        return SerialCaptureResult(
            port=device.stable_path,
            events=tuple(events),
            expected_events=expected,
            observed_events=tuple(observed),
            timed_out=bool(expected) and not success,
        )
