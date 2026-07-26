from __future__ import annotations

from collections import deque
from pathlib import Path
import os

import pytest

from hardware.adapters import (
    DeviceFileLock,
    DeviceLockError,
    MpremoteAdapter,
    SerialDevice,
    SubprocessRunner,
)


FAKE_MPREMOTE = r"""
import hashlib
import os
import pathlib
import shutil
import sys

args = sys.argv[1:]
root = pathlib.Path(os.environ["FAKE_REMOTE_ROOT"])
root.mkdir(parents=True, exist_ok=True)
if "fs" in args:
    index = args.index("fs")
    action = args[index + 1]
    if action == "cp":
        source = pathlib.Path(args[index + 2])
        target = root / args[index + 3].lstrip(":/")
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
    elif action == "sha256sum":
        target = root / args[index + 2].lstrip(":/")
        print(hashlib.sha256(target.read_bytes()).hexdigest(), args[index + 2])
elif "reset" in args:
    print("reset OK")
"""


def make_device(tmp_path: Path) -> SerialDevice:
    target = tmp_path / "ttyUSB0"
    target.write_bytes(b"")
    by_id = tmp_path / "by-id"
    by_id.mkdir(exist_ok=True)
    stable = by_id / "usb-CP2102"
    stable.symlink_to(target)
    return SerialDevice(str(stable), str(target), accessible=True)


def test_stage_hash_and_reset_are_locked_and_verified(
    tmp_path: Path, executable
) -> None:
    fake = executable("fake-mpremote", FAKE_MPREMOTE)
    remote = tmp_path / "remote"
    env = dict(os.environ)
    env["FAKE_REMOTE_ROOT"] = str(remote)
    runner = SubprocessRunner([fake], base_env=env)
    adapter = MpremoteAdapter(
        runner,
        tmp_path / "locks",
        command_prefix=(str(fake),),
    )
    device = make_device(tmp_path)
    main = tmp_path / "main.py"
    driver = tmp_path / "mpu6050.py"
    main.write_text("print('ready')\n", encoding="utf-8")
    driver.write_text("class MPU6050: pass\n", encoding="utf-8")

    staged = adapter.stage_files(
        device,
        {"main.py": main, "lib/mpu6050.py": driver},
        remote_root="/releases/candidate",
    )
    remote_hash = adapter.hash_remote(
        device, "/releases/candidate/main.py"
    )
    reset = adapter.hard_reset(device)

    assert len(staged.files) == 2
    assert all(item.sha256 for item in staged.files)
    assert remote_hash.sha256 == next(
        item.sha256 for item in staged.files if item.remote_path.endswith("main.py")
    )
    assert reset.command.ok


def test_device_file_lock_rejects_concurrent_owner(tmp_path: Path) -> None:
    first = DeviceFileLock(tmp_path, "device-one")
    second = DeviceFileLock(tmp_path, "device-one", timeout_s=0.05)
    first.__enter__()
    try:
        with pytest.raises(DeviceLockError):
            second.__enter__()
    finally:
        first.__exit__(None, None, None)


class FakeSerial:
    def __init__(self, lines: list[bytes]) -> None:
        self.lines = deque(lines)
        self.closed = False

    def readline(self) -> bytes:
        return self.lines.popleft() if self.lines else b""

    def close(self) -> None:
        self.closed = True


def test_serial_capture_parses_jsonl_events(tmp_path: Path, executable) -> None:
    fake = executable("fake-mpremote", FAKE_MPREMOTE)
    env = dict(os.environ)
    env["FAKE_REMOTE_ROOT"] = str(tmp_path / "remote")
    serial_port = FakeSerial(
        [
            b'{"event":"wirejac.ready"}\n',
            b'{"event":"snatch.detected","score":0.91}\n',
        ]
    )
    adapter = MpremoteAdapter(
        SubprocessRunner([fake], base_env=env),
        tmp_path / "locks",
        command_prefix=(str(fake),),
        serial_factory=lambda **_: serial_port,
    )

    captured = adapter.capture_serial(
        make_device(tmp_path),
        duration_s=0.5,
        expected_events=("wirejac.ready", "snatch.detected"),
    )

    assert captured.success
    assert len(captured.events) == 2
    assert captured.events[1].payload == {
        "event": "snatch.detected",
        "score": 0.91,
    }
    assert serial_port.closed
