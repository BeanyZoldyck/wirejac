"""UI-neutral visualization, cumulative SVG, and Wokwi artifact exports."""

import json;
import from hardware.catalog.profiles {
    get_board_profile,
    get_breadboard_profile,
    get_part_profile,
}
import from hardware.circuit {
    ElectricalNet,
    Endpoint,
    HardwareSpec,
    hardware_spec_json,
}
import from hardware.breadboard {
    AssemblyPlan,
    AssemblyStep,
    PinHole,
    Placement,
    WireRoute,
    hole_position,
}


obj VisualizationBundle {
    has schema_version: str,
        project_id: str,
        hardware_spec_json: str,
        visualization_json: str,
        assembly_json: str,
        wokwi_diagram_json: str,
        step_filenames: list[str],
        step_svgs: list[str];
}


def _point_model(x: int, y: int) -> dict[str, object] {
    return {"x": x, "y": y};
}


def _anchor_model(anchor: PinHole) -> dict[str, object] {
    position = hole_position(anchor.hole);
    return {
        "component_id": anchor.component_id,
        "pin_id": anchor.pin_id,
        "hole": anchor.hole,
        "x": position.x,
        "y": position.y,
    };
}


def _placement_model(placement: Placement) -> dict[str, object] {
    anchors: list[dict[str, object]] = [
        _anchor_model(anchor) for anchor in placement.anchors
    ];
    return {
        "placement_id": placement.placement_id,
        "component_id": placement.component_id,
        "profile_id": placement.profile_id,
        "label": placement.label,
        "x": placement.x,
        "y": placement.y,
        "width": placement.width,
        "height": placement.height,
        "rotation": placement.rotation,
        "anchors": anchors,
    };
}


def _route_model(route: WireRoute) -> dict[str, object] {
    points: list[dict[str, object]] = [
        _point_model(point.x, point.y) for point in route.points
    ];
    return {
        "route_id": route.route_id,
        "net_id": route.net_id,
        "role": route.role,
        "from_hole": route.from_hole,
        "to_hole": route.to_hole,
        "color": route.color,
        "points": points,
    };
}


def _step_model(step: AssemblyStep) -> dict[str, object] {
    return {
        "number": step.number,
        "title": step.title,
        "instruction": step.instruction,
        "warnings": step.warnings,
        "visible_placement_ids": step.visible_placement_ids,
        "visible_route_ids": step.visible_route_ids,
        "highlight_ids": step.highlight_ids,
        "svg": f"step-{step.number:02d}.svg",
    };
}


def visualization_model(
    spec: HardwareSpec,
    plan: AssemblyPlan,
) -> dict[str, object] {
    placements: list[dict[str, object]] = [
        _placement_model(placement) for placement in plan.placements
    ];
    routes: list[dict[str, object]] = [
        _route_model(route) for route in plan.routes
    ];
    steps: list[dict[str, object]] = [
        {
            "number": step.number,
            "title": step.title,
            "visible_placement_ids": step.visible_placement_ids,
            "visible_route_ids": step.visible_route_ids,
            "highlight_ids": step.highlight_ids,
            "svg": f"step-{step.number:02d}.svg",
        }
        for step in plan.steps
    ];
    return {
        "schema_version": "wirejac.visualization.v1",
        "project_id": spec.project_id,
        "canvas": {
            "width": 680,
            "height": 550,
            "coordinate_system": "wirejac-breadboard-v1",
        },
        "breadboard": {
            "profile_id": plan.breadboard_profile_id,
            "terminal_rows": 30,
            "terminal_columns": "ABCDEFGHIJ",
            "rails": ["TP", "TN", "BP", "BN"],
        },
        "placements": placements,
        "routes": routes,
        "steps": steps,
        "wire_color_legend": {
            "power_3v3": "#d62828",
            "ground": "#202124",
            "i2c_sda": "#2a9d55",
            "i2c_scl": "#e0a100",
            "digital_input": "#2474d2",
            "digital_output": "#ef7d22",
        },
    };
}


def assembly_model(plan: AssemblyPlan) -> dict[str, object] {
    steps: list[dict[str, object]] = [
        _step_model(step) for step in plan.steps
    ];
    return {
        "schema_version": plan.schema_version,
        "project_id": plan.project_id,
        "breadboard_profile_id": plan.breadboard_profile_id,
        "steps": steps,
    };
}


def _find_placement(
    plan: AssemblyPlan,
    component_id: str,
) -> Placement | None {
    for placement in plan.placements {
        if placement.component_id == component_id {
            return placement;
        }
    }
    return None;
}


def _find_anchor(
    plan: AssemblyPlan,
    endpoint: Endpoint,
) -> PinHole | None {
    placement = _find_placement(plan, endpoint.component_id);
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


def _wokwi_breadboard_pin(hole: str) -> str {
    if hole.startswith("TP") {
        return f"tp.{hole[2:]}";
    }
    if hole.startswith("TN") {
        return f"tn.{hole[2:]}";
    }
    if hole.startswith("BP") {
        return f"bp.{hole[2:]}";
    }
    if hole.startswith("BN") {
        return f"bn.{hole[2:]}";
    }
    row = hole[1:];
    column = hole[0].lower();
    section = "t" if hole[0] in "ABCDE" else "b";
    return f"{row}{section}.{column}";
}


def _wokwi_component_pin(
    spec: HardwareSpec,
    endpoint: Endpoint,
) -> str {
    if endpoint.component_id == spec.board_id {
        if endpoint.pin_id == "GND" {
            return "GND.2";
        }
        if endpoint.pin_id == "GND_R" {
            return "GND.1";
        }
        if endpoint.pin_id.startswith("GPIO") {
            return "D" + endpoint.pin_id[4:];
        }
        return endpoint.pin_id;
    }
    placement_id = endpoint.component_id;
    profile_id: str = "";
    for component in spec.components {
        if component.component_id == placement_id {
            profile_id = component.profile_id;
            break;
        }
    }
    if profile_id == "led-5mm-red" {
        return "A" if endpoint.pin_id == "A" else "C";
    }
    if profile_id == "resistor-220ohm" {
        return "1" if endpoint.pin_id == "P1" else "2";
    }
    if profile_id == "button-6mm" {
        return "1.l" if endpoint.pin_id == "P1" else "2.l";
    }
    return endpoint.pin_id;
}


def _wokwi_attrs(profile_id: str) -> dict[str, object] {
    if profile_id == "doit-esp32-devkit-v1-30pin" {
        return {
            "env": "micropython-20260406-v1.28.0",
            "script": "main.py",
        };
    }
    if profile_id == "half-breadboard-400" {
        return {"color": "#f5f5f2"};
    }
    if profile_id == "led-5mm-red" {
        return {"color": "red"};
    }
    if profile_id == "resistor-220ohm" {
        return {"value": "220"};
    }
    if profile_id == "button-6mm" {
        return {"color": "green", "xray": "1"};
    }
    if profile_id == "gy521-mpu6050" {
        return {"i2cAddress": "0x68"};
    }
    return {};
}


def _wokwi_parts(
    spec: HardwareSpec,
    plan: AssemblyPlan,
) -> list[dict[str, object]] {
    breadboard = get_breadboard_profile(spec.breadboard_profile_id);
    parts: list[dict[str, object]] = [{
        "type": breadboard.wokwi_type,
        "id": "bb1",
        "top": 0,
        "left": 0,
        "attrs": _wokwi_attrs(breadboard.profile_id),
    }];
    board = get_board_profile(spec.board_profile_id);
    board_placement = _find_placement(plan, spec.board_id);
    if board_placement is not None {
        parts.append({
            "type": board.wokwi_type,
            "id": spec.board_id,
            "top": board_placement.y,
            "left": board_placement.x,
            "rotate": board_placement.rotation,
            "attrs": _wokwi_attrs(board.profile_id),
        });
    }
    for component in spec.components {
        profile = get_part_profile(component.profile_id);
        placement = _find_placement(plan, component.component_id);
        if placement is None {
            continue;
        }
        parts.append({
            "type": profile.wokwi_type,
            "id": component.component_id,
            "top": placement.y,
            "left": placement.x,
            "rotate": placement.rotation,
            "attrs": _wokwi_attrs(profile.profile_id),
        });
    }
    return parts;
}


def _connection(
    first: str,
    second: str,
    color: str,
    routing: list[str],
) -> list[object] {
    return [first, second, color, routing];
}


def _wokwi_connections(
    spec: HardwareSpec,
    plan: AssemblyPlan,
) -> list[list[object]] {
    connections: list[list[object]] = [];
    seen_endpoints: set[str] = set();
    for net in spec.nets {
        for endpoint in net.endpoints {
            endpoint_key = f"{endpoint.component_id}.{endpoint.pin_id}";
            if endpoint_key in seen_endpoints {
                continue;
            }
            seen_endpoints.add(endpoint_key);
            anchor = _find_anchor(plan, endpoint);
            if anchor is None {
                continue;
            }
            connections.append(_connection(
                f"{endpoint.component_id}:{_wokwi_component_pin(spec, endpoint)}",
                f"bb1:{_wokwi_breadboard_pin(anchor.hole)}",
                "",
                ["$bb"],
            ));
        }
    }
    for route in plan.routes {
        connections.append(_connection(
            f"bb1:{_wokwi_breadboard_pin(route.from_hole)}",
            f"bb1:{_wokwi_breadboard_pin(route.to_hole)}",
            route.color,
            [],
        ));
    }
    return connections;
}


def wokwi_diagram_model(
    spec: HardwareSpec,
    plan: AssemblyPlan,
) -> dict[str, object] {
    return {
        "version": 1,
        "author": "WireJac hardware agent",
        "editor": "wokwi",
        "parts": _wokwi_parts(spec, plan),
        "connections": _wokwi_connections(spec, plan),
        "dependencies": {},
    };
}


def _xml_escape(value: str) -> str {
    return (
        value.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    );
}


def _svg_breadboard -> str {
    elements: list[str] = [
        '<rect x="20" y="22" width="640" height="326" rx="7" ',
        'fill="#f7f7f4" stroke="#9aa0a6" stroke-width="2"/>',
        '<line x1="42" y1="42" x2="642" y2="42" stroke="#d62828" ',
        'stroke-width="3"/>',
        '<line x1="42" y1="62" x2="642" y2="62" stroke="#202124" ',
        'stroke-width="3"/>',
        '<line x1="42" y1="310" x2="642" y2="310" stroke="#d62828" ',
        'stroke-width="3"/>',
        '<line x1="42" y1="330" x2="642" y2="330" stroke="#202124" ',
        'stroke-width="3"/>',
        '<rect x="42" y="181" width="600" height="10" fill="#d9dcdf"/>',
    ];
    for row in range(1, 31) {
        x = 52 + (row - 1) * 20;
        elements.append(
            (
                '<text x="{}" y="82" text-anchor="middle" '
                'font-family="sans-serif" font-size="8" fill="#5f6368">'
                "{}</text>"
            ).format(x, row)
        );
        for column in "ABCDEFGHIJ" {
            position = hole_position(f"{column}{row}");
            elements.append(
                '<circle cx="{}" cy="{}" r="3" fill="#4f5458"/>'.format(
                    position.x,
                    position.y
                )
            );
        }
        for rail in ["TP", "TN", "BP", "BN"] {
            position = hole_position(f"{rail}{row}");
            elements.append(
                '<circle cx="{}" cy="{}" r="2.6" fill="#6b7075"/>'.format(
                    position.x,
                    position.y
                )
            );
        }
    }
    return "".join(elements);
}


def _svg_placement(placement: Placement, highlighted: bool) -> str {
    stroke = "#00a86b" if highlighted else "#303438";
    stroke_width = 4 if highlighted else 2;
    label = _xml_escape(placement.label);
    if placement.profile_id == "doit-esp32-devkit-v1-30pin" {
        elements: list[str] = [
            '<g id="{}">'.format(placement.placement_id),
            (
                '<rect x="{}" y="{}" width="{}" height="{}" rx="5" '
                'fill="#167d68" stroke="{}" stroke-width="{}"/>'
            ).format(
                placement.x,
                placement.y,
                placement.width,
                placement.height,
                stroke,
                stroke_width
            ),
            (
                '<rect x="{}" y="{}" width="42" height="32" rx="2" '
                'fill="#c8cdd0"/>'
            ).format(placement.x + 258, placement.y + 92),
            (
                '<text x="{}" y="{}" text-anchor="middle" '
                'font-family="sans-serif" font-size="13" font-weight="700" '
                'fill="white">{}</text>'
            ).format(placement.x + 154, placement.y + 92, label),
            (
                '<text x="{}" y="{}" text-anchor="middle" '
                'font-family="sans-serif" font-size="10" fill="white">'
                "Right header in J1-J15; board overhangs</text>"
            ).format(placement.x + 154, placement.y + 113),
        ];
        for anchor in placement.anchors {
            position = hole_position(anchor.hole);
            elements.extend([
                (
                    '<circle cx="{}" cy="{}" r="4.5" fill="#d9c06c" '
                    'stroke="#202124" stroke-width="1"/>'
                ).format(position.x, position.y),
                (
                    '<text x="{}" y="{}" text-anchor="end" '
                    'transform="rotate(-90 {} {})" font-family="sans-serif" '
                    'font-size="7" fill="white">{}</text>'
                ).format(
                    position.x,
                    placement.y + 25,
                    position.x,
                    placement.y + 25,
                    _xml_escape(anchor.pin_id)
                ),
            ]);
        }
        elements.append("</g>");
        return "".join(elements);
    }
    if placement.profile_id == "gy521-mpu6050" {
        return "".join([
            '<g id="{}">'.format(placement.placement_id),
            (
                '<rect x="{}" y="{}" width="{}" height="{}" rx="3" '
                'fill="#2b67a3" stroke="{}" stroke-width="{}"/>'
            ).format(
                placement.x,
                placement.y,
                placement.width,
                placement.height,
                stroke,
                stroke_width
            ),
            (
                '<rect x="{}" y="{}" width="26" height="22" '
                'fill="#202124"/>'
            ).format(placement.x + 62, placement.y + 7),
            (
                '<text x="{}" y="{}" text-anchor="middle" '
                'font-family="sans-serif" font-size="9" '
                'fill="white">{}</text></g>'
            ).format(placement.x + 128, placement.y + 22, label),
        ]);
    }
    if placement.profile_id == "resistor-220ohm" {
        return "".join([
            '<g id="{}">'.format(placement.placement_id),
            (
                '<line x1="{}" y1="{}" x2="{}" y2="{}" '
                'stroke="#6f7377" stroke-width="3"/>'
            ).format(
                placement.x,
                placement.y + 11,
                placement.x + placement.width,
                placement.y + 11
            ),
            (
                '<rect x="{}" y="{}" width="38" height="18" rx="8" '
                'fill="#d7b47a" stroke="{}" stroke-width="{}"/>'
            ).format(
                placement.x + 24,
                placement.y + 2,
                stroke,
                stroke_width
            ),
            (
                '<text x="{}" y="{}" text-anchor="middle" '
                'font-family="sans-serif" font-size="10" '
                'fill="#202124">220 ohm</text></g>'
            ).format(placement.x + 43, placement.y - 4),
        ]);
    }
    if placement.profile_id == "led-5mm-red" {
        return "".join([
            '<g id="{}">'.format(placement.placement_id),
            (
                '<circle cx="{}" cy="{}" r="13" fill="#ed3b3b" '
                'fill-opacity="0.82" stroke="{}" stroke-width="{}"/>'
            ).format(
                placement.x + 17,
                placement.y + 17,
                stroke,
                stroke_width
            ),
            (
                '<text x="{}" y="{}" text-anchor="middle" '
                'font-family="sans-serif" font-size="10" '
                'fill="#202124">LED</text></g>'
            ).format(placement.x + 17, placement.y - 4),
        ]);
    }
    if placement.profile_id == "button-6mm" {
        return "".join([
            '<g id="{}">'.format(placement.placement_id),
            (
                '<rect x="{}" y="{}" width="{}" height="{}" rx="4" '
                'fill="#565b60" stroke="{}" stroke-width="{}"/>'
            ).format(
                placement.x,
                placement.y,
                placement.width,
                placement.height,
                stroke,
                stroke_width
            ),
            (
                '<circle cx="{}" cy="{}" r="12" fill="#afb4b8"/>'
            ).format(placement.x + 24, placement.y + 21),
            (
                '<text x="{}" y="{}" text-anchor="middle" '
                'font-family="sans-serif" font-size="10" '
                'fill="#202124">BUTTON</text>'
            ).format(placement.x + 29, placement.y - 5),
            (
                '<text x="{}" y="{}" text-anchor="middle" '
                'font-family="sans-serif" font-size="7" font-weight="700" '
                'fill="#ffffff">GND + GPIO19</text>'
            ).format(placement.x + 29, placement.y + 38),
            "</g>",
        ]);
    }
    return (
        '<rect id="{}" x="{}" y="{}" width="{}" height="{}" '
        'fill="#dfe3e6" stroke="{}" stroke-width="{}"/>'
    ).format(
        placement.placement_id,
        placement.x,
        placement.y,
        placement.width,
        placement.height,
        stroke,
        stroke_width
    );
}


def _svg_route(route: WireRoute, highlighted: bool) -> str {
    point_text = " ".join(
        f"{point.x},{point.y}" for point in route.points
    );
    width = 7 if highlighted else 4;
    outline = (
        '<polyline points="{}" fill="none" stroke="white" '
        'stroke-width="{}" stroke-linecap="round" '
        'stroke-linejoin="round"/>'
    ).format(
        point_text,
        width + 4
    );
    wire = (
        '<polyline id="{}" points="{}" fill="none" stroke="{}" '
        'stroke-width="{}" stroke-linecap="round" '
        'stroke-linejoin="round"/>'
    ).format(
        route.route_id,
        point_text,
        route.color,
        width
    );
    return outline + wire;
}


def _instruction_lines(instruction: str) -> list[str] {
    lines: list[str] = [];
    current = "";
    for word in instruction.split(" ") {
        if not word {
            continue;
        }
        candidate = word if not current else current + " " + word;
        if len(candidate) <= 86 {
            current = candidate;
            continue;
        }
        if len(lines) == 1 {
            return [lines[0], current[:83] + "..."];
        }
        lines.append(current);
        current = word;
    }
    if current {
        lines.append(current);
    }
    if len(lines) > 2 {
        return [lines[0], lines[1][:83] + "..."];
    }
    return lines;
}


def render_step_svg(plan: AssemblyPlan, step: AssemblyStep) -> str {
    instruction_lines = _instruction_lines(step.instruction);
    elements: list[str] = [
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 680 550" ',
        'role="img" aria-labelledby="title desc">',
        '<title id="title">Step {}: {}</title>'.format(
            step.number,
            _xml_escape(step.title)
        ),
        '<desc id="desc">{}</desc>'.format(
            _xml_escape(step.instruction)
        ),
        '<rect width="680" height="550" fill="#ffffff"/>',
        _svg_breadboard(),
    ];
    for route in plan.routes {
        if route.route_id in step.visible_route_ids {
            elements.append(_svg_route(
                route,
                route.route_id in step.highlight_ids,
            ));
        }
    }
    for placement in plan.placements {
        if placement.placement_id in step.visible_placement_ids {
            elements.append(_svg_placement(
                placement,
                placement.placement_id in step.highlight_ids,
            ));
        }
    }
    elements.extend([
        '<rect x="20" y="446" width="640" height="48" rx="4" ',
        'fill="#f7f7f4" stroke="#d4d7da"/>',
    ]);
    for (index, line) in enumerate(instruction_lines) {
        elements.append(
            (
                '<text x="32" y="{}" font-family="sans-serif" font-size="10" '
                'fill="#303438">{}</text>'
            ).format(466 + index * 16, _xml_escape(line))
        );
    }
    elements.extend([
        '<rect x="20" y="510" width="640" height="28" rx="4" ',
        'fill="#f1f3f4" stroke="#d4d7da"/>',
        (
            '<text x="32" y="529" font-family="sans-serif" font-size="12" '
            'font-weight="700" fill="#202124">Step {}: {}</text>'
        ).format(step.number, _xml_escape(step.title)),
        "</svg>",
    ]);
    return "".join(elements);
}


def build_visualization(
    spec: HardwareSpec,
    plan: AssemblyPlan,
) -> VisualizationBundle {
    if spec.project_id != plan.project_id {
        raise ValueError("HardwareSpec and AssemblyPlan project ids do not match");
    }
    filenames: list[str] = [];
    svgs: list[str] = [];
    for step in plan.steps {
        filenames.append(f"step-{step.number:02d}.svg");
        svgs.append(render_step_svg(plan, step));
    }
    return VisualizationBundle(
        schema_version="wirejac.visualization.bundle.v1",
        project_id=spec.project_id,
        hardware_spec_json=hardware_spec_json(spec),
        visualization_json=json.dumps(
            visualization_model(spec, plan),
            sort_keys=True,
            indent=2,
        ) as str,
        assembly_json=json.dumps(
            assembly_model(plan),
            sort_keys=True,
            indent=2,
        ) as str,
        wokwi_diagram_json=json.dumps(
            wokwi_diagram_model(spec, plan),
            sort_keys=True,
            indent=2,
        ) as str,
        step_filenames=filenames,
        step_svgs=svgs,
    );
}
