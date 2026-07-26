"""Restricted device-source placeholder for the external Jac-to-Python pipeline."""

obj Acceleration {
    has captured_at_ms: int,
        x: float,
        y: float,
        z: float;
}

def sample_payload(device_id: str, reading: Acceleration) -> dict {
    return {
        "device_id": device_id,
        "captured_at_ms": reading.captured_at_ms,
        "x": reading.x,
        "y": reading.y,
        "z": reading.z,
        "label": None
    };
}
