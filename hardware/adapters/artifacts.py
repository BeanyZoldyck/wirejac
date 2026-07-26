"""Safe, atomic artifact persistence below a configured workspace."""

from __future__ import annotations

import contextlib
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import tempfile
from collections.abc import Iterator, Mapping
from typing import Any

from .models import ArtifactConflictError, ArtifactRef, SafetyError


class ArtifactStore:
    """An immutable-by-default artifact store constrained to one workspace."""

    def __init__(
        self,
        workspace_root: str | os.PathLike[str],
        store_dir: str = "artifacts",
    ) -> None:
        workspace = Path(workspace_root).expanduser().resolve()
        workspace.mkdir(parents=True, exist_ok=True)
        relative_store = self._validate_relative(store_dir)
        root = (workspace / relative_store).resolve(strict=False)
        if not root.is_relative_to(workspace):
            raise SafetyError("artifact store must remain below the workspace root")
        root.mkdir(parents=True, exist_ok=True)
        self.workspace_root = workspace
        self.root = root

    @staticmethod
    def _validate_relative(relative_path: str | os.PathLike[str]) -> Path:
        value = os.fspath(relative_path)
        if not value or value == "." or "\x00" in value or "\\" in value:
            raise SafetyError(f"invalid artifact path: {value!r}")
        posix = PurePosixPath(value)
        if posix.is_absolute() or any(part in {"", ".", ".."} for part in posix.parts):
            raise SafetyError(f"artifact path must be a clean relative path: {value!r}")
        return Path(*posix.parts)

    def path_for(self, relative_path: str | os.PathLike[str]) -> Path:
        relative = self._validate_relative(relative_path)
        candidate = self.root / relative
        resolved = candidate.resolve(strict=False)
        if not resolved.is_relative_to(self.root):
            raise SafetyError("artifact path escapes the configured store")
        return resolved

    def _prepare_parent(self, target: Path) -> None:
        target.parent.mkdir(parents=True, exist_ok=True)
        resolved_parent = target.parent.resolve()
        if not resolved_parent.is_relative_to(self.root):
            raise SafetyError("artifact parent resolves outside the configured store")

    @staticmethod
    def _hash_file(path: Path) -> tuple[str, int]:
        digest = hashlib.sha256()
        size = 0
        with path.open("rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(chunk)
                size += len(chunk)
        return digest.hexdigest(), size

    def _existing(
        self,
        target: Path,
        relative_path: str,
        sha256: str,
        size: int,
        overwrite: bool,
    ) -> ArtifactRef | None:
        if not target.exists():
            return None
        if not target.is_file():
            raise ArtifactConflictError(f"artifact target is not a file: {relative_path}")
        existing_sha, existing_size = self._hash_file(target)
        if existing_sha == sha256 and existing_size == size:
            return ArtifactRef(
                relative_path,
                str(target),
                sha256,
                size,
                created=False,
            )
        if not overwrite:
            raise ArtifactConflictError(
                f"immutable artifact already exists with different content: {relative_path}"
            )
        return None

    def put_bytes(
        self,
        relative_path: str,
        content: bytes,
        *,
        overwrite: bool = False,
        mode: int = 0o600,
    ) -> ArtifactRef:
        target = self.path_for(relative_path)
        self._prepare_parent(target)
        sha256 = hashlib.sha256(content).hexdigest()
        existing = self._existing(
            target, relative_path, sha256, len(content), overwrite
        )
        if existing is not None:
            return existing

        fd, temporary_name = tempfile.mkstemp(prefix=".wirejac-", dir=target.parent)
        temporary = Path(temporary_name)
        try:
            with os.fdopen(fd, "wb") as output:
                output.write(content)
                output.flush()
                os.fsync(output.fileno())
            os.chmod(temporary, mode)
            os.replace(temporary, target)
            self._fsync_directory(target.parent)
        finally:
            temporary.unlink(missing_ok=True)
        return ArtifactRef(relative_path, str(target), sha256, len(content), True)

    def put_json(
        self,
        relative_path: str,
        value: Mapping[str, Any] | list[Any],
        *,
        overwrite: bool = False,
    ) -> ArtifactRef:
        encoded = (
            json.dumps(
                value,
                sort_keys=True,
                separators=(",", ":"),
                ensure_ascii=True,
            ).encode("utf-8")
            + b"\n"
        )
        return self.put_bytes(relative_path, encoded, overwrite=overwrite)

    def put_file(
        self,
        relative_path: str,
        source_path: str | os.PathLike[str],
        *,
        overwrite: bool = False,
        mode: int = 0o600,
    ) -> ArtifactRef:
        source = Path(source_path).expanduser().resolve(strict=True)
        if not source.is_file():
            raise SafetyError(f"artifact source is not a regular file: {source}")
        target = self.path_for(relative_path)
        self._prepare_parent(target)
        sha256, size = self._hash_file(source)
        existing = self._existing(target, relative_path, sha256, size, overwrite)
        if existing is not None:
            return existing

        fd, temporary_name = tempfile.mkstemp(prefix=".wirejac-", dir=target.parent)
        temporary = Path(temporary_name)
        try:
            with source.open("rb") as incoming, os.fdopen(fd, "wb") as output:
                shutil.copyfileobj(incoming, output, 1024 * 1024)
                output.flush()
                os.fsync(output.fileno())
            os.chmod(temporary, mode)
            os.replace(temporary, target)
            self._fsync_directory(target.parent)
        finally:
            temporary.unlink(missing_ok=True)
        return ArtifactRef(relative_path, str(target), sha256, size, True)

    def read_bytes(self, relative_path: str) -> bytes:
        path = self.path_for(relative_path)
        if not path.is_file():
            raise FileNotFoundError(path)
        return path.read_bytes()

    @contextlib.contextmanager
    def staging_path(self, *, suffix: str = "") -> Iterator[Path]:
        staging = self.root / ".staging"
        staging.mkdir(parents=True, exist_ok=True)
        fd, name = tempfile.mkstemp(prefix="wirejac-", suffix=suffix, dir=staging)
        os.close(fd)
        path = Path(name)
        path.unlink()
        try:
            yield path
        finally:
            path.unlink(missing_ok=True)

    @staticmethod
    def _fsync_directory(path: Path) -> None:
        try:
            descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        except OSError:
            return
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
