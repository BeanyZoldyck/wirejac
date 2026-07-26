def configure_runtime(workspace_root: str, store_dir: str = ...) -> str: ...
def capabilities_json() -> str: ...
def discover_devices_json() -> str: ...
def persist_artifact(
    workspace_id: str,
    revision_id: str,
    name: str,
    payload: bytes,
    media_type: str = ...,
) -> str: ...
def read_artifact(uri: str) -> bytes: ...
def artifact_path(uri: str) -> str: ...
def build_simulation_image(
    workspace_id: str,
    revision_id: str,
    files_json: str,
) -> str: ...
def identify_device(stable_path: str, expected_mac: str = ...) -> str: ...
def probe_micropython(stable_path: str) -> str: ...
def simulate_bundle(
    diagram_json: str,
    firmware_path: str,
    controls_json: str = ...,
    run_seconds: float = ...,
    expected_events_json: str = ...,
) -> str: ...
def backup_device(
    stable_path: str,
    relative_path: str,
    flash_size_bytes: int,
    expected_mac: str,
) -> str: ...
def provision_configured_device(
    stable_path: str,
    backup_ref_json: str,
    expected_mac: str,
) -> str: ...
def backup_and_provision_configured_device(
    stable_path: str,
    workspace_id: str,
    revision_id: str,
    flash_size_bytes: int,
    expected_mac: str,
) -> str: ...
def deploy_release(
    stable_path: str,
    files_json: str,
    workspace_id: str,
    revision_id: str,
    expected_mac: str = ...,
) -> str: ...
def deploy_and_verify_release(
    stable_path: str,
    files_json: str,
    workspace_id: str,
    revision_id: str,
    expected_mac: str,
    expected_events_json: str,
    duration_s: float,
    baudrate: int = ...,
) -> str: ...
def rollback_release(
    stable_path: str,
    workspace_id: str,
    revision_id: str,
    previous_slot: str,
) -> str: ...
def verify_device(
    stable_path: str,
    expected_events_json: str,
    duration_s: float,
    baudrate: int = ...,
) -> str: ...
