"""Optional Wokwi simulation client isolated from Jac orchestration."""

from __future__ import annotations

from collections.abc import Callable, Mapping, Sequence
import json
import os
from pathlib import Path
import threading
from typing import Any

from .models import (
    CapabilityUnavailableError,
    SafetyError,
    VerificationError,
    WokwiControl,
    WokwiSimulationResult,
)


ClientFactory = Callable[[str], Any]


class WokwiAdapter:
    """Run a controllable simulation without exposing the token to artifacts."""

    def __init__(
        self,
        token: str | None = None,
        *,
        client_factory: ClientFactory | None = None,
    ) -> None:
        self._token = token or os.environ.get("WOKWI_CLI_TOKEN")
        self._client_factory = client_factory

    def available(self) -> bool:
        if not self._token:
            return False
        if self._client_factory is not None:
            return True
        try:
            import wokwi_client  # noqa: F401
        except ImportError:
            return False
        return True

    def _make_client(self) -> Any:
        if not self._token:
            raise CapabilityUnavailableError("WOKWI_CLI_TOKEN is not configured")
        if self._client_factory is not None:
            return self._client_factory(self._token)
        try:
            from wokwi_client import WokwiClientSync
        except ImportError as error:
            raise CapabilityUnavailableError("wokwi-client is unavailable") from error
        return WokwiClientSync(self._token)

    @staticmethod
    def _diagram_bytes(diagram: Mapping[str, Any] | bytes | str) -> bytes:
        if isinstance(diagram, Mapping):
            return (
                json.dumps(
                    diagram,
                    sort_keys=True,
                    separators=(",", ":"),
                    ensure_ascii=True,
                ).encode("utf-8")
                + b"\n"
            )
        if isinstance(diagram, str):
            return diagram.encode("utf-8")
        if isinstance(diagram, bytes):
            return diagram
        raise TypeError("diagram must be a mapping, UTF-8 string, or bytes")

    def run(
        self,
        diagram: Mapping[str, Any] | bytes | str,
        firmware_path: str | os.PathLike[str],
        *,
        controls: Sequence[WokwiControl] = (),
        run_seconds: float = 5,
        expected_events: Sequence[str] = (),
        flash_size_mb: int | None = 4,
    ) -> WokwiSimulationResult:
        if run_seconds <= 0 or run_seconds > 900:
            raise SafetyError("simulation duration must be in (0, 900] seconds")
        if flash_size_mb is not None and flash_size_mb not in {2, 4, 8, 16, 32}:
            raise SafetyError("unsupported simulated flash size")
        ordered_controls = tuple(sorted(controls, key=lambda item: item.at_seconds))
        if any(
            item.at_seconds < 0 or item.at_seconds > run_seconds
            for item in ordered_controls
        ):
            raise SafetyError("Wokwi controls must occur within the simulation window")
        firmware = Path(firmware_path).expanduser().resolve(strict=True)
        if not firmware.is_file():
            raise SafetyError("Wokwi firmware must be a regular file")

        serial_lines: list[str] = []
        serial_lock = threading.Lock()

        def collect(line: bytes | str) -> None:
            value = (
                line.decode("utf-8", errors="replace")
                if isinstance(line, bytes)
                else str(line)
            )
            with serial_lock:
                serial_lines.extend(item for item in value.splitlines() if item)

        client = self._make_client()
        connected = False
        try:
            server_info = client.connect()
            connected = True
            client.upload("diagram.json", self._diagram_bytes(diagram))
            client.upload("firmware.bin", firmware.read_bytes())
            client.serial_monitor(collect)
            client.start_simulation(
                firmware="firmware.bin",
                pause=False,
                flash_size=flash_size_mb,
            )
            for control in ordered_controls:
                client.wait_until_simulation_time(control.at_seconds)
                client.set_control(
                    control.part,
                    control.control,
                    control.value,
                )
            client.wait_until_simulation_time(run_seconds)
            client.pause_simulation()
        except CapabilityUnavailableError:
            raise
        except Exception as error:
            raise VerificationError(f"Wokwi simulation failed: {error}") from error
        finally:
            if connected:
                try:
                    client.disconnect()
                except Exception:
                    pass

        expected = tuple(expected_events)
        observed: list[str] = []
        with serial_lock:
            lines = tuple(serial_lines)
        for line in lines:
            try:
                payload = json.loads(line)
            except (TypeError, ValueError):
                payload = None
            if isinstance(payload, dict) and isinstance(payload.get("event"), str):
                event = payload["event"]
                if event not in observed:
                    observed.append(event)
            for required in expected:
                if required in line and required not in observed:
                    observed.append(required)
        return WokwiSimulationResult(
            server_info=dict(server_info or {}),
            serial_lines=lines,
            expected_events=expected,
            observed_events=tuple(observed),
            controls_applied=ordered_controls,
        )
