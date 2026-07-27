"""Production phase hooks connecting Jac orchestration to constrained adapters."""

import json;
import os;
import from hashlib { sha256 }
import from os.path { expanduser }
import from time { time }
import hardware.adapters.host_runtime as host_runtime;
import from hardware.breadboard { AssemblyPlan, compile_breadboard }
import from hardware.circuit {
    HardwareSpec,
    hardware_spec_json,
    validate_hardware
}
import from hardware.contracts {
    ArtifactInput,
    ArtifactKind,
    ArtifactView,
    CapabilityView,
    DeviceView,
    ExecutionMode,
    GateInput,
    GateKind,
    IssueSeverity,
    JobStatus,
    PhaseContext,
    PhaseOutcome,
    PhaseResult,
    ProvisionPolicy,
    VerificationStatus
}
import from hardware.firmware {
    FirmwareBundle,
    FirmwarePins,
    compile_firmware
}
import from hardware.graph {
    AssemblyStepNode,
    BoardNode,
    ComponentNode,
    Connects,
    ElectricalNetNode,
    HasAssemblyStep,
    HasBoard,
    HasComponent,
    HasNet,
    HasPin,
    HasPlacement,
    HardwareRevisionNode,
    Occupies,
    PinNode,
    PlacementNode,
    _add_deployment,
    _add_issue,
    _add_simulation_run,
    _add_verification,
    _revision_issues
}
import from hardware.intent_compiler { compile_hardware_intent }
import from hardware.orchestration {
    _register_artifact_read_hook,
    _register_capabilities_hook,
    _register_device_discovery_hook,
    _register_phase_hook
}
import from hardware.planning {
    FirmwareApplication,
    HardwareIntent,
    author_micropython,
    hardware_intent_json,
    plan_hardware
}
import from hardware.visualization {
    VisualizationBundle,
    build_visualization
}


glob _registered: bool = False;
glob _intents: dict[str, HardwareIntent] = {};
glob _specs: dict[str, HardwareSpec] = {};
glob _plans: dict[str, AssemblyPlan] = {};
glob _visuals: dict[str, VisualizationBundle] = {};
glob _firmwares: dict[str, FirmwareBundle] = {};
glob _artifact_records: dict[str, dict[str, object]] = {};
glob _deployment_files: dict[str, dict[str, str]] = {};
glob _simulation_passed: set[str] = set();


def _json_object(payload: str) -> dict[str, object] {
    decoded = json.loads(payload);
    if not isinstance(decoded, dict) {
        raise ValueError("Adapter returned a non-object JSON payload");
    }
    return decoded as dict[str, object];
}


def _json_array(payload: str) -> list[object] {
    decoded = json.loads(payload);
    if not isinstance(decoded, list) {
        raise ValueError("Adapter returned a non-array JSON payload");
    }
    return decoded as list[object];
}


def _nested_object(
    value: dict[str, object],
    key: str
) -> dict[str, object] {
    nested = value.get(key);
    if not isinstance(nested, dict) {
        raise ValueError(f"Adapter payload is missing object '{key}'");
    }
    return nested as dict[str, object];
}


def _string_list(value: object) -> list[str] {
    if not isinstance(value, list) {
        return [];
    }
    result: list[str] = [];
    for item in value {
        if isinstance(item, str) {
            result.append(item);
        }
    }
    return result;
}


def _int_value(value: object, fallback: int = 0) -> int {
    if isinstance(value, int) {
        return value;
    }
    if isinstance(value, float) {
        return int(value);
    }
    return fallback;
}


def _record_key(context: PhaseContext, name: str) -> str {
    return f"{context.revision_id}:{name}";
}


def _persist_record(
    context: PhaseContext,
    name: str,
    payload: bytes,
    media_type: str
) -> dict[str, object] {
    record = _json_object(
        host_runtime.persist_artifact(
            context.workspace_id,
            context.revision_id,
            name,
            payload,
            media_type
        )
    );
    _artifact_records[_record_key(context, name)] = record;
    return record;
}


def _artifact_input(
    kind: ArtifactKind,
    name: str,
    record: dict[str, object],
    metadata: dict[str, str] | None = None
) -> ArtifactInput {
    return ArtifactInput(
        kind=kind,
        name=name,
        uri=str(record["uri"]),
        sha256=str(record["sha256"]),
        media_type=str(record["media_type"]),
        size_bytes=_int_value(record["size_bytes"]),
        metadata=metadata or {}
    );
}


def _persist_text_artifact(
    context: PhaseContext,
    kind: ArtifactKind,
    name: str,
    text: str,
    media_type: str = "application/json",
    metadata: dict[str, str] | None = None
) -> ArtifactInput {
    record = _persist_record(
        context,
        name,
        text.encode("utf-8"),
        media_type
    );
    return _artifact_input(kind, name, record, metadata);
}


def _persist_bytes_artifact(
    context: PhaseContext,
    kind: ArtifactKind,
    name: str,
    payload: bytes,
    media_type: str,
    metadata: dict[str, str] | None = None
) -> ArtifactInput {
    record = _persist_record(context, name, payload, media_type);
    return _artifact_input(kind, name, record, metadata);
}


def _intent_for(context: PhaseContext) -> HardwareIntent {
    cached = _intents.get(context.revision_id);
    if cached is not None {
        return cached;
    }
    intent = plan_hardware(context.request);
    _intents[context.revision_id] = intent;
    return intent;
}


def _spec_for(context: PhaseContext) -> HardwareSpec {
    cached = _specs.get(context.revision_id);
    if cached is not None {
        return cached;
    }
    spec = compile_hardware_intent(
        _intent_for(context),
        context.request.project_id
    );
    _specs[context.revision_id] = spec;
    return spec;
}


def _application_for(
    context: PhaseContext,
    intent: HardwareIntent
) -> FirmwareApplication {
    return author_micropython(context.request, intent);
}


def _pin_gpio(spec: HardwareSpec, role: str, fallback: int) -> int {
    for assignment in spec.pin_assignments {
        if assignment.role == role {
            return assignment.gpio;
        }
    }
    return fallback;
}


def _ingest_url(context: PhaseContext) -> str {
    if context.request.integration is None {
        return "";
    }
    return context.request.integration.backend_endpoint;
}


def _record_validation_issues(
    context: PhaseContext,
    spec: HardwareSpec
) {
    target = jobj(context.revision_id);
    if not isinstance(target, HardwareRevisionNode) {
        return;
    }
    revision = target as HardwareRevisionNode;
    existing = {issue.code for issue in _revision_issues(revision)};
    validation = validate_hardware(spec);
    for issue in validation.issues {
        if issue.code in existing {
            continue;
        }
        severity = (
            IssueSeverity.ERROR
            if issue.severity == "error"
            else IssueSeverity.WARNING
        );
        _ = _add_issue(
            revision,
            issue.code,
            severity,
            issue.message,
            issue.reference
        );
    }
}


def _planning_phase(context: PhaseContext) -> PhaseResult {
    if context.request.board_profile != "doit-esp32-devkit-v1-30pin" {
        return PhaseResult(
            outcome=PhaseOutcome.FAILED,
            message=f"Unsupported board profile: {context.request.board_profile}",
            error_code="BOARD_PROFILE_UNSUPPORTED"
        );
    }
    intent = _intent_for(context);
    artifact = _persist_text_artifact(
        context,
        ArtifactKind.OTHER,
        "hardware-intent.json",
        hardware_intent_json(intent)
    );
    return PhaseResult(
        outcome=PhaseOutcome.CONTINUE,
        message="Hardware intent planned in Jac",
        artifacts=[artifact],
        data={"planning_source": str(intent.source)}
    );
}


def _validation_phase(context: PhaseContext) -> PhaseResult {
    spec = _spec_for(context);
    validation = validate_hardware(spec);
    _record_validation_issues(context, spec);
    artifact = _persist_text_artifact(
        context,
        ArtifactKind.HARDWARE_SPEC,
        "hardware-spec.json",
        hardware_spec_json(spec)
    );
    if not validation.valid {
        codes = ",".join([issue.code for issue in validation.issues]);
        return PhaseResult(
            outcome=PhaseOutcome.FAILED,
            message=f"Electrical validation failed: {codes}",
            error_code="ELECTRICAL_RULE_CHECK_FAILED",
            artifacts=[artifact]
        );
    }
    return PhaseResult(
        outcome=PhaseOutcome.CONTINUE,
        message="Electrical and board-profile validation passed",
        artifacts=[artifact],
        data={"issue_count": str(len(validation.issues))}
    );
}


def _persist_deployment_files(
    context: PhaseContext,
    firmware: FirmwareBundle
) -> dict[str, str] {
    local_files: dict[str, str] = {};
    uri_map: dict[str, str] = {};
    for path in firmware.files {
        record = _persist_record(
            context,
            f"firmware/{path}",
            firmware.files[path].encode("utf-8"),
            "text/x-python" if path.endswith(".py") else "text/plain"
        );
        local_files[path] = str(record["absolute_path"]);
        uri_map[path] = str(record["uri"]);
    }
    _deployment_files[context.revision_id] = local_files;
    _ = _persist_record(
        context,
        "firmware/deployment-map.json",
        (
            json.dumps(uri_map, sort_keys=True, indent=2) as str
        ).encode("utf-8"),
        "application/json"
    );
    return local_files;
}


def _materialize_topology(
    context: PhaseContext,
    spec: HardwareSpec,
    plan: AssemblyPlan
) {
    target = jobj(context.revision_id);
    if not isinstance(target, HardwareRevisionNode) {
        raise ValueError("Current hardware revision is unavailable");
    }
    revision = target as HardwareRevisionNode;
    if len([revision ->:HasBoard:->]) > 0 {
        return;
    }
    created_at = time();
    board = BoardNode(
        profile_id=spec.board_profile_id,
        display_name=spec.title,
        spec_hash=sha256(
            hardware_spec_json(spec).encode("utf-8")
        ).hexdigest(),
        created_at=created_at
    );
    revision +>:HasBoard:+> board;

    components: dict[str, ComponentNode] = {};
    for component in spec.components {
        component_node = ComponentNode(
            instance_id=component.component_id,
            profile_id=component.profile_id,
            display_name=component.label,
            created_at=created_at
        );
        revision +>:HasComponent:+> component_node;
        components[component.component_id] = component_node;
    }
    for assignment in spec.pin_assignments {
        component = components.get(assignment.component_id);
        if component is None {
            continue;
        }
        pin = PinNode(
            pin_id=assignment.role,
            label=f"GPIO{assignment.gpio} to {assignment.component_pin}",
            gpio=assignment.gpio,
            voltage_domain="3.3v",
            created_at=created_at
        );
        component +>:HasPin:+> pin;
    }
    for net in spec.nets {
        voltage_domain = (
            "3.3v"
            if net.role == "power_3v3"
            else "ground" if net.role == "ground" else "signal"
        );
        net_node = ElectricalNetNode(
            net_id=net.net_id,
            name=net.net_id,
            role=net.role,
            voltage_domain=voltage_domain,
            created_at=created_at
        );
        revision +>:HasNet:+> net_node;
        for endpoint in net.endpoints {
            component = components.get(endpoint.component_id);
            if component is not None {
                net_node +>:Connects(pin_id=endpoint.pin_id):+> component;
            }
        }
    }
    for placement in plan.placements {
        first_hole = (
            placement.anchors[0].hole
            if placement.anchors
            else ""
        );
        placement_node = PlacementNode(
            placement_id=placement.placement_id,
            part_instance_id=placement.component_id,
            breadboard_hole=first_hole,
            orientation=placement.rotation,
            created_at=created_at
        );
        revision +>:HasPlacement:+> placement_node;
        component = components.get(placement.component_id);
        if component is not None {
            component +>:Occupies:+> placement_node;
        }
    }
    for step in plan.steps {
        step_node = AssemblyStepNode(
            step_id=f"step-{step.number:02d}",
            number=step.number,
            title=step.title,
            instruction=step.instruction,
            visual_artifact_id=f"step-{step.number:02d}.svg",
            created_at=created_at
        );
        revision +>:HasAssemblyStep:+> step_node;
    }
}


def _generation_phase(context: PhaseContext) -> PhaseResult {
    intent = _intent_for(context);
    spec = _spec_for(context);
    validation = validate_hardware(spec);
    if not validation.valid {
        return PhaseResult(
            outcome=PhaseOutcome.FAILED,
            message="Generation refused an invalid hardware specification",
            error_code="INVALID_HARDWARE_SPEC"
        );
    }
    plan = compile_breadboard(spec);
    visual = build_visualization(spec, plan);
    application = _application_for(context, intent);
    firmware = compile_firmware(
        application,
        build_id=context.revision_id,
        ingest_url=_ingest_url(context),
        slot="A",
        pins=FirmwarePins(
            sda=_pin_gpio(spec, "i2c_sda", 21),
            scl=_pin_gpio(spec, "i2c_scl", 22),
            led=_pin_gpio(spec, "status_led", 18),
            button=_pin_gpio(spec, "arm_button", 19)
        )
    );
    _plans[context.revision_id] = plan;
    _visuals[context.revision_id] = visual;
    _firmwares[context.revision_id] = firmware;
    _materialize_topology(context, spec, plan);
    _ = _persist_deployment_files(context, firmware);

    artifacts: list[ArtifactInput] = [
        _persist_text_artifact(
            context,
            ArtifactKind.VISUALIZATION,
            "visualization.json",
            visual.visualization_json
        ),
        _persist_text_artifact(
            context,
            ArtifactKind.ASSEMBLY,
            "assembly.json",
            visual.assembly_json
        ),
        _persist_text_artifact(
            context,
            ArtifactKind.WOKWI_DIAGRAM,
            "diagram.json",
            visual.wokwi_diagram_json
        ),
        _persist_bytes_artifact(
            context,
            ArtifactKind.FIRMWARE_BUNDLE,
            "firmware-bundle.zip",
            firmware.archive,
            "application/zip",
            {"build_id": firmware.build_id, "slot": firmware.slot}
        ),
        _persist_text_artifact(
            context,
            ArtifactKind.OTHER,
            "firmware-manifest.json",
            firmware.manifest
        ),
    ];
    for (filename, svg) in zip(
        visual.step_filenames,
        visual.step_svgs
    ) {
        artifacts.append(
            _persist_text_artifact(
                context,
                ArtifactKind.ASSEMBLY_STEP_SVG,
                filename,
                svg,
                "image/svg+xml"
            )
        );
    }
    return PhaseResult(
        outcome=PhaseOutcome.CONTINUE,
        message=(
            f"Generated {len(firmware.files)} MicroPython files and "
            f"{len(visual.step_svgs)} assembly visuals"
        ),
        artifacts=artifacts,
        data={
            "firmware_sha256": firmware.archive_sha256,
            "assembly_steps": str(len(visual.step_svgs)),
        }
    );
}


def _capability_available(name: str) -> bool {
    capability_report = _json_object(host_runtime.capabilities_json());
    raw_capabilities = capability_report.get("capabilities");
    if not isinstance(raw_capabilities, list) {
        return False;
    }
    for raw in raw_capabilities {
        if not isinstance(raw, dict) {
            continue;
        }
        capability = raw as dict[str, object];
        if capability.get("name") == name {
            return capability.get("available") as bool;
        }
    }
    return False;
}


def _record_simulation(
    context: PhaseContext,
    status: VerificationStatus,
    summary: str,
    started_at: float
) {
    target = jobj(context.revision_id);
    if isinstance(target, HardwareRevisionNode) {
        _ = _add_simulation_run(
            target as HardwareRevisionNode,
            status,
            "wokwi",
            summary,
            started_at,
            time()
        );
    }
}


def _simulation_phase(context: PhaseContext) -> PhaseResult {
    started_at = time();
    if not _capability_available("wokwi_token") {
        if context.request.execution_mode == ExecutionMode.DEPLOY {
            _record_simulation(
                context,
                VerificationStatus.SKIPPED,
                "Wokwi token unavailable; guarded physical path selected",
                started_at
            );
            return PhaseResult(
                outcome=PhaseOutcome.SKIPPED,
                message="Wokwi token is unavailable; continuing to the guarded physical path",
                next_status=JobStatus.PROVISIONING,
                data={"simulation": "skipped"}
            );
        }
        _record_simulation(
            context,
            VerificationStatus.USER_ACTION_REQUIRED,
            "Wokwi token is required for a simulation-only job",
            started_at
        );
        return PhaseResult(
            outcome=PhaseOutcome.BLOCKED,
            message="WOKWI_CLI_TOKEN is required for simulation-only jobs",
            error_code="WOKWI_UNAVAILABLE"
        );
    }
    firmware = _firmwares.get(context.revision_id);
    visual = _visuals.get(context.revision_id);
    if firmware is None or visual is None {
        _record_simulation(
            context,
            VerificationStatus.FAILED,
            "Generated simulation state is unavailable",
            started_at
        );
        return PhaseResult(
            outcome=PhaseOutcome.BLOCKED,
            message="Generation state is unavailable; create a new immutable revision",
            error_code="GENERATION_STATE_UNAVAILABLE"
        );
    }
    image_result = _json_object(
        host_runtime.build_simulation_image(
            context.workspace_id,
            context.revision_id,
            json.dumps(firmware.files, sort_keys=True) as str
        )
    );
    image = _nested_object(image_result, "image");
    image_artifact = _nested_object(image, "artifact");
    controls = json.dumps(
        [
            {
                "at_seconds": 2.0,
                "part": "imu",
                "control": "accelX",
                "value": 3.0,
            },
            {
                "at_seconds": 2.0,
                "part": "imu",
                "control": "rotationX",
                "value": 250.0,
            },
            {
                "at_seconds": 4.0,
                "part": "arm_button",
                "control": "pressed",
                "value": 1,
            },
            {
                "at_seconds": 4.2,
                "part": "arm_button",
                "control": "pressed",
                "value": 0,
            },
        ],
        sort_keys=True
    ) as str;
    expected = ["wirejac.ready", "sensor.detected", "snatch.detected"];
    evidence_text = host_runtime.simulate_bundle(
        visual.wokwi_diagram_json,
        str(image_artifact["absolute_path"]),
        controls,
        7.0,
        json.dumps(expected) as str
    );
    evidence = _json_object(evidence_text);
    observed = _string_list(evidence.get("observed_events"));
    passed = True;
    for event in expected {
        if event not in observed {
            passed = False;
        }
    }
    evidence_artifact = _persist_text_artifact(
        context,
        ArtifactKind.SIMULATION_EVIDENCE,
        "simulation-evidence.json",
        evidence_text
    );
    image_input = ArtifactInput(
        kind=ArtifactKind.OTHER,
        name="wokwi-flash.bin",
        uri=str(image_result["image_uri"]),
        sha256=str(image_artifact["sha256"]),
        media_type="application/octet-stream",
        size_bytes=_int_value(image_artifact["size"])
    );
    if not passed {
        _record_simulation(
            context,
            VerificationStatus.FAILED,
            "Wokwi missed one or more expected events",
            started_at
        );
        return PhaseResult(
            outcome=PhaseOutcome.FAILED,
            message=f"Wokwi missed expected events: {','.join(expected)}",
            error_code="SIMULATION_VERIFICATION_FAILED",
            artifacts=[evidence_artifact, image_input]
        );
    }
    _simulation_passed.add(context.revision_id);
    _record_simulation(
        context,
        VerificationStatus.PASSED,
        "Wokwi simulation passed",
        started_at
    );
    return PhaseResult(
        outcome=PhaseOutcome.CONTINUE,
        message="In-process Wokwi simulation passed",
        artifacts=[evidence_artifact, image_input],
        data={"observed_events": ",".join(observed)}
    );
}


def _identity_uri(context: PhaseContext) -> str {
    return (
        f"artifact://{context.workspace_id}/{context.revision_id}/"
        "device-identity.json"
    );
}


def _pinned_identity(context: PhaseContext) -> dict[str, object] | None {
    try {
        return _json_object(
            host_runtime.read_artifact(_identity_uri(context)).decode("utf-8")
        );
    } except Exception {
        return None;
    }
}


def _identity_record(
    context: PhaseContext,
    identity: dict[str, object]
) -> dict[str, object] {
    return {
        "schema": "wirejac.device-identity/v1",
        "stable_path": context.request.device_selector,
        "mac": str(identity["mac"]),
        "chip": str(identity["chip"]),
        "revision": str(identity.get("revision") or ""),
        "flash_size_bytes": _int_value(
            identity.get("flash_size_bytes"),
            4 * 1024 * 1024
        ),
    };
}


def _device_identity(context: PhaseContext) -> dict[str, object] {
    pinned = _pinned_identity(context);
    expected_mac = context.request.metadata.get("expected_mac", "");
    if not expected_mac and pinned is not None {
        expected_mac = str(pinned["mac"]);
    }
    return _json_object(
        host_runtime.identify_device(
            context.request.device_selector,
            expected_mac
        )
    );
}


def _provisioning_phase(context: PhaseContext) -> PhaseResult {
    if not context.request.device_selector {
        return PhaseResult(
            outcome=PhaseOutcome.BLOCKED,
            message="Select a stable /dev/serial/by-id device in a new revision",
            error_code="DEVICE_SELECTOR_REQUIRED"
        );
    }
    try {
        identity = _device_identity(context);
    } except Exception as error {
        return PhaseResult(
            outcome=PhaseOutcome.WAITING,
            message=str(error),
            error_code="DEVICE_ACCESS_BLOCKED",
            gate=GateInput(
                kind=GateKind.DEVICE_PERMISSION,
                title="Serial device access is required",
                instructions=(
                    "Grant this user read/write access to the selected stable "
                    "serial device, reconnect it, then retry this gate."
                ),
                resume_status=JobStatus.PROVISIONING,
                metadata={"error": str(error)}
            )
        );
    }
    mac = str(identity["mac"]);
    pinned = _pinned_identity(context);
    identity_artifacts: list[ArtifactInput] = [];
    if pinned is None {
        record = _identity_record(context, identity);
        identity_artifacts.append(
            _persist_text_artifact(
                context,
                ArtifactKind.OTHER,
                "device-identity.json",
                json.dumps(record, sort_keys=True, indent=2) as str
            )
        );
        pinned = record;
    }
    if (
        not context.request.metadata.get("expected_mac", "")
        and not context.request.metadata.get("identity_confirmed", "")
        and len(identity_artifacts) > 0
    ) {
        return PhaseResult(
            outcome=PhaseOutcome.WAITING,
            message=f"Confirm ESP32 identity {mac}",
            artifacts=identity_artifacts,
            gate=GateInput(
                kind=GateKind.DEVICE_SELECTION,
                title="Confirm the physical ESP32",
                instructions=(
                    f"Confirm {context.request.device_selector} is the intended "
                    f"{str(identity['chip'])} with MAC {mac}."
                ),
                resume_status=JobStatus.PROVISIONING,
                metadata={
                    "stable_port": context.request.device_selector,
                    "mac_address": mac,
                    "chip": str(identity["chip"]),
                }
            )
        );
    }

    probe = _json_object(
        host_runtime.probe_micropython(context.request.device_selector)
    );
    if (
        (probe.get("available") as bool)
        and context.request.provision_policy != ProvisionPolicy.FORCE
    ) {
        return PhaseResult(
            outcome=PhaseOutcome.SKIPPED,
            message=f"MicroPython already responds on ESP32 {mac}",
            next_status=JobStatus.DEPLOYING,
            artifacts=identity_artifacts,
            data={"mac_address": mac, "provisioning": "not_required"}
        );
    }
    if context.request.provision_policy == ProvisionPolicy.NEVER {
        return PhaseResult(
            outcome=PhaseOutcome.BLOCKED,
            message=(
                "MicroPython is unavailable and provision_policy is never; "
                "submit a revision with allow_if_needed"
            ),
            error_code="PROVISIONING_NOT_AUTHORIZED",
            artifacts=identity_artifacts
        );
    }

    flash_size = _int_value(identity.get("flash_size_bytes"), 4 * 1024 * 1024);
    transaction_text = host_runtime.backup_and_provision_configured_device(
        context.request.device_selector,
        context.workspace_id,
        context.revision_id,
        flash_size,
        mac
    );
    transaction = _json_object(transaction_text);
    backup = _nested_object(transaction, "backup");
    backup_artifact = _nested_object(backup, "artifact");
    backup_input = ArtifactInput(
        kind=ArtifactKind.FLASH_BACKUP,
        name="flash-backup.bin",
        uri=f"artifact://{str(backup_artifact['relative_path'])}",
        sha256=str(backup_artifact["sha256"]),
        media_type="application/octet-stream",
        size_bytes=_int_value(backup_artifact["size"]),
        metadata={"mac_address": mac}
    );
    evidence = _persist_text_artifact(
        context,
        ArtifactKind.OTHER,
        "provisioning-evidence.json",
        transaction_text
    );
    phase_artifacts = identity_artifacts + [backup_input, evidence];
    if not (transaction.get("success") as bool) {
        recovery_failed = transaction.get("recovery_failed") as bool;
        return PhaseResult(
            outcome=PhaseOutcome.FAILED,
            message=f"MicroPython provisioning failed: {str(transaction['error'])}",
            error_code=(
                "PROVISIONING_RECOVERY_FAILED"
                if recovery_failed
                else "PROVISIONING_FAILED_RESTORED"
            ),
            artifacts=phase_artifacts
        );
    }
    return PhaseResult(
        outcome=PhaseOutcome.CONTINUE,
        message=f"Backed up and provisioned ESP32 {mac}",
        artifacts=phase_artifacts,
        data={"mac_address": mac, "provisioning": "completed"}
    );
}


def _deployment_files_for(context: PhaseContext) -> dict[str, str] {
    cached = _deployment_files.get(context.revision_id);
    if cached is not None {
        return cached;
    }
    uri = (
        f"artifact://{context.workspace_id}/{context.revision_id}/"
        "firmware/deployment-map.json"
    );
    decoded = json.loads(host_runtime.read_artifact(uri).decode("utf-8"));
    if not isinstance(decoded, dict) {
        raise ValueError("Deployment map artifact is invalid");
    }
    result: dict[str, str] = {};
    mapping = decoded as dict[str, object];
    for remote in mapping {
        artifact_uri = mapping[remote];
        if not isinstance(artifact_uri, str) {
            raise ValueError("Deployment map contains a non-string URI");
        }
        result[remote] = host_runtime.artifact_path(artifact_uri);
    }
    _deployment_files[context.revision_id] = result;
    return result;
}


def _deployment_phase(context: PhaseContext) -> PhaseResult {
    started_at = time();
    if not context.request.device_selector {
        return PhaseResult(
            outcome=PhaseOutcome.BLOCKED,
            message="Device selector is required for deployment",
            error_code="DEVICE_SELECTOR_REQUIRED"
        );
    }
    pinned = _pinned_identity(context);
    if pinned is None {
        return PhaseResult(
            outcome=PhaseOutcome.BLOCKED,
            message="Persisted device identity is missing; retry provisioning",
            error_code="DEVICE_IDENTITY_EVIDENCE_MISSING"
        );
    }
    expected = ["sensor.detected", "wirejac.ready", "wirejac.heartbeat"];
    result_text = host_runtime.deploy_and_verify_release(
        context.request.device_selector,
        json.dumps(
            _deployment_files_for(context),
            sort_keys=True
        ) as str,
        context.workspace_id,
        context.revision_id,
        str(pinned["mac"]),
        json.dumps(expected) as str,
        12.0,
        115200
    );
    result = _json_object(result_text);
    deployment = result.get("deployment");
    target_slot = "";
    if isinstance(deployment, dict) {
        target_slot = str(
            (deployment as dict[str, object]).get("target_slot") or ""
        );
    }
    evidence = _persist_text_artifact(
        context,
        ArtifactKind.OTHER,
        "deployment-evidence.json",
        result_text,
        metadata={
            "mac_address": str(pinned["mac"]),
            "target_slot": target_slot,
            "verified": str(result.get("success") as bool),
            "rolled_back": str(result.get("rolled_back") as bool),
        }
    );
    firmware = _firmwares.get(context.revision_id);
    firmware_sha256 = (
        firmware.archive_sha256 if firmware is not None else ""
    );
    target = jobj(context.revision_id);
    if isinstance(target, HardwareRevisionNode) {
        _ = _add_deployment(
            target as HardwareRevisionNode,
            (
                VerificationStatus.PASSED
                if result.get("success") as bool
                else VerificationStatus.FAILED
            ),
            context.operation_id,
            firmware_sha256,
            started_at,
            time()
        );
    }
    return PhaseResult(
        outcome=PhaseOutcome.CONTINUE,
        message=(
            f"Activated and verified slot {target_slot}"
            if result.get("success") as bool
            else "Deployment transaction completed with verification failure"
        ),
        artifacts=[evidence],
        data={
            "mac_address": str(pinned["mac"]),
            "active_slot": target_slot,
            "verified": str(result.get("success") as bool),
        }
    );
}


def _record_verification(
    context: PhaseContext,
    status: VerificationStatus,
    summary: str,
    checks: dict[str, str]
) {
    target = jobj(context.revision_id);
    if isinstance(target, HardwareRevisionNode) {
        revision = target as HardwareRevisionNode;
        _ = _add_verification(revision, status, summary, checks);
    }
}


def _verification_phase(context: PhaseContext) -> PhaseResult {
    if context.request.execution_mode == ExecutionMode.SIMULATE {
        passed = context.revision_id in _simulation_passed;
        if not passed {
            try {
                simulation_uri = (
                    f"artifact://{context.workspace_id}/{context.revision_id}/"
                    "simulation-evidence.json"
                );
                persisted = _json_object(
                    host_runtime.read_artifact(
                        simulation_uri
                    ).decode("utf-8")
                );
                observed = _string_list(persisted.get("observed_events"));
                passed = all(
                    event in observed
                    for event in [
                        "wirejac.ready",
                        "sensor.detected",
                        "snatch.detected"
                    ]
                );
            } except Exception {
                passed = False;
            }
        }
        checks = {"wokwi": "passed" if passed else "missing"};
        manifest = json.dumps(
            {
                "schema": "wirejac.verification/v1",
                "status": "passed" if passed else "failed",
                "checks": checks,
            },
            sort_keys=True,
            indent=2
        ) as str;
        artifact = _persist_text_artifact(
            context,
            ArtifactKind.VERIFICATION_MANIFEST,
            "verification-manifest.json",
            manifest
        );
        if not passed {
            _record_verification(
                context,
                VerificationStatus.FAILED,
                "Simulation evidence is unavailable",
                checks
            );
            return PhaseResult(
                outcome=PhaseOutcome.FAILED,
                message="Simulation verification evidence is unavailable",
                error_code="SIMULATION_EVIDENCE_MISSING",
                artifacts=[artifact]
            );
        }
        _record_verification(
            context,
            VerificationStatus.PASSED,
            "Wokwi simulation passed",
            checks
        );
        return PhaseResult(
            outcome=PhaseOutcome.CONTINUE,
            message="Simulation verification passed",
            artifacts=[artifact]
        );
    }

    transaction_uri = (
        f"artifact://{context.workspace_id}/{context.revision_id}/"
        "deployment-evidence.json"
    );
    try {
        transaction_text = host_runtime.read_artifact(
            transaction_uri
        ).decode("utf-8");
        transaction = _json_object(transaction_text);
    } except Exception as error {
        return PhaseResult(
            outcome=PhaseOutcome.FAILED,
            message=f"Deployment transaction evidence is unavailable: {str(error)}",
            error_code="DEPLOYMENT_EVIDENCE_MISSING"
        );
    }
    raw_verification = transaction.get("verification");
    verification: dict[str, object] = (
        raw_verification as dict[str, object]
        if isinstance(raw_verification, dict)
        else {}
    );
    expected = _string_list(verification.get("expected_events"));
    observed = _string_list(verification.get("observed_events"));
    passed = transaction.get("success") as bool;
    evidence_text = json.dumps(
        verification,
        sort_keys=True,
        indent=2
    ) as str;
    serial_artifact = _persist_text_artifact(
        context,
        ArtifactKind.SERIAL_LOG,
        "serial-verification.json",
        evidence_text
    );
    checks = {
        "serial": "passed" if passed else "failed",
        "expected_events": ",".join(expected),
        "observed_events": ",".join(observed),
    };
    manifest = json.dumps(
        {
            "schema": "wirejac.verification/v1",
            "status": "passed" if passed else "failed",
            "checks": checks,
        },
        sort_keys=True,
        indent=2
    ) as str;
    manifest_artifact = _persist_text_artifact(
        context,
        ArtifactKind.VERIFICATION_MANIFEST,
        "verification-manifest.json",
        manifest
    );
    if passed {
        _record_verification(
            context,
            VerificationStatus.PASSED,
            "Physical device verification passed",
            checks
        );
        return PhaseResult(
            outcome=PhaseOutcome.CONTINUE,
            message="Physical serial verification passed",
            artifacts=[serial_artifact, manifest_artifact]
        );
    }

    if transaction.get("rolled_back") as bool {
        rollback_text = json.dumps(
            transaction.get("rollback"),
            sort_keys=True,
            indent=2
        ) as str;
        rollback_artifact = _persist_text_artifact(
            context,
            ArtifactKind.OTHER,
            "rollback-evidence.json",
            rollback_text
        );
        _record_verification(
            context,
            VerificationStatus.FAILED,
            "Verification failed and the previous slot was restored",
            checks
        );
        return PhaseResult(
            outcome=PhaseOutcome.CONTINUE,
            message="Verification failed; deployment transaction restored the previous slot",
            next_status=JobStatus.ROLLED_BACK,
            artifacts=[
                serial_artifact,
                manifest_artifact,
                rollback_artifact,
            ]
        );
    }
    _record_verification(
        context,
        VerificationStatus.FAILED,
        "Physical serial verification failed",
        checks
    );
    return PhaseResult(
        outcome=PhaseOutcome.FAILED,
        message="Physical serial verification missed required events",
        error_code="DEVICE_VERIFICATION_FAILED",
        artifacts=[serial_artifact, manifest_artifact]
    );
}


def _discover_devices -> list[DeviceView] {
    views: list[DeviceView] = [];
    for raw in _json_array(host_runtime.discover_devices_json()) {
        if not isinstance(raw, dict) {
            continue;
        }
        device = raw as dict[str, object];
        stable = str(device.get("stable_path") or "");
        access_error = str(device.get("access_error") or "");
        views.append(
            DeviceView(
                device_id=sha256(stable.encode("utf-8")).hexdigest()[:16],
                stable_port=stable,
                chip_family="esp32",
                mac_address="",
                flash_size_bytes=0,
                firmware_kind="unknown",
                connected=access_error != "missing_target",
                last_seen_at=time()
            )
        );
    }
    return views;
}


def _capabilities -> list[CapabilityView] {
    views: list[CapabilityView] = [
        CapabilityView(
            name="profile:doit-esp32-devkit-v1-30pin",
            available=True,
            detail="deterministic circuit, breadboard, SVG, and Wokwi compiler"
        )
    ];
    capability_report = _json_object(host_runtime.capabilities_json());
    raw_capabilities = capability_report.get("capabilities");
    if not isinstance(raw_capabilities, list) {
        return views;
    }
    for raw in raw_capabilities {
        if not isinstance(raw, dict) {
            continue;
        }
        capability = raw as dict[str, object];
        detail = str(
            capability.get("detail")
            or capability.get("version")
            or ""
        );
        views.append(
            CapabilityView(
                name=f"host:{str(capability.get('name') or '')}",
                available=capability.get("available") as bool,
                detail=detail
            )
        );
    }
    return views;
}


def _read_artifact(view: ArtifactView) -> bytes {
    return host_runtime.read_artifact(view.uri);
}


def _register_hardware_service {
    if not _registered {
        workspace = os.environ.get(
            "WIREJAC_WORKSPACE_ROOT",
            expanduser("~/.wirejac/runs")
        );
        _ = host_runtime.configure_runtime(workspace);
    }
    _register_phase_hook(JobStatus.PLANNING, _planning_phase);
    _register_phase_hook(JobStatus.VALIDATING, _validation_phase);
    _register_phase_hook(JobStatus.GENERATING, _generation_phase);
    _register_phase_hook(JobStatus.SIMULATING, _simulation_phase);
    _register_phase_hook(JobStatus.PROVISIONING, _provisioning_phase);
    _register_phase_hook(JobStatus.DEPLOYING, _deployment_phase);
    _register_phase_hook(JobStatus.VERIFYING, _verification_phase);
    _register_device_discovery_hook(_discover_devices);
    _register_capabilities_hook(_capabilities);
    _register_artifact_read_hook(_read_artifact);
    _registered = True;
}
