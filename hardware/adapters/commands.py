"""Strict subprocess execution without a shell or privilege escalation."""

from __future__ import annotations

from collections.abc import Iterable, Mapping, Sequence
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

from .models import (
    CommandExecutionError,
    CommandNotAllowedError,
    CommandResult,
    SafetyError,
)


_ENV_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
_PRIVILEGE_TOOLS = {"sudo", "su", "doas", "pkexec"}


class SubprocessRunner:
    """Execute only configured executables with ``shell=False``."""

    def __init__(
        self,
        allowed_executables: Iterable[str | os.PathLike[str]],
        *,
        cwd_root: str | os.PathLike[str] | None = None,
        base_env: Mapping[str, str] | None = None,
        dry_run: bool = False,
        max_timeout_s: float = 900,
        max_output_bytes: int = 2 * 1024 * 1024,
    ) -> None:
        resolved: set[Path] = set()
        for executable in allowed_executables:
            result = self._find_executable(os.fspath(executable))
            if result is None:
                raise FileNotFoundError(f"allowed executable not found: {executable}")
            if result.name in _PRIVILEGE_TOOLS:
                raise CommandNotAllowedError(
                    f"privilege escalation command is never allowed: {result.name}"
                )
            resolved.add(result)
        if not resolved:
            raise ValueError("at least one allowed executable is required")
        self.allowed_executables = frozenset(resolved)
        self.cwd_root = (
            Path(cwd_root).expanduser().resolve() if cwd_root is not None else None
        )
        self.base_env = dict(os.environ if base_env is None else base_env)
        self.dry_run = dry_run
        self.max_timeout_s = max_timeout_s
        self.max_output_bytes = max_output_bytes

    @staticmethod
    def _find_executable(value: str) -> Path | None:
        if not value or "\x00" in value:
            return None
        found = value if os.sep in value else shutil.which(value)
        if found is None:
            return None
        path = Path(found).expanduser().resolve()
        return path if path.is_file() else None

    def _validate_argv(self, argv: Sequence[str]) -> tuple[Path, tuple[str, ...]]:
        if isinstance(argv, (str, bytes)) or not argv:
            raise CommandNotAllowedError("argv must be a non-empty sequence")
        values: list[str] = []
        for item in argv:
            if not isinstance(item, str) or "\x00" in item:
                raise CommandNotAllowedError("command arguments must be NUL-free strings")
            values.append(item)
        executable = self._find_executable(values[0])
        if executable is None or executable not in self.allowed_executables:
            raise CommandNotAllowedError(f"executable is not allowed: {values[0]!r}")
        if executable.name in _PRIVILEGE_TOOLS:
            raise CommandNotAllowedError("privilege escalation is never allowed")
        values[0] = str(executable)
        return executable, tuple(values)

    def _validate_cwd(self, cwd: str | os.PathLike[str] | None) -> Path | None:
        if cwd is None:
            return self.cwd_root
        result = Path(cwd).expanduser().resolve()
        if self.cwd_root is not None and not result.is_relative_to(self.cwd_root):
            raise SafetyError("command cwd escapes the configured workspace")
        return result

    @staticmethod
    def _validate_env(env: Mapping[str, str] | None) -> dict[str, str]:
        result: dict[str, str] = {}
        for key, value in (env or {}).items():
            if (
                not isinstance(key, str)
                or _ENV_NAME.fullmatch(key) is None
                or not isinstance(value, str)
                or "\x00" in value
            ):
                raise SafetyError(f"invalid subprocess environment entry: {key!r}")
            result[key] = value
        return result

    def run(
        self,
        argv: Sequence[str],
        *,
        timeout_s: float = 60,
        cwd: str | os.PathLike[str] | None = None,
        env: Mapping[str, str] | None = None,
        stdin: bytes | None = None,
        check: bool = True,
        redact_indices: Iterable[int] = (),
    ) -> CommandResult:
        _, validated = self._validate_argv(argv)
        if timeout_s <= 0 or timeout_s > self.max_timeout_s:
            raise SafetyError(
                f"timeout must be in (0, {self.max_timeout_s}] seconds"
            )
        command_cwd = self._validate_cwd(cwd)
        command_env = dict(self.base_env)
        command_env.update(self._validate_env(env))
        redacted = list(validated)
        for index in redact_indices:
            if 0 <= index < len(redacted):
                redacted[index] = "<redacted>"
        public_argv = tuple(redacted)
        if self.dry_run:
            return CommandResult(public_argv, 0, "", "", 0, dry_run=True)

        started = time.monotonic()
        try:
            completed = subprocess.run(
                validated,
                input=stdin,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                cwd=command_cwd,
                env=command_env,
                shell=False,
                timeout=timeout_s,
                check=False,
            )
            result = CommandResult(
                public_argv,
                completed.returncode,
                self._decode(completed.stdout),
                self._decode(completed.stderr),
                time.monotonic() - started,
            )
        except subprocess.TimeoutExpired as error:
            result = CommandResult(
                public_argv,
                124,
                self._decode(error.stdout or b""),
                self._decode(error.stderr or b""),
                time.monotonic() - started,
                timed_out=True,
            )
        if check and not result.ok:
            raise CommandExecutionError(result)
        return result

    def _decode(self, value: bytes) -> str:
        if len(value) > self.max_output_bytes:
            value = value[: self.max_output_bytes] + b"\n[output truncated]"
        return value.decode("utf-8", errors="replace")
