"""Constrained MicroPython bundle compiler used by the Jac generation phase."""

from __future__ import annotations

import ast
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import zipfile


_TEMPLATE_ROOT = Path(__file__).with_name("templates")
_ALLOWED_MODULE_IMPORTS = {"math", "time"}
_ALLOWED_FROM_IMPORTS = {
    "machine": {"I2C", "Pin"},
    "drivers.mpu6050": {"MPU6050"},
    "wirejac_config": {
        "BUILD_ID",
        "COOLDOWN_MS",
        "GYRO_THRESHOLD_DPS",
        "HEARTBEAT_MS",
        "I2C_ADDRESS",
        "INGEST_URL",
        "LINEAR_ACCEL_THRESHOLD_G",
        "PIN_BUTTON",
        "PIN_LED",
        "PIN_SCL",
        "PIN_SDA",
        "SAMPLE_HZ",
        "TRIGGER_WINDOW_MS",
    },
    "wirejac_events": {"emit"},
    "wirejac_http": {"post_json"},
    "wirejac_secrets": {"AUTHORIZATION"},
}
_FORBIDDEN_CALLS = {
    "__import__",
    "bootloader",
    "compile",
    "delattr",
    "eval",
    "exec",
    "getattr",
    "globals",
    "locals",
    "open",
    "reset",
    "setattr",
    "soft_reset",
    "vars",
}
_FORBIDDEN_ATTRIBUTES = {
    "bootloader",
    "deepsleep",
    "freq",
    "lightsleep",
    "mem8",
    "mem16",
    "mem32",
    "remove",
    "reset",
    "rmdir",
    "soft_reset",
    "system",
    "unlink",
    "WDT",
}
_FORBIDDEN_MACHINE_IMPORTS = _FORBIDDEN_ATTRIBUTES
_FORBIDDEN_NAMES = _FORBIDDEN_CALLS | {
    "__builtins__",
    "breakpoint",
    "builtins",
    "dir",
    "help",
    "input",
    "memoryview",
    "object",
    "type",
}
_PIN_CONSTANTS = {"PIN_BUTTON", "PIN_LED", "PIN_SCL", "PIN_SDA"}
_PIN_ATTRIBUTES = {"IN", "OPEN_DRAIN", "OUT", "PULL_DOWN", "PULL_UP"}
_DIRECT_CALL_ONLY = {"I2C", "MPU6050", "Pin", "emit", "post_json"}
_MPU6050_ATTRIBUTES = {"initialize", "read", "who_am_i"}
_MAX_FILE_BYTES = 48 * 1024
_MAX_BUNDLE_BYTES = 256 * 1024


def _template(name: str) -> str:
    return (_TEMPLATE_ROOT / name).read_text(encoding="utf-8")


def reviewed_phone_snatch_app() -> str:
    """Return the reviewed deterministic application used by local fixtures."""
    return _template("app.py.tmpl")


def reviewed_motion_test_app() -> str:
    """Return the reviewed application for button-controlled motion capture."""
    return _template("motion_test_app.py.tmpl")


def _safe_remote_path(path: str) -> str:
    remote = PurePosixPath(path)
    if remote.is_absolute() or ".." in remote.parts or not remote.parts:
        raise ValueError(f"unsafe firmware path: {path}")
    normalized = str(remote)
    if normalized.startswith(".") or "\x00" in normalized:
        raise ValueError(f"unsafe firmware path: {path}")
    return normalized


def _direct_name(call: ast.Call) -> str:
    if isinstance(call.func, ast.Name):
        return call.func.id
    if isinstance(call.func, ast.Attribute):
        return call.func.attr
    return ""


def _is_positional_argument(node: ast.AST, call: ast.Call, index: int) -> bool:
    return len(call.args) > index and call.args[index] is node


def _validate_import(node: ast.Import | ast.ImportFrom) -> list[str]:
    issues: list[str] = []
    if isinstance(node, ast.Import):
        for imported in node.names:
            if imported.name not in _ALLOWED_MODULE_IMPORTS:
                issues.append(
                    f"app.py imports disallowed module '{imported.name}' "
                    f"at line {node.lineno}"
                )
            if imported.asname is not None:
                issues.append(
                    f"app.py aliases imports at line {node.lineno}; aliases are forbidden"
                )
        return issues

    module = node.module or ""
    allowed_names = _ALLOWED_FROM_IMPORTS.get(module)
    if node.level or allowed_names is None:
        return [
            f"app.py imports disallowed module '{module}' at line {node.lineno}"
        ]
    for imported in node.names:
        if imported.name not in allowed_names:
            issues.append(
                f"app.py imports disallowed name '{imported.name}' from "
                f"'{module}' at line {node.lineno}"
            )
        if imported.asname is not None:
            issues.append(
                f"app.py aliases imports at line {node.lineno}; aliases are forbidden"
            )
    return issues


def validate_application(source: str) -> list[str]:
    """Validate agent-authored app code before it can enter a device bundle."""
    issues: list[str] = []
    if len(source.encode("utf-8")) > _MAX_FILE_BYTES:
        issues.append("app.py exceeds the 48 KiB source limit")
        return issues
    if "@@" in source:
        issues.append("app.py contains an unresolved template placeholder")
    try:
        tree = ast.parse(source, filename="app.py")
    except SyntaxError as exc:
        return [f"app.py syntax error at line {exc.lineno}: {exc.msg}"]

    parents = {
        child: parent
        for parent in ast.walk(tree)
        for child in ast.iter_child_nodes(parent)
    }
    mpu6050_names = {
        target.id
        for node in ast.walk(tree)
        if isinstance(node, ast.Assign)
        and isinstance(node.value, ast.Call)
        and _direct_name(node.value) == "MPU6050"
        for target in node.targets
        if isinstance(target, ast.Name)
    }
    has_run = False
    for node in ast.walk(tree):
        if isinstance(node, (ast.Import, ast.ImportFrom)):
            issues.extend(_validate_import(node))
            if isinstance(node, ast.ImportFrom) and node.module == "machine":
                for imported in node.names:
                    if imported.name in _FORBIDDEN_MACHINE_IMPORTS:
                        issues.append(
                            "app.py imports forbidden machine operation "
                            f"'{imported.name}' at line {node.lineno}"
                        )
        elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            if node.name == "run" and isinstance(node, ast.FunctionDef):
                has_run = True
            if node.name in _FORBIDDEN_NAMES or node.name.startswith("__"):
                issues.append(
                    f"app.py defines forbidden name '{node.name}' at line {node.lineno}"
                )
        elif isinstance(node, ast.ClassDef):
            issues.append(f"app.py defines a class at line {node.lineno}; classes are forbidden")
        elif isinstance(node, ast.Name):
            if node.id in _FORBIDDEN_NAMES or node.id.startswith("__"):
                issues.append(
                    f"app.py references forbidden name '{node.id}' at line {node.lineno}"
                )
            parent = parents.get(node)
            safe_constrained_use = isinstance(parent, ast.Call) and parent.func is node
            if (
                node.id == "Pin"
                and isinstance(parent, ast.Attribute)
                and parent.value is node
                and parent.attr in _PIN_ATTRIBUTES
            ):
                safe_constrained_use = True
            if (
                isinstance(node.ctx, ast.Load)
                and node.id in _DIRECT_CALL_ONLY
                and not safe_constrained_use
            ):
                issues.append(
                    f"app.py aliases constrained API '{node.id}' at line {node.lineno}"
                )
            if node.id == "AUTHORIZATION" and isinstance(node.ctx, ast.Load):
                safe_secret_use = (
                    isinstance(parent, ast.Call)
                    and _direct_name(parent) == "post_json"
                    and (
                        _is_positional_argument(node, parent, 2)
                        or any(
                            keyword.arg == "authorization" and keyword.value is node
                            for keyword in parent.keywords
                        )
                    )
                )
                if not safe_secret_use:
                    issues.append(
                        "app.py may use AUTHORIZATION only as post_json authorization "
                        f"at line {node.lineno}"
                    )
        elif isinstance(node, ast.Call):
            if isinstance(node.func, ast.Name) and node.func.id in _FORBIDDEN_CALLS:
                issues.append(
                    f"app.py calls forbidden builtin '{node.func.id}' at line {node.lineno}"
                )
            if isinstance(node.func, ast.Attribute) and (
                node.func.attr in _FORBIDDEN_ATTRIBUTES or node.func.attr == "popen"
            ):
                issues.append(
                    f"app.py calls forbidden operation '{node.func.attr}' at line {node.lineno}"
                )
            call_name = _direct_name(node)
            if call_name == "Pin":
                pin_arg = node.args[0] if node.args else None
                if not isinstance(pin_arg, ast.Name) or pin_arg.id not in _PIN_CONSTANTS:
                    issues.append(
                        "app.py Pin() must use a compiled PIN_* constant "
                        f"at line {node.lineno}"
                    )
            if call_name == "post_json":
                url_arg = node.args[0] if node.args else None
                if not isinstance(url_arg, ast.Name) or url_arg.id != "INGEST_URL":
                    issues.append(
                        "app.py post_json() must use compiled INGEST_URL "
                        f"at line {node.lineno}"
                    )
            if call_name == "emit" and len(node.args) != 1:
                issues.append(
                    "app.py emit() requires exactly one positional event name; "
                    f"fields must be keyword arguments at line {node.lineno}"
                )
        elif isinstance(node, ast.Attribute):
            if node.attr in _FORBIDDEN_ATTRIBUTES or node.attr.startswith("_"):
                issues.append(
                    f"app.py accesses forbidden operation '{node.attr}' at line {node.lineno}"
                )
            if (
                isinstance(node.value, ast.Name)
                and node.value.id in mpu6050_names
                and node.attr not in _MPU6050_ATTRIBUTES
            ):
                issues.append(
                    "app.py uses unsupported MPU6050 member "
                    f"'{node.attr}' at line {node.lineno}; use initialize() and read()"
                )
        elif isinstance(node, (ast.Global, ast.Nonlocal)):
            issues.append(
                f"app.py uses forbidden shared-state declaration at line {node.lineno}"
            )

    if not has_run:
        issues.append("app.py must define run()")
    return sorted(set(issues))


def _render_config(
    build_id: str,
    ingest_url: str,
    pin_sda: int,
    pin_scl: int,
    pin_led: int,
    pin_button: int,
) -> str:
    config = _template("wirejac_config.py.tmpl")
    values = {
        "@@BUILD_ID@@": repr(build_id),
        "@@INGEST_URL@@": repr(ingest_url),
        "@@PIN_SDA@@": str(pin_sda),
        "@@PIN_SCL@@": str(pin_scl),
        "@@PIN_LED@@": str(pin_led),
        "@@PIN_BUTTON@@": str(pin_button),
    }
    for token, value in values.items():
        config = config.replace(token, value)
    return config


def compile_bundle(
    app_source: str,
    build_id: str,
    ingest_url: str = "",
    slot: str = "A",
    pin_sda: int = 21,
    pin_scl: int = 22,
    pin_led: int = 18,
    pin_button: int = 19,
) -> dict[str, str]:
    """Compile reviewed support code and one validated application into a bundle."""
    issues = validate_application(app_source)
    if issues:
        raise ValueError("; ".join(issues))
    if slot not in {"A", "B"}:
        raise ValueError("slot must be A or B")
    if not build_id or len(build_id) > 128:
        raise ValueError("build_id must contain 1 to 128 characters")
    if any(ord(char) < 32 for char in build_id + ingest_url):
        raise ValueError("build metadata contains control characters")
    for name, pin in {
        "pin_sda": pin_sda,
        "pin_scl": pin_scl,
        "pin_led": pin_led,
        "pin_button": pin_button,
    }.items():
        if isinstance(pin, bool) or not isinstance(pin, int) or not 0 <= pin <= 39:
            raise ValueError(f"{name} must be an ESP32 GPIO number")

    release = f"releases/{slot}"
    files = {
        "main.py": _template("main.py"),
        "wirejac_bootstrap.py": _template("wirejac_bootstrap.py"),
        "config/active": slot + "\n",
        "config/previous": ("B" if slot == "A" else "A") + "\n",
        f"{release}/app.py": app_source,
        f"{release}/wirejac_config.py": _render_config(
            build_id,
            ingest_url,
            pin_sda,
            pin_scl,
            pin_led,
            pin_button,
        ),
        f"{release}/wirejac_events.py": _template("wirejac_events.py"),
        f"{release}/wirejac_http.py": _template("wirejac_http.py"),
        f"{release}/drivers/__init__.py": "",
        f"{release}/drivers/mpu6050.py": _template("drivers/mpu6050.py"),
    }
    normalized = {_safe_remote_path(path): body for path, body in files.items()}
    total = sum(len(body.encode("utf-8")) for body in normalized.values())
    if total > _MAX_BUNDLE_BYTES:
        raise ValueError("firmware bundle exceeds the 256 KiB source limit")
    for path, body in normalized.items():
        if len(body.encode("utf-8")) > _MAX_FILE_BYTES:
            raise ValueError(f"{path} exceeds the 48 KiB source limit")
        if "@@" in body:
            raise ValueError(f"{path} contains an unresolved template placeholder")
        if path.endswith(".py"):
            ast.parse(body, filename=path)
    return dict(sorted(normalized.items()))


def manifest_json(files: dict[str, str], build_id: str, slot: str) -> str:
    """Return a deterministic manifest with a hash for every remote file."""
    entries = []
    for path, source in sorted(files.items()):
        payload = source.encode("utf-8")
        entries.append(
            {
                "path": _safe_remote_path(path),
                "sha256": hashlib.sha256(payload).hexdigest(),
                "size_bytes": len(payload),
            }
        )
    manifest = {
        "schema": "wirejac.firmware.bundle/v1",
        "build_id": build_id,
        "slot": slot,
        "files": entries,
    }
    return json.dumps(manifest, indent=2, sort_keys=True) + "\n"


def bundle_zip(files: dict[str, str], manifest: str) -> bytes:
    """Create a reproducible ZIP artifact from a compiled bundle."""
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path, source in sorted(files.items()):
            info = zipfile.ZipInfo(_safe_remote_path(path))
            info.date_time = (1980, 1, 1, 0, 0, 0)
            info.external_attr = 0o644 << 16
            archive.writestr(info, source.encode("utf-8"))
        info = zipfile.ZipInfo("wirejac-manifest.json")
        info.date_time = (1980, 1, 1, 0, 0, 0)
        info.external_attr = 0o644 << 16
        archive.writestr(info, manifest.encode("utf-8"))
    return output.getvalue()


def sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()
