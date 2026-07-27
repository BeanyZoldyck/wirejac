"""Cooperative pause control for the live USB-to-cloud gyro bridge."""

from __future__ import annotations

import os
from pathlib import Path


def _pause_path() -> Path:
    return Path(
        os.environ.get(
            "WIREJAC_GYRO_BRIDGE_PAUSE_FILE",
            str(Path.home() / ".wirejac" / "gyro-bridge.pause"),
        )
    ).expanduser()


def pause_gyro_bridge() -> None:
    path = _pause_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("paused\n", encoding="utf-8")


def resume_gyro_bridge() -> None:
    _pause_path().unlink(missing_ok=True)


def gyro_bridge_paused() -> bool:
    return _pause_path().exists()
