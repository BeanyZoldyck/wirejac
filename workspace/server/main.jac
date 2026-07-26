"""Placeholder for the generated WireJac accelerometer server."""

obj Sample {
    has device_id: str,
        captured_at_ms: int,
        x: float,
        y: float,
        z: float,
        label: str | None = None;
}

def health() -> dict {
    return {"status": "ok", "service": "wirejac-sample-api"};
}
