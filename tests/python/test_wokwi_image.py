from __future__ import annotations

from pathlib import Path

import pytest

from hardware.adapters import (
    ArtifactStore,
    CapabilityUnavailableError,
    LittleFSProfile,
    MicroPythonImageBuilder,
    SafetyError,
    WokwiAdapter,
    WokwiControl,
)


class FakeWokwiClient:
    def __init__(self, token: str) -> None:
        assert token == "test-token"
        self.uploads: dict[str, bytes] = {}
        self.callback = None
        self.controls = []
        self.disconnected = False

    def connect(self):
        return {"version": "fake"}

    def upload(self, name: str, content: bytes) -> None:
        self.uploads[name] = content

    def serial_monitor(self, callback) -> None:
        self.callback = callback

    def start_simulation(self, **_) -> None:
        self.callback(b'{"event":"wirejac.ready"}\n')

    def wait_until_simulation_time(self, seconds: float) -> None:
        if seconds >= 2:
            self.callback(b'{"event":"snatch.detected"}\n')

    def set_control(self, part: str, control: str, value) -> None:
        self.controls.append((part, control, value))

    def pause_simulation(self) -> None:
        pass

    def disconnect(self) -> None:
        self.disconnected = True


def test_wokwi_wrapper_keeps_simulation_in_process(tmp_path: Path) -> None:
    firmware = tmp_path / "firmware.bin"
    firmware.write_bytes(b"firmware")
    clients: list[FakeWokwiClient] = []

    def factory(token: str) -> FakeWokwiClient:
        client = FakeWokwiClient(token)
        clients.append(client)
        return client

    result = WokwiAdapter(
        "test-token",
        client_factory=factory,
    ).run(
        {"version": 1, "parts": [], "connections": []},
        firmware,
        controls=(WokwiControl(1, "imu1", "accelX", 8.5),),
        run_seconds=2,
        expected_events=("wirejac.ready", "snatch.detected"),
    )

    assert result.success
    assert clients[0].uploads["firmware.bin"] == b"firmware"
    assert b'"connections":[]' in clients[0].uploads["diagram.json"]
    assert clients[0].controls == [("imu1", "accelX", 8.5)]
    assert clients[0].disconnected


def test_wokwi_without_token_is_explicitly_unavailable(tmp_path: Path) -> None:
    firmware = tmp_path / "firmware.bin"
    firmware.write_bytes(b"x")
    adapter = WokwiAdapter(token=None, client_factory=lambda _: None)
    adapter._token = None

    with pytest.raises(CapabilityUnavailableError):
        adapter.run({"version": 1}, firmware)


def test_littlefs_and_merged_flash_images_are_deterministic(tmp_path: Path) -> None:
    pytest.importorskip("littlefs")
    store = ArtifactStore(tmp_path / "workspace")
    builder = MicroPythonImageBuilder(store)
    filesystem = builder.build_littlefs_image(
        {
            "main.py": b"print('ready')\n",
            "lib/driver.py": b"VALUE = 1\n",
        },
        "images/filesystem.bin",
        profile=LittleFSProfile(block_size=4096, block_count=16),
    )
    base = tmp_path / "micropython.bin"
    base.write_bytes(b"MPY")
    merged = builder.merge_flash_image(
        base,
        filesystem.artifact.absolute_path,
        "images/wokwi-flash.bin",
        base_flash_offset=0x1000,
        filesystem_flash_offset=0x10000,
        flash_size_bytes=0x20000,
    )

    image = Path(merged.artifact.absolute_path).read_bytes()
    assert filesystem.artifact.size == 4096 * 16
    assert filesystem.files == ("lib/driver.py", "main.py")
    assert image[0x1000:0x1003] == b"MPY"
    assert image[0x10000:0x20000] == Path(
        filesystem.artifact.absolute_path
    ).read_bytes()
    assert image[:0x1000] == b"\xff" * 0x1000


def test_merge_rejects_overlapping_regions(tmp_path: Path) -> None:
    store = ArtifactStore(tmp_path / "workspace")
    builder = MicroPythonImageBuilder(store)
    base = tmp_path / "base.bin"
    filesystem = tmp_path / "filesystem.bin"
    base.write_bytes(b"A" * 100)
    filesystem.write_bytes(b"B" * 100)

    with pytest.raises(SafetyError):
        builder.merge_flash_image(
            base,
            filesystem,
            "bad.bin",
            base_flash_offset=0,
            filesystem_flash_offset=50,
            flash_size_bytes=200,
        )
