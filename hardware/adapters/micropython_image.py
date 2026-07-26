"""Deterministic MicroPython filesystem and merged-flash image creation."""

from __future__ import annotations

from collections.abc import Mapping
import os
from pathlib import Path, PurePosixPath
from typing import TypeAlias

from .artifacts import ArtifactStore
from .models import (
    CapabilityUnavailableError,
    LittleFSProfile,
    MicroPythonImageResult,
    SafetyError,
)


FileContent: TypeAlias = bytes | str | os.PathLike[str]


class MicroPythonImageBuilder:
    """Build images only from explicit board-profile geometry."""

    def __init__(self, store: ArtifactStore) -> None:
        self.store = store

    @staticmethod
    def _filesystem_path(value: str) -> str:
        if not value or "\x00" in value or "\\" in value:
            raise SafetyError(f"invalid filesystem path: {value!r}")
        path = PurePosixPath(value)
        if path.is_absolute() or any(part in {"", ".", ".."} for part in path.parts):
            raise SafetyError("filesystem entries must use clean relative POSIX paths")
        return str(path)

    @staticmethod
    def _content(value: FileContent) -> bytes:
        if isinstance(value, bytes):
            return value
        source = Path(value).expanduser().resolve(strict=True)
        if not source.is_file():
            raise SafetyError(f"filesystem source is not a regular file: {source}")
        return source.read_bytes()

    @staticmethod
    def _validate_profile(profile: LittleFSProfile) -> None:
        if profile.block_size <= 0 or profile.block_count < 2:
            raise SafetyError("LittleFS block geometry is invalid")
        for name in ("read_size", "prog_size", "cache_size", "lookahead_size"):
            value = getattr(profile, name)
            if value <= 0:
                raise SafetyError(f"LittleFS {name} must be positive")
        if profile.block_size % profile.read_size:
            raise SafetyError("LittleFS read size must divide the block size")
        if profile.block_size % profile.prog_size:
            raise SafetyError("LittleFS program size must divide the block size")
        if profile.lookahead_size % 8:
            raise SafetyError("LittleFS lookahead size must be a multiple of 8")

    def build_littlefs_image(
        self,
        files: Mapping[str, FileContent],
        relative_path: str,
        *,
        profile: LittleFSProfile,
        overwrite: bool = False,
    ) -> MicroPythonImageResult:
        """Build LFS2 data; callers must provide a matching board partition profile."""

        self._validate_profile(profile)
        normalized = {
            self._filesystem_path(path): self._content(content)
            for path, content in files.items()
        }
        try:
            from littlefs import LittleFS, UserContext
        except ImportError as error:
            raise CapabilityUnavailableError("littlefs-python is unavailable") from error

        context = UserContext(buffsize=profile.image_size)
        filesystem = LittleFS(
            context=context,
            mount=False,
            block_size=profile.block_size,
            block_count=profile.block_count,
            read_size=profile.read_size,
            prog_size=profile.prog_size,
            cache_size=profile.cache_size,
            lookahead_size=profile.lookahead_size,
        )
        filesystem.format()
        filesystem.mount()
        directories: set[str] = set()
        for path in normalized:
            parent = PurePosixPath(path).parent
            while str(parent) != ".":
                directories.add(str(parent))
                parent = parent.parent
        for directory in sorted(
            directories, key=lambda item: (item.count("/"), item)
        ):
            filesystem.mkdir(f"/{directory}")
        for path, content in sorted(normalized.items()):
            with filesystem.open(f"/{path}", "wb") as output:
                output.write(content)
        filesystem.unmount()
        artifact = self.store.put_bytes(
            relative_path,
            bytes(context.buffer),
            overwrite=overwrite,
        )
        return MicroPythonImageResult(
            artifact=artifact,
            files=tuple(sorted(normalized)),
            filesystem="littlefs2",
        )

    def merge_flash_image(
        self,
        base_firmware: str | os.PathLike[str],
        filesystem_image: str | os.PathLike[str],
        relative_path: str,
        *,
        base_flash_offset: int,
        filesystem_flash_offset: int,
        flash_size_bytes: int,
        overwrite: bool = False,
    ) -> MicroPythonImageResult:
        """Merge explicit flash regions; no ESP32 partition offsets are guessed."""

        if flash_size_bytes <= 0 or flash_size_bytes > 128 * 1024 * 1024:
            raise SafetyError("flash image size is outside the supported range")
        if base_flash_offset < 0 or filesystem_flash_offset < 0:
            raise SafetyError("flash offsets cannot be negative")
        firmware_path = Path(base_firmware).expanduser().resolve(strict=True)
        filesystem_path = Path(filesystem_image).expanduser().resolve(strict=True)
        if not firmware_path.is_file() or not filesystem_path.is_file():
            raise SafetyError("flash image inputs must be regular files")
        firmware = firmware_path.read_bytes()
        filesystem = filesystem_path.read_bytes()
        firmware_end = base_flash_offset + len(firmware)
        filesystem_end = filesystem_flash_offset + len(filesystem)
        if firmware_end > flash_size_bytes or filesystem_end > flash_size_bytes:
            raise SafetyError("flash region exceeds the configured flash size")
        if not (
            firmware_end <= filesystem_flash_offset
            or filesystem_end <= base_flash_offset
        ):
            raise SafetyError("firmware and filesystem flash regions overlap")

        image = bytearray(b"\xff" * flash_size_bytes)
        image[base_flash_offset:firmware_end] = firmware
        image[filesystem_flash_offset:filesystem_end] = filesystem
        artifact = self.store.put_bytes(
            relative_path,
            bytes(image),
            overwrite=overwrite,
        )
        return MicroPythonImageResult(
            artifact=artifact,
            files=(),
            filesystem="merged-flash",
            filesystem_offset=filesystem_flash_offset,
            flash_size_bytes=flash_size_bytes,
        )
