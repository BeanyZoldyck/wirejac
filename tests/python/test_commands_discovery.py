from __future__ import annotations

from pathlib import Path
import os
from types import SimpleNamespace

import pytest

from hardware.adapters import (
    CommandExecutionError,
    CommandNotAllowedError,
    DeviceDiscovery,
    SafetyError,
    SubprocessRunner,
    discover_capabilities,
)


def test_runner_executes_only_allowlisted_program_without_shell(
    tmp_path: Path, executable
) -> None:
    tool = executable(
        "safe-tool",
        "import sys\nprint('|'.join(sys.argv[1:]))\n",
    )
    runner = SubprocessRunner([tool], cwd_root=tmp_path)

    result = runner.run([str(tool), "hello; touch nope", "$HOME"])

    assert result.ok
    assert result.stdout.strip() == "hello; touch nope|$HOME"
    assert not (tmp_path / "nope").exists()
    with pytest.raises(CommandNotAllowedError):
        runner.run(["/bin/sh", "-c", "true"])


def test_runner_reports_nonzero_timeout_and_cwd_escape(
    tmp_path: Path, executable
) -> None:
    tool = executable(
        "controlled",
        "import sys, time\n"
        "if sys.argv[1] == 'fail': raise SystemExit(7)\n"
        "time.sleep(2)\n",
    )
    runner = SubprocessRunner([tool], cwd_root=tmp_path, max_timeout_s=3)

    with pytest.raises(CommandExecutionError) as failed:
        runner.run([str(tool), "fail"], timeout_s=1)
    assert failed.value.result.returncode == 7
    timed_out = runner.run([str(tool), "sleep"], timeout_s=0.05, check=False)
    assert timed_out.timed_out
    with pytest.raises(SafetyError):
        runner.run([str(tool), "sleep"], cwd=tmp_path.parent)


def test_runner_dry_run_has_no_side_effect(tmp_path: Path, executable) -> None:
    marker = tmp_path / "marker"
    tool = executable("writer", f"open({str(marker)!r}, 'w').write('bad')\n")
    runner = SubprocessRunner([tool], dry_run=True)

    result = runner.run([str(tool)])

    assert result.dry_run
    assert not marker.exists()


def test_stable_device_discovery_reports_metadata_and_access(
    tmp_path: Path,
) -> None:
    by_id = tmp_path / "by-id"
    by_id.mkdir()
    target = tmp_path / "ttyUSB0"
    target.write_bytes(b"")
    stable = by_id / "usb-Silicon_Labs_CP2102-01"
    stable.symlink_to(target)
    broken = by_id / "usb-broken"
    broken.symlink_to(tmp_path / "missing")
    port = SimpleNamespace(
        device=str(target),
        vid=0x10C4,
        pid=0xEA60,
        serial_number="01",
        manufacturer="Silicon Labs",
        product="CP2102",
    )
    discovery = DeviceDiscovery(by_id, port_provider=lambda: [port])

    devices = discovery.list_devices()

    assert len(devices) == 2
    found = discovery.get(str(stable))
    assert found is not None
    assert found.accessible
    assert found.vid == 0x10C4
    assert found.target_path == str(target)
    assert next(item for item in devices if item.stable_path.endswith("usb-broken")).access_error == "missing_target"


def test_capability_report_never_exposes_wokwi_token(tmp_path: Path) -> None:
    discovery = DeviceDiscovery(tmp_path, port_provider=lambda: ())

    report = discover_capabilities(
        discovery,
        environ={"WOKWI_CLI_TOKEN": "super-secret-token"},
    )

    token = report.get("wokwi_token")
    assert token is not None and token.available
    assert "super-secret-token" not in repr(report)
