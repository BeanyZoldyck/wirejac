from __future__ import annotations

import json
from pathlib import Path

import pytest

from hardware.adapters import (
    ArtifactConflictError,
    ArtifactStore,
    SafetyError,
)


def test_atomic_artifacts_are_immutable_and_idempotent(tmp_path: Path) -> None:
    store = ArtifactStore(tmp_path, "generated")

    created = store.put_bytes("job-1/firmware/main.py", b"print('ready')\n")
    repeated = store.put_bytes("job-1/firmware/main.py", b"print('ready')\n")

    assert created.created is True
    assert repeated.created is False
    assert repeated.sha256 == created.sha256
    assert store.read_bytes("job-1/firmware/main.py") == b"print('ready')\n"
    with pytest.raises(ArtifactConflictError):
        store.put_bytes("job-1/firmware/main.py", b"different")


def test_json_is_canonical_and_source_files_are_copied(tmp_path: Path) -> None:
    store = ArtifactStore(tmp_path)
    value = store.put_json("job/spec.json", {"z": 1, "a": [True]})
    source = tmp_path / "source.bin"
    source.write_bytes(b"\x00\x01")
    copied = store.put_file("job/source.bin", source)

    assert Path(value.absolute_path).read_bytes() == b'{"a":[true],"z":1}\n'
    assert copied.size == 2
    assert Path(copied.absolute_path).read_bytes() == b"\x00\x01"


@pytest.mark.parametrize(
    "path",
    ("../escape", "/absolute", "a/../../escape", ".", "a\\b", ""),
)
def test_artifact_paths_cannot_escape(tmp_path: Path, path: str) -> None:
    store = ArtifactStore(tmp_path)
    with pytest.raises(SafetyError):
        store.path_for(path)


def test_symlink_parent_cannot_escape_store(tmp_path: Path) -> None:
    store = ArtifactStore(tmp_path / "workspace")
    outside = tmp_path / "outside"
    outside.mkdir()
    (store.root / "link").symlink_to(outside, target_is_directory=True)

    with pytest.raises(SafetyError):
        store.put_bytes("link/escaped.bin", b"no")
    assert not (outside / "escaped.bin").exists()
