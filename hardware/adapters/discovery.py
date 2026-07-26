"""Host capability reporting and stable serial-device discovery."""

from __future__ import annotations

from collections.abc import Callable, Iterable
import importlib.metadata
import importlib.util
import os
from pathlib import Path
import sys
from typing import Any

from .models import Capability, CapabilityReport, SerialDevice


PortProvider = Callable[[], Iterable[Any]]


class DeviceDiscovery:
    """Enumerate only stable ``/dev/serial/by-id`` device identities."""

    def __init__(
        self,
        by_id_dir: str | os.PathLike[str] = "/dev/serial/by-id",
        *,
        port_provider: PortProvider | None = None,
    ) -> None:
        self.by_id_dir = Path(by_id_dir).expanduser()
        self._port_provider = port_provider

    @staticmethod
    def _default_port_provider() -> Iterable[Any]:
        try:
            from serial.tools import list_ports
        except ImportError:
            return ()
        return list_ports.comports()

    def list_devices(self) -> tuple[SerialDevice, ...]:
        if not self.by_id_dir.is_dir():
            return ()
        provider = self._port_provider or self._default_port_provider
        ports = tuple(provider())
        by_target: dict[str, Any] = {}
        for port in ports:
            device = getattr(port, "device", None)
            if device:
                by_target[os.path.realpath(str(device))] = port

        devices: list[SerialDevice] = []
        for stable in sorted(self.by_id_dir.iterdir(), key=lambda path: path.name):
            if not stable.is_symlink():
                continue
            stable_absolute = stable.absolute()
            target = Path(os.path.realpath(stable_absolute))
            exists = target.exists()
            accessible = exists and os.access(target, os.R_OK | os.W_OK)
            if not exists:
                access_error = "missing_target"
            elif not accessible:
                access_error = "permission_denied"
            else:
                access_error = None
            port = by_target.get(str(target))
            devices.append(
                SerialDevice(
                    stable_path=str(stable_absolute),
                    target_path=str(target),
                    accessible=accessible,
                    access_error=access_error,
                    vid=getattr(port, "vid", None),
                    pid=getattr(port, "pid", None),
                    serial_number=getattr(port, "serial_number", None),
                    manufacturer=getattr(port, "manufacturer", None),
                    product=(
                        getattr(port, "product", None)
                        or getattr(port, "description", None)
                    ),
                )
            )
        return tuple(devices)

    def get(self, stable_path: str) -> SerialDevice | None:
        requested = str(Path(stable_path).absolute())
        return next(
            (item for item in self.list_devices() if item.stable_path == requested),
            None,
        )


def _package_capability(name: str, module: str, distribution: str) -> Capability:
    if importlib.util.find_spec(module) is None:
        return Capability(name, False, detail=f"Python module {module!r} is unavailable")
    try:
        version = importlib.metadata.version(distribution)
    except importlib.metadata.PackageNotFoundError:
        version = None
    return Capability(name, True, version=version)


def discover_capabilities(
    device_discovery: DeviceDiscovery | None = None,
    *,
    environ: dict[str, str] | None = None,
) -> CapabilityReport:
    """Report adapter prerequisites without opening or changing any device."""

    current_env = os.environ if environ is None else environ
    capabilities = [
        Capability(
            "python",
            True,
            version=".".join(str(item) for item in sys.version_info[:3]),
            executable=sys.executable,
        ),
        _package_capability("esptool", "esptool", "esptool"),
        _package_capability("mpremote", "mpremote", "mpremote"),
        _package_capability("pyserial", "serial", "pyserial"),
        _package_capability("wokwi_client", "wokwi_client", "wokwi-client"),
        _package_capability("littlefs", "littlefs", "littlefs-python"),
        Capability(
            "wokwi_token",
            bool(current_env.get("WOKWI_CLI_TOKEN")),
            detail=(
                "configured"
                if current_env.get("WOKWI_CLI_TOKEN")
                else "WOKWI_CLI_TOKEN is not configured"
            ),
        ),
    ]
    discovery = device_discovery or DeviceDiscovery()
    return CapabilityReport(tuple(capabilities), discovery.list_devices())
