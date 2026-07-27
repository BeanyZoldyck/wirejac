"""Deterministic breadboard placement, routing, and assembly compilation."""

import from hardware.catalog.profiles {
    BoardProfile,
    get_board_profile,
    get_breadboard_profile,
    get_part_profile,
}
import from hardware.circuit {
    ComponentInstance,
    ElectricalNet,
    Endpoint,
    HardwareSpec,
    validate_hardware,
}


obj HolePosition {
    has x: int,
        y: int;
}


obj PinHole {
    has component_id: str,
        pin_id: str,
        hole: str;
}


obj Placement {
    has placement_id: str,
        component_id: str,
        profile_id: str,
        label: str,
        anchors: list[PinHole],
        x: int,
        y: int,
        width: int,
        height: int;
    has rotation: int = 0;
}


obj RoutePoint {
    has x: int,
        y: int;
}


obj WireRoute {
    has route_id: str,
        net_id: str,
        role: str,
        from_hole: str,
        to_hole: str,
        color: str,
        points: list[RoutePoint];
}


obj AssemblyStep {
    has number: int,
        title: str,
        instruction: str,
        visible_placement_ids: list[str],
        visible_route_ids: list[str],
        highlight_ids: list[str];
    has warnings: list[str] = [];
}


obj AssemblyPlan {
    has schema_version: str,
        project_id: str,
        breadboard_profile_id: str,
        placements: list[Placement],
        routes: list[WireRoute],
        steps: list[AssemblyStep];
}


def _terminal_column_y(column: str) -> int {
    columns: dict[str, int] = {
        "A": 92,
        "B": 110,
        "C": 128,
        "D": 146,
        "E": 164,
        "F": 208,
        "G": 226,
        "H": 244,
        "I": 262,
        "J": 280,
    };
    return columns.get(column, 0);
}


def _hole_row(hole: str) -> int {
    if hole.startswith(("TP", "TN", "BP", "BN")) {
        return int(hole[2:]);
    }
    return int(hole[1:]);
}


"""Translate canonical breadboard hole ids to stable canvas coordinates."""
def hole_position(hole: str) -> HolePosition {
    row = _hole_row(hole);
    x = 52 + (row - 1) * 20;
    if hole.startswith("TP") {
        return HolePosition(x=x, y=42);
    }
    if hole.startswith("TN") {
        return HolePosition(x=x, y=62);
    }
    if hole.startswith("BP") {
        return HolePosition(x=x, y=310);
    }
    if hole.startswith("BN") {
        return HolePosition(x=x, y=330);
    }
    return HolePosition(x=x, y=_terminal_column_y(hole[0]));
}


"""Return whether two holes are internally connected by the breadboard."""
def holes_share_strip(first: str, second: str) -> bool {
    rail_prefixes: list[str] = ["TP", "TN", "BP", "BN"];
    for prefix in rail_prefixes {
        if first.startswith(prefix) and second.startswith(prefix) {
            return True;
        }
    }
    if (
        first.startswith(tuple(rail_prefixes))
        or second.startswith(tuple(rail_prefixes))
    ) {
        return False;
    }
    if _hole_row(first) != _hole_row(second) {
        return False;
    }
    first_left = first[0] in "ABCDE";
    second_left = second[0] in "ABCDE";
    return first_left == second_left;
}


def _board_placement(spec: HardwareSpec, board: BoardProfile) -> Placement {
    anchors: list[PinHole] = [];
    for pin in board.pins {
        # A full-width DevKit hides both strip edges on this half breadboard.
        # Mount only the used right header in J and overhang the board body.
        if pin.header_side == "right" {
            anchors.append(PinHole(
                component_id=spec.board_id,
                pin_id=pin.pin_id,
                hole=f"J{pin.header_row}",
            ));
        }
    }
    return Placement(
        placement_id="place-esp32",
        component_id=spec.board_id,
        profile_id=board.profile_id,
        label=board.name,
        anchors=anchors,
        x=38,
        y=270,
        width=308,
        height=160,
    );
}


def _part_placement(component: ComponentInstance) -> Placement {
    if component.profile_id == "gy521-mpu6050" {
        pin_ids: list[str] = [
            "VCC", "GND", "SCL", "SDA", "XDA", "XCL", "AD0", "INT"
        ];
        anchors: list[PinHole] = [];
        for (index, pin_id) in enumerate(pin_ids) {
            anchors.append(PinHole(
                component_id=component.component_id,
                pin_id=pin_id,
                hole=f"J{18 + index}",
            ));
        }
        return Placement(
            placement_id=f"place-{component.component_id}",
            component_id=component.component_id,
            profile_id=component.profile_id,
            label=component.label,
            anchors=anchors,
            x=380,
            y=268,
            width=166,
            height=36,
        );
    }
    if component.profile_id == "resistor-220ohm" {
        return Placement(
            placement_id=f"place-{component.component_id}",
            component_id=component.component_id,
            profile_id=component.profile_id,
            label=component.label,
            anchors=[
                PinHole(component.component_id, "P1", "B20"),
                PinHole(component.component_id, "P2", "B24"),
            ],
            x=425,
            y=99,
            width=86,
            height=22,
        );
    }
    if component.profile_id == "led-5mm-red" {
        return Placement(
            placement_id=f"place-{component.component_id}",
            component_id=component.component_id,
            profile_id=component.profile_id,
            label=component.label,
            anchors=[
                PinHole(component.component_id, "A", "A24"),
                PinHole(component.component_id, "K", "A25"),
            ],
            x=505,
            y=78,
            width=34,
            height=34,
        );
    }
    if component.profile_id == "button-6mm" {
        return Placement(
            placement_id=f"place-{component.component_id}",
            component_id=component.component_id,
            profile_id=component.profile_id,
            label=component.label,
            anchors=[
                # Verified demo orientation: both live leads use the same
                # physical button side while remaining on separate rows.
                PinHole(component.component_id, "P1", "I17"),
                PinHole(component.component_id, "P2", "I16"),
            ],
            x=332,
            y=220,
            width=58,
            height=42,
        );
    }
    raise ValueError(f"No placement template for {component.profile_id}");
}


def _placement_for_component(
    placements: list[Placement],
    component_id: str,
) -> Placement | None {
    for placement in placements {
        if placement.component_id == component_id {
            return placement;
        }
    }
    return None;
}


def _anchor_for_endpoint(
    placements: list[Placement],
    endpoint: Endpoint,
) -> PinHole | None {
    placement = _placement_for_component(placements, endpoint.component_id);
    if placement is None {
        return None;
    }
    for anchor in placement.anchors {
        if anchor.pin_id == endpoint.pin_id {
            return anchor;
        }
    }
    return None;
}


def _attachment_hole(placement: Placement, anchor: PinHole) -> str {
    hole = anchor.hole;
    row = _hole_row(hole);
    if placement.profile_id == "doit-esp32-devkit-v1-30pin" {
        return f"I{row}";
    }
    if placement.profile_id == "gy521-mpu6050" {
        return f"I{row}";
    }
    if placement.profile_id == "resistor-220ohm" {
        return f"C{row}";
    }
    if placement.profile_id == "led-5mm-red" {
        return f"A{row}";
    }
    if placement.profile_id == "button-6mm" {
        # Both live jumpers exit the verified physical side of the button.
        return f"H{row}";
    }
    return hole;
}


def _wire_color(role: str) -> str {
    if role == "power_3v3" {
        return "#d62828";
    }
    if role == "ground" {
        return "#202124";
    }
    if role == "i2c_sda" {
        return "#2a9d55";
    }
    if role == "i2c_scl" {
        return "#e0a100";
    }
    if role.startswith("digital_input") {
        return "#2474d2";
    }
    if role.startswith("digital_output") {
        return "#ef7d22";
    }
    return "#6b7280";
}


def _wire_color_name(role: str) -> str {
    if role == "power_3v3" {
        return "red";
    }
    if role == "ground" {
        return "black";
    }
    if role == "i2c_sda" {
        return "green";
    }
    if role == "i2c_scl" {
        return "yellow";
    }
    if role.startswith("digital_input") {
        return "blue";
    }
    if role.startswith("digital_output") {
        return "orange";
    }
    return "gray";
}


def _route_points(
    from_hole: str,
    to_hole: str,
    lane: int,
) -> list[RoutePoint] {
    start = hole_position(from_hole);
    end = hole_position(to_hole);
    # Keep the button ground jumper outside the button body in the SVG.
    if from_hole == "H16" and to_hole == "TN16" {
        return [
            RoutePoint(start.x, start.y),
            RoutePoint(426, start.y),
            RoutePoint(426, end.y),
            RoutePoint(end.x, end.y),
        ];
    }
    if start.x == end.x or start.y == end.y {
        return [
            RoutePoint(start.x, start.y),
            RoutePoint(end.x, end.y),
        ];
    }
    lane_offset = (lane % 4) * 4;
    bend_y = start.y + lane_offset;
    return [
        RoutePoint(start.x, start.y),
        RoutePoint(start.x, bend_y),
        RoutePoint(end.x, bend_y),
        RoutePoint(end.x, end.y),
    ];
}


def _power_routes(
    net: ElectricalNet,
    placements: list[Placement],
    start_index: int,
) -> list[WireRoute] {
    routes: list[WireRoute] = [];
    prefix = "TP" if net.role == "power_3v3" else "TN";
    for (index, endpoint) in enumerate(net.endpoints) {
        anchor = _anchor_for_endpoint(placements, endpoint);
        if anchor is None {
            continue;
        }
        placement = _placement_for_component(placements, endpoint.component_id);
        if placement is None {
            continue;
        }
        source = _attachment_hole(placement, anchor);
        destination = f"{prefix}{_hole_row(anchor.hole)}";
        route_number = start_index + index;
        routes.append(WireRoute(
            route_id=f"wire-{net.net_id}-{index + 1}",
            net_id=net.net_id,
            role=net.role,
            from_hole=source,
            to_hole=destination,
            color=_wire_color(net.role),
            points=_route_points(source, destination, route_number),
        ));
    }
    return routes;
}


def _signal_routes(
    net: ElectricalNet,
    placements: list[Placement],
    start_index: int,
) -> list[WireRoute] {
    routes: list[WireRoute] = [];
    if len(net.endpoints) < 2 {
        return routes;
    }
    source_endpoint = net.endpoints[0];
    source_anchor = _anchor_for_endpoint(placements, source_endpoint);
    source_placement = _placement_for_component(
        placements,
        source_endpoint.component_id,
    );
    if source_anchor is None or source_placement is None {
        return routes;
    }
    source_hole = _attachment_hole(source_placement, source_anchor);
    for (index, endpoint) in enumerate(net.endpoints[1:]) {
        target_anchor = _anchor_for_endpoint(placements, endpoint);
        target_placement = _placement_for_component(
            placements,
            endpoint.component_id,
        );
        if target_anchor is None or target_placement is None {
            continue;
        }
        if holes_share_strip(source_anchor.hole, target_anchor.hole) {
            continue;
        }
        target_hole = _attachment_hole(target_placement, target_anchor);
        route_number = start_index + index;
        routes.append(WireRoute(
            route_id=f"wire-{net.net_id}-{index + 1}",
            net_id=net.net_id,
            role=net.role,
            from_hole=source_hole,
            to_hole=target_hole,
            color=_wire_color(net.role),
            points=_route_points(source_hole, target_hole, route_number),
        ));
    }
    return routes;
}


def _placement_instruction(placement: Placement) -> str {
    if placement.profile_id == "doit-esp32-devkit-v1-30pin" {
        return (
            "Insert only the ESP32 right header along J1-J15: GPIO23 in J1, "
            "GPIO22 in J2, GPIO21 in J5, GND in J14, and 3V3 in J15. The "
            "board body and unused left header overhang past the J edge; keep "
            "the USB connector past the row-15 end and support the overhang."
        );
    }
    if placement.profile_id == "gy521-mpu6050" {
        return (
            "Insert the GY-521 header along J18-J25: VCC in J18, GND "
            "in J19, SCL in J20, SDA in J21, and INT in J25."
        );
    }
    if placement.profile_id == "resistor-220ohm" {
        return (
            "Place the 220 ohm resistor from B20 to B24. Its lead at "
            "B24 shares the row strip with the LED anode at A24."
        );
    }
    if placement.profile_id == "led-5mm-red" {
        return (
            "Place the LED long anode leg in A24 and short cathode leg "
            "in A25. Do not reverse the LED."
        );
    }
    if placement.profile_id == "button-6mm" {
        return (
            "Place the recording button between the ESP32 and GY-521. Put "
            "its black-ground leg in I16, directly beside ESP32 3V3 at J15, "
            "and its blue GPIO19 leg in I17 on the same physical button side. "
            "Leave the opposite-side legs unused."
        );
    }
    return f"Place {placement.label} at its highlighted holes.";
}


def _route_instruction(route: WireRoute) -> str {
    if route.net_id == "button_input" {
        return (
            "Connect I6 to H17 with the blue GPIO19 jumper. Attach it to "
            "the same physical side of the button as the black ground lead; "
            "do not use the visually opposite button side."
        );
    }
    if route.from_hole == "H16" and route.to_hole == "TN16" {
        return (
            "Connect H16 to TN16 with the black ground jumper. H16 is the "
            "button ground lead beside ESP32 3V3 at J15."
        );
    }
    return (
        f"Connect {route.from_hole} to {route.to_hole} with a "
        f"{_wire_color_name(route.role)} jumper. "
        f"This is the {route.net_id} net."
    );
}


def _build_steps(
    placements: list[Placement],
    routes: list[WireRoute],
) -> list[AssemblyStep] {
    steps: list[AssemblyStep] = [];
    visible_placements: list[str] = [];
    visible_routes: list[str] = [];
    step_number: int = 1;
    steps.append(AssemblyStep(
        number=step_number,
        title="Disconnect power",
        instruction=(
            "Unplug the ESP32 USB cable. Build and inspect the entire "
            "breadboard before applying power."
        ),
        visible_placement_ids=[],
        visible_route_ids=[],
        highlight_ids=[],
        warnings=["Never move breadboard wiring while USB power is connected."],
    ));
    step_number += 1;
    for placement in placements {
        visible_placements.append(placement.placement_id);
        steps.append(AssemblyStep(
            number=step_number,
            title=f"Place {placement.label}",
            instruction=_placement_instruction(placement),
            visible_placement_ids=visible_placements.copy(),
            visible_route_ids=visible_routes.copy(),
            highlight_ids=[placement.placement_id],
        ));
        step_number += 1;
    }
    for route in routes {
        visible_routes.append(route.route_id);
        steps.append(AssemblyStep(
            number=step_number,
            title=f"Wire {route.net_id}",
            instruction=_route_instruction(route),
            visible_placement_ids=visible_placements.copy(),
            visible_route_ids=visible_routes.copy(),
            highlight_ids=[route.route_id],
        ));
        step_number += 1;
    }
    has_led = any(
        placement.profile_id == "led-5mm-red"
        for placement in placements
    );
    has_imu = any(
        placement.profile_id == "gy521-mpu6050"
        for placement in placements
    );
    has_button = any(
        placement.profile_id == "button-6mm"
        for placement in placements
    );
    inspection = (
        "Confirm the red 3.3V rail never touches a ground rail and every "
        "highlighted endpoint matches the completed diagram."
    );
    if has_led {
        inspection = (
            "Confirm the red 3.3V rail never touches a ground rail, the "
            "LED cathode is in A25, and every highlighted endpoint matches "
            "the completed diagram."
        );
    }
    verification = "It must identify the ESP32";
    if has_imu {
        verification += " and find the MPU6050 at 0x68";
    }
    verification += ", then receive ready and heartbeat events.";
    if has_button {
        inspection += (
            " Confirm the black ground lead is H16 to TN16 and the blue "
            "GPIO19 lead is I6 to H17. They leave the same physical side of "
            "the button but occupy separate breadboard rows."
        );
        verification += " Press the button and verify its expected device event.";
    }
    steps.append(AssemblyStep(
        number=step_number,
        title="Inspect before power",
        instruction=inspection,
        visible_placement_ids=visible_placements.copy(),
        visible_route_ids=visible_routes.copy(),
        highlight_ids=[],
        warnings=["Stop if any wire or component is warm, damaged, or uncertain."],
    ));
    step_number += 1;
    steps.append(AssemblyStep(
        number=step_number,
        title="Connect and verify",
        instruction=(
            "Connect USB, then run the WireJac physical verification. "
            + verification
        ),
        visible_placement_ids=visible_placements.copy(),
        visible_route_ids=visible_routes.copy(),
        highlight_ids=[],
    ));
    return steps;
}


def _assert_unique_holes(placements: list[Placement]) {
    occupied: set[str] = set();
    for placement in placements {
        for anchor in placement.anchors {
            if anchor.hole in occupied {
                raise ValueError(
                    f"Breadboard hole collision at {anchor.hole}"
                );
            }
            occupied.add(anchor.hole);
        }
    }
}


"""Compile a validated netlist into deterministic physical artifacts."""
def compile_breadboard(spec: HardwareSpec) -> AssemblyPlan {
    validation = validate_hardware(spec);
    if not validation.valid {
        messages = [
            f"{issue.code}: {issue.message}"
            for issue in validation.issues
            if issue.severity == "error"
        ];
        raise ValueError(
            "Cannot lay out an invalid circuit: " + "; ".join(messages)
        );
    }
    _ = get_breadboard_profile(spec.breadboard_profile_id);
    board = get_board_profile(spec.board_profile_id);
    placements: list[Placement] = [_board_placement(spec, board)];
    for component in spec.components {
        _ = get_part_profile(component.profile_id);
        placements.append(_part_placement(component));
    }
    _assert_unique_holes(placements);
    routes: list[WireRoute] = [];
    route_index: int = 0;
    for net in spec.nets {
        if net.role in ["power_3v3", "ground"] {
            net_routes = _power_routes(net, placements, route_index);
        } else {
            net_routes = _signal_routes(net, placements, route_index);
        }
        routes.extend(net_routes);
        route_index += len(net_routes);
    }
    return AssemblyPlan(
        schema_version="wirejac.assembly.v1",
        project_id=spec.project_id,
        breadboard_profile_id=spec.breadboard_profile_id,
        placements=placements,
        routes=routes,
        steps=_build_steps(placements, routes),
    );
}
