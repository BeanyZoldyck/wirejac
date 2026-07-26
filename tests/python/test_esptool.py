from __future__ import annotations

from pathlib import Path
import os

import pytest

from hardware.adapters import (
    ArtifactStore,
    EspToolAdapter,
    IdentityMismatchError,
    SerialDevice,
    SubprocessRunner,
)


FAKE_ESPTOOL = r"""
import pathlib
import sys

args = sys.argv[1:]
command = next(
    item for item in ("chip-id", "flash-id", "read-flash", "erase-flash",
                      "write-flash", "verify-flash") if item in args
)
if command == "chip-id":
    print("Chip type: ESP32-D0WDQ6 (revision v1.0)")
    print("MAC: 8c:aa:b5:8b:44:5c")
elif command == "flash-id":
    print("Detected flash size: 4MB")
elif command == "read-flash":
    index = args.index(command)
    size = int(args[index + 2], 0)
    pathlib.Path(args[index + 3]).write_bytes(b"B" * size)
else:
    print(command + " OK")
"""


def make_device(tmp_path: Path) -> SerialDevice:
    target = tmp_path / "ttyUSB0"
    target.write_bytes(b"")
    by_id = tmp_path / "by-id"
    by_id.mkdir()
    stable = by_id / "usb-CP2102"
    stable.symlink_to(target)
    return SerialDevice(str(stable), str(target), accessible=True)


def test_identify_backup_and_provision_use_verified_identity(
    tmp_path: Path, executable
) -> None:
    fake = executable("fake-esptool", FAKE_ESPTOOL)
    store = ArtifactStore(tmp_path / "workspace")
    runner = SubprocessRunner([fake])
    adapter = EspToolAdapter(runner, store, command_prefix=(str(fake),))
    device = make_device(tmp_path)

    identity = adapter.identify(device, expected_mac="8CAA-B58B-445C")
    backup = adapter.backup(
        device,
        "backups/original.bin",
        size_bytes=4 * 1024 * 1024,
        expected_mac=identity.mac,
    )
    firmware = tmp_path / "micropython.bin"
    firmware.write_bytes(b"MPY" * 128)
    provisioned = adapter.provision(
        device,
        firmware,
        backup_ref=backup.artifact,
        expected_mac=identity.mac,
    )
    restored = adapter.restore(
        device,
        backup.artifact,
        expected_mac=identity.mac,
    )

    assert identity.chip == "ESP32-D0WDQ6"
    assert identity.revision == "revision v1.0"
    assert identity.flash_size_bytes == 4 * 1024 * 1024
    assert backup.artifact.size == 4 * 1024 * 1024
    assert provisioned.erased
    assert provisioned.write.ok and provisioned.verify.ok
    assert restored.write.ok and restored.verify.ok
    assert restored.backup_sha256 == backup.artifact.sha256
    assert restored.backup_size == 4 * 1024 * 1024
    assert "--force" not in " ".join(provisioned.write.argv)


def test_identity_mismatch_stops_before_flash(tmp_path: Path, executable) -> None:
    fake = executable("fake-esptool", FAKE_ESPTOOL)
    store = ArtifactStore(tmp_path / "workspace")
    adapter = EspToolAdapter(
        SubprocessRunner([fake]),
        store,
        command_prefix=(str(fake),),
    )

    with pytest.raises(IdentityMismatchError):
        adapter.identify(make_device(tmp_path), expected_mac="00:11:22:33:44:55")
