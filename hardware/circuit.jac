"""Typed hardware specification and deterministic electrical-rule checking."""

import json;
import from hardware.catalog.profiles {
    BoardPinProfile,
    BoardProfile,
    PartPinProfile,
    PartProfile,
    board_pin_by_gpio,
    board_pin_by_id,
    get_board_profile,
    get_breadboard_profile,
    get_part_profile,
    part_pin_by_id,
}


obj ComponentInstance {
    has component_id: str,
        profile_id: str,
        label: str;
    has i2c_address: int = -1;
}


obj Endpoint {
    has component_id: str,
        pin_id: str;
}


obj ElectricalNet {
    has net_id: str,
        role: str,
        endpoints: list[Endpoint];
}


obj PinAssignment {
    has role: str,
        gpio: int,
        component_id: str,
        component_pin: str;
    has direction: str = "bidirectional";
}


obj HardwareSpec {
    has schema_version: str,
        project_id: str,
        board_id: str,
        board_profile_id: str,
        breadboard_profile_id: str,
        components: list[ComponentInstance],
        pin_assignments: list[PinAssignment],
        nets: list[ElectricalNet],
        expected_events: list[str];
    has title: str = "WireJac hardware project",
        behavior: str = "";
}


obj HardwareIssue {
    has code: str,
        severity: str,
        message: str;
    has reference: str = "";
}


obj HardwareValidation {
    has valid: bool,
        issues: list[HardwareIssue];
}


"""Build a safe reference ESP32 motion-sensor specification for compiler tests."""
def make_default_phone_snatch_spec(project_id: str) -> HardwareSpec {
    return HardwareSpec(
        schema_version="wirejac.hardware.v1",
        project_id=project_id,
        title="Phone-snatching training sensor",
        behavior=(
            "Read the MPU6050, detect a sharp acceleration/rotation event, "
            "signal locally, and publish structured snatch events."
        ),
        board_id="esp32",
        board_profile_id="doit-esp32-devkit-v1-30pin",
        breadboard_profile_id="half-breadboard-400",
        components=[
            ComponentInstance(
                component_id="imu",
                profile_id="gy521-mpu6050",
                label="Motion sensor",
                i2c_address=104,
            ),
            ComponentInstance(
                component_id="status_led",
                profile_id="led-5mm-red",
                label="Snatch indicator",
            ),
            ComponentInstance(
                component_id="led_resistor",
                profile_id="resistor-220ohm",
                label="LED current limiter",
            ),
            ComponentInstance(
                component_id="arm_button",
                profile_id="button-6mm",
                label="Arm/test button",
            ),
        ],
        pin_assignments=[
            PinAssignment(
                role="i2c_sda",
                gpio=21,
                component_id="imu",
                component_pin="SDA",
            ),
            PinAssignment(
                role="i2c_scl",
                gpio=22,
                component_id="imu",
                component_pin="SCL",
            ),
            PinAssignment(
                role="status_led",
                gpio=18,
                component_id="status_led",
                component_pin="A",
                direction="output",
            ),
            PinAssignment(
                role="arm_button",
                gpio=19,
                component_id="arm_button",
                component_pin="P1",
                direction="input_pullup",
            ),
        ],
        nets=[
            ElectricalNet(
                net_id="power_3v3",
                role="power_3v3",
                endpoints=[
                    Endpoint("esp32", "3V3"),
                    Endpoint("imu", "VCC"),
                ],
            ),
            ElectricalNet(
                net_id="ground",
                role="ground",
                endpoints=[
                    Endpoint("esp32", "GND_R"),
                    Endpoint("imu", "GND"),
                    Endpoint("status_led", "K"),
                    Endpoint("arm_button", "P2"),
                ],
            ),
            ElectricalNet(
                net_id="i2c_sda",
                role="i2c_sda",
                endpoints=[
                    Endpoint("esp32", "GPIO21"),
                    Endpoint("imu", "SDA"),
                ],
            ),
            ElectricalNet(
                net_id="i2c_scl",
                role="i2c_scl",
                endpoints=[
                    Endpoint("esp32", "GPIO22"),
                    Endpoint("imu", "SCL"),
                ],
            ),
            ElectricalNet(
                net_id="led_drive",
                role="digital_output",
                endpoints=[
                    Endpoint("esp32", "GPIO18"),
                    Endpoint("led_resistor", "P1"),
                ],
            ),
            ElectricalNet(
                net_id="led_series",
                role="passive",
                endpoints=[
                    Endpoint("led_resistor", "P2"),
                    Endpoint("status_led", "A"),
                ],
            ),
            ElectricalNet(
                net_id="button_input",
                role="digital_input_pullup",
                endpoints=[
                    Endpoint("esp32", "GPIO19"),
                    Endpoint("arm_button", "P1"),
                ],
            ),
        ],
        expected_events=[
            "wirejac.ready",
            "sensor.detected",
            "wirejac.heartbeat",
            "snatch.detected",
        ],
    );
}


def _component_by_id(
    spec: HardwareSpec,
    component_id: str,
) -> ComponentInstance | None {
    for component in spec.components {
        if component.component_id == component_id {
            return component;
        }
    }
    return None;
}


def _net_for_endpoint(
    spec: HardwareSpec,
    component_id: str,
    pin_id: str,
) -> ElectricalNet | None {
    for net in spec.nets {
        for endpoint in net.endpoints {
            if (
                endpoint.component_id == component_id
                and endpoint.pin_id == pin_id
            ) {
                return net;
            }
        }
    }
    return None;
}


def _net_has_profile(
    spec: HardwareSpec,
    net: ElectricalNet,
    profile_id: str,
) -> bool {
    for endpoint in net.endpoints {
        component = _component_by_id(spec, endpoint.component_id);
        if component is not None and component.profile_id == profile_id {
            return True;
        }
    }
    return False;
}


def _pin_assignment_for_gpio(
    spec: HardwareSpec,
    gpio: int,
) -> PinAssignment | None {
    for assignment in spec.pin_assignments {
        if assignment.gpio == gpio {
            return assignment;
        }
    }
    return None;
}


def _net_has_component_pin(
    net: ElectricalNet,
    component_id: str,
    pin_id: str,
) -> bool {
    for endpoint in net.endpoints {
        if (
            endpoint.component_id == component_id
            and endpoint.pin_id == pin_id
        ) {
            return True;
        }
    }
    return False;
}


def _nets_share_series_resistor(
    spec: HardwareSpec,
    first: ElectricalNet,
    second: ElectricalNet,
) -> bool {
    for component in spec.components {
        if component.profile_id != "resistor-220ohm" {
            continue;
        }
        first_has_p1 = _net_has_component_pin(
            first,
            component.component_id,
            "P1",
        );
        first_has_p2 = _net_has_component_pin(
            first,
            component.component_id,
            "P2",
        );
        second_has_p1 = _net_has_component_pin(
            second,
            component.component_id,
            "P1",
        );
        second_has_p2 = _net_has_component_pin(
            second,
            component.component_id,
            "P2",
        );
        if (
            (first_has_p1 and second_has_p2)
            or (first_has_p2 and second_has_p1)
        ) {
            return True;
        }
    }
    return False;
}


def _endpoint_voltage(
    spec: HardwareSpec,
    board: BoardProfile,
    endpoint: Endpoint,
) -> float {
    if endpoint.component_id == spec.board_id {
        board_pin = board_pin_by_id(board, endpoint.pin_id);
        return board_pin.voltage if board_pin is not None else 0.0;
    }
    component = _component_by_id(spec, endpoint.component_id);
    if component is None {
        return 0.0;
    }
    try {
        part = get_part_profile(component.profile_id);
    } except ValueError {
        return 0.0;
    }
    part_pin = part_pin_by_id(part, endpoint.pin_id);
    return part_pin.voltage if part_pin is not None else 0.0;
}


def _validate_component_catalog(
    spec: HardwareSpec,
    issues: list[HardwareIssue],
) {
    seen_ids: set[str] = set();
    for component in spec.components {
        if component.component_id == spec.board_id {
            issues.append(HardwareIssue(
                code="COMPONENT_ID_RESERVED",
                severity="error",
                message=f"{component.component_id} is reserved for the board",
                reference=component.component_id,
            ));
        }
        if component.component_id in seen_ids {
            issues.append(HardwareIssue(
                code="DUPLICATE_COMPONENT_ID",
                severity="error",
                message=f"Duplicate component id {component.component_id}",
                reference=component.component_id,
            ));
        }
        seen_ids.add(component.component_id);
        try {
            _ = get_part_profile(component.profile_id);
        } except ValueError {
            issues.append(HardwareIssue(
                code="UNKNOWN_COMPONENT_PROFILE",
                severity="error",
                message=f"Unknown profile {component.profile_id}",
                reference=component.component_id,
            ));
        }
    }
}


def _validate_pin_assignments(
    spec: HardwareSpec,
    board: BoardProfile,
    issues: list[HardwareIssue],
) {
    seen_gpios: set[int] = set();
    seen_roles: set[str] = set();
    for assignment in spec.pin_assignments {
        board_pin = board_pin_by_gpio(board, assignment.gpio);
        if board_pin is None {
            issues.append(HardwareIssue(
                code="GPIO_NOT_ON_BOARD",
                severity="error",
                message=f"GPIO{assignment.gpio} is not exposed by {board.name}",
                reference=assignment.role,
            ));
            continue;
        }
        if assignment.gpio in seen_gpios {
            issues.append(HardwareIssue(
                code="DUPLICATE_GPIO_ASSIGNMENT",
                severity="error",
                message=f"GPIO{assignment.gpio} has multiple logical roles",
                reference=assignment.role,
            ));
        }
        if assignment.role in seen_roles {
            issues.append(HardwareIssue(
                code="DUPLICATE_PIN_ROLE",
                severity="error",
                message=f"Pin role {assignment.role} is assigned more than once",
                reference=assignment.role,
            ));
        }
        seen_gpios.add(assignment.gpio);
        seen_roles.add(assignment.role);
        if (
            board_pin.input_only
            and assignment.direction not in ["input", "input_pullup", "input_pulldown"]
        ) {
            issues.append(HardwareIssue(
                code="INPUT_ONLY_GPIO",
                severity="error",
                message=f"GPIO{assignment.gpio} is input-only",
                reference=assignment.role,
            ));
        }
        if board_pin.strapping {
            issues.append(HardwareIssue(
                code="BOOT_STRAPPING_GPIO",
                severity="error",
                message=(
                    f"GPIO{assignment.gpio} affects ESP32 boot strapping; "
                    "choose a safe application pin"
                ),
                reference=assignment.role,
            ));
        }
        if board_pin.reserved {
            issues.append(HardwareIssue(
                code="RESERVED_BOARD_PIN",
                severity="error",
                message=f"{board_pin.label} cannot be assigned as an application GPIO",
                reference=assignment.role,
            ));
        }
        component = _component_by_id(spec, assignment.component_id);
        if component is None {
            issues.append(HardwareIssue(
                code="ASSIGNMENT_COMPONENT_MISSING",
                severity="error",
                message=f"Pin role {assignment.role} targets a missing component",
                reference=assignment.component_id,
            ));
        }
        expected_net = _net_for_endpoint(
            spec,
            spec.board_id,
            board_pin.pin_id,
        );
        component_net = _net_for_endpoint(
            spec,
            assignment.component_id,
            assignment.component_pin,
        );
        if (
            expected_net is None
            or component_net is None
            or (
                expected_net.net_id != component_net.net_id
                and not _nets_share_series_resistor(
                    spec,
                    expected_net,
                    component_net,
                )
            )
        ) {
            issues.append(HardwareIssue(
                code="PIN_MAP_NET_MISMATCH",
                severity="error",
                message=(
                    f"{assignment.role} does not connect GPIO{assignment.gpio} "
                    f"to {assignment.component_id}.{assignment.component_pin}"
                ),
                reference=assignment.role,
            ));
        }
    }
}


def _validate_nets(
    spec: HardwareSpec,
    board: BoardProfile,
    issues: list[HardwareIssue],
) {
    seen_net_ids: set[str] = set();
    seen_endpoints: set[str] = set();
    board_ground_seen: bool = False;
    component_ground_seen: bool = False;
    for net in spec.nets {
        if net.net_id in seen_net_ids {
            issues.append(HardwareIssue(
                code="DUPLICATE_NET_ID",
                severity="error",
                message=f"Duplicate net id {net.net_id}",
                reference=net.net_id,
            ));
        }
        seen_net_ids.add(net.net_id);
        if len(net.endpoints) < 2 {
            issues.append(HardwareIssue(
                code="OPEN_NET",
                severity="error",
                message=f"Net {net.net_id} has fewer than two endpoints",
                reference=net.net_id,
            ));
        }
        voltages: list[float] = [];
        output_drivers: int = 0;
        for endpoint in net.endpoints {
            endpoint_key = f"{endpoint.component_id}.{endpoint.pin_id}";
            if endpoint_key in seen_endpoints {
                issues.append(HardwareIssue(
                    code="PIN_ON_MULTIPLE_NETS",
                    severity="error",
                    message=f"{endpoint_key} appears on multiple nets",
                    reference=endpoint_key,
                ));
            }
            seen_endpoints.add(endpoint_key);
            if endpoint.component_id == spec.board_id {
                board_pin = board_pin_by_id(board, endpoint.pin_id);
                if board_pin is None {
                    issues.append(HardwareIssue(
                        code="UNKNOWN_BOARD_PIN",
                        severity="error",
                        message=f"Unknown board pin {endpoint.pin_id}",
                        reference=endpoint_key,
                    ));
                    continue;
                }
                if board_pin.is_ground and net.role == "ground" {
                    board_ground_seen = True;
                }
                if board_pin.gpio >= 0 {
                    assignment = _pin_assignment_for_gpio(spec, board_pin.gpio);
                    if (
                        assignment is not None
                        and assignment.direction in ["output", "bidirectional"]
                    ) {
                        output_drivers += 1;
                    }
                }
            } else {
                component = _component_by_id(spec, endpoint.component_id);
                if component is None {
                    issues.append(HardwareIssue(
                        code="UNKNOWN_ENDPOINT_COMPONENT",
                        severity="error",
                        message=f"Unknown component {endpoint.component_id}",
                        reference=endpoint_key,
                    ));
                    continue;
                }
                try {
                    part = get_part_profile(component.profile_id);
                    part_pin = part_pin_by_id(part, endpoint.pin_id);
                    if part_pin is None {
                        issues.append(HardwareIssue(
                            code="UNKNOWN_COMPONENT_PIN",
                            severity="error",
                            message=f"Unknown pin {endpoint_key}",
                            reference=endpoint_key,
                        ));
                    } elif part_pin.drive == "output" {
                        output_drivers += 1;
                    }
                } except ValueError {
                    continue;
                }
                if net.role == "ground" {
                    component_ground_seen = True;
                }
            }
            voltage = _endpoint_voltage(spec, board, endpoint);
            if voltage > 0.0 {
                voltages.append(voltage);
            }
        }
        if len(voltages) > 1 and max(voltages) - min(voltages) > 0.2 {
            issues.append(HardwareIssue(
                code="VOLTAGE_DOMAIN_CONFLICT",
                severity="error",
                message=(
                    f"Net {net.net_id} mixes {min(voltages)}V and "
                    f"{max(voltages)}V endpoints"
                ),
                reference=net.net_id,
            ));
        }
        if output_drivers > 1 {
            issues.append(HardwareIssue(
                code="OUTPUT_DRIVER_CONFLICT",
                severity="error",
                message=f"Net {net.net_id} has multiple active output drivers",
                reference=net.net_id,
            ));
        }
    }
    if not board_ground_seen or not component_ground_seen {
        issues.append(HardwareIssue(
            code="COMMON_GROUND_MISSING",
            severity="error",
            message="The board and external components require a shared ground net",
            reference="ground",
        ));
    }
}


def _validate_component_requirements(
    spec: HardwareSpec,
    issues: list[HardwareIssue],
) {
    i2c_addresses: set[int] = set();
    for component in spec.components {
        if component.i2c_address >= 0 {
            if component.i2c_address in i2c_addresses {
                issues.append(HardwareIssue(
                    code="I2C_ADDRESS_COLLISION",
                    severity="error",
                    message=(
                        "Multiple I2C components use address "
                        f"0x{component.i2c_address:02x}"
                    ),
                    reference=component.component_id,
                ));
            }
            i2c_addresses.add(component.i2c_address);
        }
        if component.profile_id == "gy521-mpu6050" {
            for pin_id in ["VCC", "GND", "SCL", "SDA"] {
                net = _net_for_endpoint(spec, component.component_id, pin_id);
                if net is None {
                    issues.append(HardwareIssue(
                        code="MPU6050_REQUIRED_PIN_MISSING",
                        severity="error",
                        message=f"{component.label} requires {pin_id}",
                        reference=f"{component.component_id}.{pin_id}",
                    ));
                }
            }
        }
        if component.profile_id == "led-5mm-red" {
            anode_net = _net_for_endpoint(spec, component.component_id, "A");
            cathode_net = _net_for_endpoint(spec, component.component_id, "K");
            if (
                anode_net is None
                or not _net_has_profile(spec, anode_net, "resistor-220ohm")
            ) {
                issues.append(HardwareIssue(
                    code="LED_RESISTOR_MISSING",
                    severity="error",
                    message=(
                        f"{component.label} requires a series 220 ohm "
                        "current-limiting resistor"
                    ),
                    reference=component.component_id,
                ));
            }
            if cathode_net is None or cathode_net.role != "ground" {
                issues.append(HardwareIssue(
                    code="LED_POLARITY_INVALID",
                    severity="error",
                    message=f"{component.label} cathode must connect to ground",
                    reference=component.component_id,
                ));
            }
        }
        if component.profile_id == "button-6mm" {
            first_net = _net_for_endpoint(spec, component.component_id, "P1");
            second_net = _net_for_endpoint(spec, component.component_id, "P2");
            if (
                first_net is None
                or second_net is None
                or second_net.role != "ground"
            ) {
                issues.append(HardwareIssue(
                    code="BUTTON_WIRING_INVALID",
                    severity="error",
                    message=(
                        f"{component.label} must connect a pull-up input "
                        "to ground when pressed"
                    ),
                    reference=component.component_id,
                ));
            }
        }
    }
}


def _validate_breadboard_access(
    spec: HardwareSpec,
    board: BoardProfile,
    issues: list[HardwareIssue],
) {
    if (
        spec.board_profile_id != "doit-esp32-devkit-v1-30pin"
        or spec.breadboard_profile_id != "half-breadboard-400"
    ) {
        return;
    }
    for net in spec.nets {
        for endpoint in net.endpoints {
            if endpoint.component_id != spec.board_id {
                continue;
            }
            board_pin = board_pin_by_id(board, endpoint.pin_id);
            if board_pin is not None and board_pin.header_side != "right" {
                issues.append(HardwareIssue(
                    code="BREADBOARD_PIN_INACCESSIBLE",
                    severity="error",
                    message=(
                        f"{board_pin.label} is on the unsupported header side "
                        "for the one-header 400-point breadboard mount"
                    ),
                    reference=f"{endpoint.component_id}.{endpoint.pin_id}",
                ));
            }
        }
    }
}


def validate_hardware(spec: HardwareSpec) -> HardwareValidation {
    issues: list[HardwareIssue] = [];
    try {
        board = get_board_profile(spec.board_profile_id);
    } except ValueError {
        issues.append(HardwareIssue(
            code="UNKNOWN_BOARD_PROFILE",
            severity="error",
            message=f"Unknown board profile {spec.board_profile_id}",
            reference=spec.board_profile_id,
        ));
        return HardwareValidation(valid=False, issues=issues);
    }
    try {
        _ = get_breadboard_profile(spec.breadboard_profile_id);
    } except ValueError {
        issues.append(HardwareIssue(
            code="UNKNOWN_BREADBOARD_PROFILE",
            severity="error",
            message=f"Unknown breadboard profile {spec.breadboard_profile_id}",
            reference=spec.breadboard_profile_id,
        ));
    }
    _validate_component_catalog(spec, issues);
    _validate_pin_assignments(spec, board, issues);
    _validate_nets(spec, board, issues);
    _validate_component_requirements(spec, issues);
    _validate_breadboard_access(spec, board, issues);
    return HardwareValidation(
        valid=not `any(issue.severity == "error" for issue in issues),
        issues=issues,
    );
}


def _endpoint_model(endpoint: Endpoint) -> dict[str, object] {
    return {
        "component_id": endpoint.component_id,
        "pin_id": endpoint.pin_id,
    };
}


"""Convert the internal typed model at the artifact/API boundary."""
def hardware_spec_model(spec: HardwareSpec) -> dict[str, object] {
    component_models: list[dict[str, object]] = [];
    assignment_models: list[dict[str, object]] = [];
    net_models: list[dict[str, object]] = [];
    for component in spec.components {
        component_models.append({
            "component_id": component.component_id,
            "profile_id": component.profile_id,
            "label": component.label,
            "i2c_address": component.i2c_address,
        });
    }
    for assignment in spec.pin_assignments {
        assignment_models.append({
            "role": assignment.role,
            "gpio": assignment.gpio,
            "component_id": assignment.component_id,
            "component_pin": assignment.component_pin,
            "direction": assignment.direction,
        });
    }
    for net in spec.nets {
        endpoint_models: list[dict[str, object]] = [
            _endpoint_model(endpoint) for endpoint in net.endpoints
        ];
        net_models.append({
            "net_id": net.net_id,
            "role": net.role,
            "endpoints": endpoint_models,
        });
    }
    return {
        "schema_version": spec.schema_version,
        "project_id": spec.project_id,
        "title": spec.title,
        "behavior": spec.behavior,
        "board_id": spec.board_id,
        "board_profile_id": spec.board_profile_id,
        "breadboard_profile_id": spec.breadboard_profile_id,
        "components": component_models,
        "pin_assignments": assignment_models,
        "nets": net_models,
        "expected_events": spec.expected_events,
    };
}


def hardware_spec_json(spec: HardwareSpec) -> str {
    return json.dumps(
        hardware_spec_model(spec),
        sort_keys=True,
        indent=2,
    ) as str;
}
