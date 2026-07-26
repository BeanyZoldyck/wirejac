"""Compile LLM-produced intent into the deterministic supported hardware IR."""

import from hardware.circuit {
    ComponentInstance,
    ElectricalNet,
    Endpoint,
    HardwareSpec,
    PinAssignment
}
import from hardware.planning { HardwareIntent }


def _intent_has(intent: HardwareIntent, needles: list[str]) -> bool {
    for component in intent.components {
        value = component.kind.lower();
        for needle in needles {
            if needle in value {
                return True;
            }
        }
    }
    return False;
}


def _signal_gpio(
    intent: HardwareIntent,
    needles: list[str],
    fallback: int
) -> int {
    for signal in intent.signals {
        value = f"{signal.name} {signal.protocol}".lower();
        for needle in needles {
            if needle in value and signal.preferred_gpio is not None {
                return signal.preferred_gpio;
            }
        }
    }
    return fallback;
}


def compile_hardware_intent(
    intent: HardwareIntent,
    project_id: str
) -> HardwareSpec {
    has_imu = _intent_has(
        intent,
        ["mpu6050", "mpu-6050", "accelerometer", "gyroscope", "imu"]
    );
    has_led = _intent_has(intent, ["led", "light"]);
    has_button = _intent_has(intent, ["button", "switch"]);
    components: list[ComponentInstance] = [];
    assignments: list[PinAssignment] = [];
    nets: list[ElectricalNet] = [];

    power_endpoints: list[Endpoint] = [Endpoint("esp32", "3V3")];
    ground_endpoints: list[Endpoint] = [Endpoint("esp32", "GND_R")];

    if has_imu {
        components.append(
            ComponentInstance(
                component_id="imu",
                profile_id="gy521-mpu6050",
                label="Motion sensor",
                i2c_address=104
            )
        );
        sda = _signal_gpio(intent, ["sda", "i2c_data"], 21);
        scl = _signal_gpio(intent, ["scl", "i2c_clock"], 22);
        assignments.extend([
            PinAssignment(
                role="i2c_sda",
                gpio=sda,
                component_id="imu",
                component_pin="SDA"
            ),
            PinAssignment(
                role="i2c_scl",
                gpio=scl,
                component_id="imu",
                component_pin="SCL"
            ),
        ]);
        power_endpoints.append(Endpoint("imu", "VCC"));
        ground_endpoints.append(Endpoint("imu", "GND"));
        nets.extend([
            ElectricalNet(
                net_id="i2c_sda",
                role="i2c_sda",
                endpoints=[
                    Endpoint("esp32", f"GPIO{sda}"),
                    Endpoint("imu", "SDA"),
                ]
            ),
            ElectricalNet(
                net_id="i2c_scl",
                role="i2c_scl",
                endpoints=[
                    Endpoint("esp32", f"GPIO{scl}"),
                    Endpoint("imu", "SCL"),
                ]
            ),
        ]);
    }

    if has_led {
        components.extend([
            ComponentInstance(
                component_id="status_led",
                profile_id="led-5mm-red",
                label="Status indicator"
            ),
            ComponentInstance(
                component_id="led_resistor",
                profile_id="resistor-220ohm",
                label="LED current limiter"
            ),
        ]);
        led_gpio = _signal_gpio(intent, ["led", "light"], 18);
        assignments.append(
            PinAssignment(
                role="status_led",
                gpio=led_gpio,
                component_id="status_led",
                component_pin="A",
                direction="output"
            )
        );
        ground_endpoints.append(Endpoint("status_led", "K"));
        nets.extend([
            ElectricalNet(
                net_id="led_drive",
                role="digital_output",
                endpoints=[
                    Endpoint("esp32", f"GPIO{led_gpio}"),
                    Endpoint("led_resistor", "P1"),
                ]
            ),
            ElectricalNet(
                net_id="led_series",
                role="passive",
                endpoints=[
                    Endpoint("led_resistor", "P2"),
                    Endpoint("status_led", "A"),
                ]
            ),
        ]);
    }

    if has_button {
        components.append(
            ComponentInstance(
                component_id="arm_button",
                profile_id="button-6mm",
                label="Test button"
            )
        );
        button_gpio = _signal_gpio(intent, ["button", "switch"], 19);
        assignments.append(
            PinAssignment(
                role="arm_button",
                gpio=button_gpio,
                component_id="arm_button",
                component_pin="P1",
                direction="input_pullup"
            )
        );
        ground_endpoints.append(Endpoint("arm_button", "P2"));
        nets.append(
            ElectricalNet(
                net_id="button_input",
                role="digital_input_pullup",
                endpoints=[
                    Endpoint("esp32", f"GPIO{button_gpio}"),
                    Endpoint("arm_button", "P1"),
                ]
            )
        );
    }

    if len(power_endpoints) > 1 {
        nets.insert(
            0,
            ElectricalNet(
                net_id="power_3v3",
                role="power_3v3",
                endpoints=power_endpoints
            )
        );
    }
    if len(ground_endpoints) > 1 {
        nets.insert(
            1 if len(power_endpoints) > 1 else 0,
            ElectricalNet(
                net_id="ground",
                role="ground",
                endpoints=ground_endpoints
            )
        );
    }

    return HardwareSpec(
        schema_version="wirejac.hardware.v1",
        project_id=project_id,
        title="WireJac generated embedded subsystem",
        behavior=intent.project_summary,
        board_id="esp32",
        board_profile_id=intent.board_profile,
        breadboard_profile_id="half-breadboard-400",
        components=components,
        pin_assignments=assignments,
        nets=nets,
        expected_events=intent.telemetry_events
    );
}
