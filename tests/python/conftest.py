from __future__ import annotations

from pathlib import Path
import stat
import sys

import pytest


ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))


@pytest.fixture
def executable(tmp_path: Path):
    def create(name: str, source: str) -> Path:
        path = tmp_path / name
        path.write_text("#!/usr/bin/python3\n" + source, encoding="utf-8")
        path.chmod(path.stat().st_mode | stat.S_IXUSR)
        return path

    return create
