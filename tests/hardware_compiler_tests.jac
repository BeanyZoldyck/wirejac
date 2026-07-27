"""Focused tests for deterministic circuit, breadboard, and visual compilation."""

import json;
import from xml.etree.ElementTree { fromstring }
import from hardware.circuit {
    Endpoint,
    make_default_phone_snatch_spec,
    validate_hardware,
}
import from hardware.breadboard {
    compile_breadboard,
    holes_share_strip,
}
import from hardware.visualization { build_visualization }


def _issue_codes(project_id: str) -> list[str] {
    validation = validate_hardware(make_default_phone_snatch_spec(project_id));
    return [issue.code for issue in validation.issues];
}


test "phone snatch fixture uses safe pins and passes ERC" {
    spec = make_default_phone_snatch_spec("compiler-safe");
    validation = validate_hardware(spec);
    assert validation.valid;
    assert validation.issues == [];
    gpio_map = {assignment.role: assignment.gpio for assignment in spec.pin_assignments};
    assert gpio_map["i2c_sda"] == 21;
    assert gpio_map["i2c_scl"] == 22;
    assert gpio_map["status_led"] == 18;
    assert gpio_map["arm_button"] == 19;
    assert _issue_codes("compiler-safe-second") == [];
}


test "unsafe strapping pin is rejected" {
    spec = make_default_phone_snatch_spec("compiler-strap");
    spec.pin_assignments[0].gpio = 12;
    validation = validate_hardware(spec);
    codes = [issue.code for issue in validation.issues];
    assert not validation.valid;
    assert "BOOT_STRAPPING_GPIO" in codes;
    assert "PIN_MAP_NET_MISMATCH" in codes;
}


test "half breadboard rejects hidden ESP32 header pins" {
    spec = make_default_phone_snatch_spec("compiler-hidden-header");
    for assignment in spec.pin_assignments {
        if assignment.role == "status_led" {
            assignment.gpio = 25;
        }
    }
    for net in spec.nets {
        if net.net_id == "led_drive" {
            net.endpoints[0] = Endpoint("esp32", "GPIO25");
        }
    }
    validation = validate_hardware(spec);
    codes = [issue.code for issue in validation.issues];
    assert not validation.valid;
    assert "BREADBOARD_PIN_INACCESSIBLE" in codes;
}


test "mixed voltage power net is rejected" {
    spec = make_default_phone_snatch_spec("compiler-voltage");
    spec.nets[0].endpoints[0] = Endpoint("esp32", "VIN");
    validation = validate_hardware(spec);
    codes = [issue.code for issue in validation.issues];
    assert not validation.valid;
    assert "VOLTAGE_DOMAIN_CONFLICT" in codes;
}


test "missing LED resistor is rejected" {
    spec = make_default_phone_snatch_spec("compiler-resistor");
    spec.components = [
        component
        for component in spec.components
        if component.component_id != "led_resistor"
    ];
    validation = validate_hardware(spec);
    codes = [issue.code for issue in validation.issues];
    assert not validation.valid;
    assert "LED_RESISTOR_MISSING" in codes;
}


test "breadboard placement and routing are deterministic" {
    spec = make_default_phone_snatch_spec("compiler-layout");
    first = compile_breadboard(spec);
    second = compile_breadboard(spec);
    assert len(first.placements) == 5;
    assert len(first.routes) == 10;
    assert len(first.steps) == 18;
    assert first.routes[0].route_id == second.routes[0].route_id;
    assert first.routes[-1].from_hole == second.routes[-1].from_hole;
    assert first.routes[-1].to_hole == second.routes[-1].to_hole;
    assert holes_share_strip("B24", "A24");
    assert not holes_share_strip("I16", "I17");
    board = first.placements[0];
    assert len(board.anchors) == 15;
    assert board.anchors[0].hole == "J1";
    assert board.anchors[-1].hole == "J15";
    occupied: set[str] = set();
    for placement in first.placements {
        for anchor in placement.anchors {
            assert anchor.hole not in occupied;
            occupied.add(anchor.hole);
    button = [
        placement
        for placement in first.placements
        if placement.component_id == "arm_button"
    ][0];
    button_holes = {anchor.pin_id: anchor.hole for anchor in button.anchors};
    assert button_holes["P1"] == "I17";
    assert button_holes["P2"] == "I16";
    button_input = [
        route for route in first.routes if route.net_id == "button_input"
    ][0];
    assert button_input.from_hole == "I6";
    assert button_input.to_hole == "H17";
    button_ground = [
        route
        for route in first.routes
        if route.from_hole == "H16" and route.to_hole == "TN16"
    ][0];
    assert button_ground.color == "#202124";
        }
    }
}


test "visual bundle is complete and internally aligned" {
    spec = make_default_phone_snatch_spec("compiler-visual");
    plan = compile_breadboard(spec);
    bundle = build_visualization(spec, plan);
    diagram = json.loads(bundle.wokwi_diagram_json);
    visualization = json.loads(bundle.visualization_json);
    assembly = json.loads(bundle.assembly_json);
    hardware_spec = json.loads(bundle.hardware_spec_json);
    assert diagram["version"] == 1;
    assert len(diagram["parts"]) == 6;
    assert len(diagram["connections"]) == 26;
    assert visualization["project_id"] == spec.project_id;
    assert len(visualization["routes"]) == len(plan.routes);
    assert len(assembly["steps"]) == len(plan.steps);
    assert hardware_spec["pin_assignments"][0]["gpio"] == 21;
    assert len(bundle.step_filenames) == len(plan.steps);
    assert len(bundle.step_svgs) == len(plan.steps);
    for svg in bundle.step_svgs {
        fromstring(svg);
    }
    assert "place-esp32" not in bundle.step_svgs[0];
    assert "wire-button_input-1" in bundle.step_svgs[-1];
    assert "GND + GPIO19" in bundle.step_svgs[-1];
    assert bundle.step_filenames[-1] == "step-18.svg";
}
