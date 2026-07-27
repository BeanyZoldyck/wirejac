"""Typed Jac-native planning and MicroPython authoring boundary."""

import json;
import hardware.firmware_tools as firmware_tools;
import from hardware.contracts { HardwareRequest }


enum PlanningSource: str {
    LLM = "llm",
    REVIEWED_FIXTURE = "reviewed_fixture"
}


obj ComponentIntent {
    has reference: str,
        kind: str,
        purpose: str,
        required: bool = True,
        quantity: int = 1;
}
sem ComponentIntent.reference = "Stable short component reference such as esp32 or imu.";
sem ComponentIntent.kind = "Exact component identifier copied verbatim from HardwareRequest.allowed_inventory.";
sem ComponentIntent.purpose = "Why this component is required by the requested device.";
sem ComponentIntent.required = "Whether the design cannot function without this component.";
sem ComponentIntent.quantity = "Number of identical components required.";


obj SignalIntent {
    has name: str,
        direction: str,
        protocol: str,
        component_reference: str;
    has preferred_gpio: int | None = None,
        electrical_note: str = "";
}
sem SignalIntent.name = "Logical signal name.";
sem SignalIntent.direction = "Signal direction from the ESP32 perspective.";
sem SignalIntent.protocol = "Electrical protocol such as i2c, digital-in, or digital-out.";
sem SignalIntent.component_reference = "Reference of the attached component.";
sem SignalIntent.preferred_gpio = "Preferred safe ESP32 GPIO, or null if the compiler should assign one.";
sem SignalIntent.electrical_note = "Voltage, pull-up, current, or boot-strap constraint.";


obj HardwareIntent {
    has project_summary: str,
        board_profile: str,
        components: list[ComponentIntent],
        signals: list[SignalIntent],
        device_behaviors: list[str],
        telemetry_events: list[str];
    has source: PlanningSource = PlanningSource.LLM,
        assumptions: list[str] = [],
        warnings: list[str] = [];
}
sem HardwareIntent.project_summary = "One precise sentence describing the embedded subsystem.";
sem HardwareIntent.board_profile = "The exact supported ESP32 board profile from the request.";
sem HardwareIntent.components = "Only components available in the request inventory.";
sem HardwareIntent.signals = "Required logical signals. Prefer safe, non-strap GPIO pins.";
sem HardwareIntent.device_behaviors = "Observable runtime behaviors and safety behavior.";
sem HardwareIntent.telemetry_events = "Stable JSON event names emitted over serial or HTTP.";
sem HardwareIntent.assumptions = "Explicit assumptions requiring validation or user confirmation.";
sem HardwareIntent.warnings = "Electrical or feasibility cautions.";


obj FirmwareApplication {
    has app_source: str,
        summary: str,
        expected_events: list[str],
        self_test_steps: list[str];
    has source: PlanningSource = PlanningSource.LLM,
        repair_notes: list[str] = [];
}
sem FirmwareApplication.app_source = """
The complete contents of one MicroPython app.py module. It must define run().
Use only direct, unaliased imports from the reviewed machine I2C/Pin,
drivers.mpu6050, wirejac_config, wirejac_events, wirejac_http, and optional
wirejac_secrets APIs, plus math and time. Every Pin() must use a compiled PIN_*
constant and post_json() must use INGEST_URL. It must never contain secrets,
shell commands, dynamic imports, eval, exec, package installation, filesystem
operations, or deployment logic. Use only the pins and components in the intent.
""";
sem FirmwareApplication.summary = "Short description of the implemented device behavior.";
sem FirmwareApplication.expected_events = "JSON event names the application emits for verification.";
sem FirmwareApplication.self_test_steps = "Checks that prove sensors, controls, and telemetry work.";
sem FirmwareApplication.repair_notes = "Changes made in response to a previous validation failure.";


def plan_hardware(request: HardwareRequest) -> HardwareIntent by llm(
    temperature=0.1,
    max_tokens=4000,
    max_output_retries=2,
    system_prompt="""
You are WireJac's constrained embedded systems planner. Produce a breadboard
design for the exact board profile and allowed inventory in the request.
Do not invent components. Every ComponentIntent.kind must exactly match an
entry in request.allowed_inventory; use a short stable reference such as
esp32, imu, record_button, or breadboard, and make every
SignalIntent.component_reference match one of those references. Use 3.3 V-safe
wiring, include the shared ESP32/peripheral ground requirement, avoid ESP32
flash/strap pins, and describe only the embedded subsystem. Deployment and host
shell commands are outside your authority.
"""
);
sem plan_hardware = "Turn a coordinator hardware request into a typed, compilable hardware intent.";
sem plan_hardware.request = "Coordinator request including prompt, board, inventory, and integration contract.";


def author_micropython(
    request: HardwareRequest,
    intent: HardwareIntent
) -> FirmwareApplication by llm(
    temperature=0.1,
    max_tokens=8000,
    max_output_retries=2,
    system_prompt="""
You are WireJac's MicroPython application author. Return only a structured
FirmwareApplication. app_source is an application module loaded by a reviewed
A/B bootstrap, so it must define run() and must not invoke run() itself. Use the
reviewed WireJac APIs exactly as follows: machine exports I2C and Pin;
drivers.mpu6050 exports MPU6050; wirejac_events exports emit; wirejac_http
exports post_json; and wirejac_config exports only BUILD_ID, COOLDOWN_MS,
GYRO_THRESHOLD_DPS, HEARTBEAT_MS, I2C_ADDRESS, INGEST_URL,
LINEAR_ACCEL_THRESHOLD_G, PIN_BUTTON, PIN_LED, PIN_SCL, PIN_SDA, SAMPLE_HZ,
and TRIGGER_WINDOW_MS. Imports must be direct and unaliased. Call emit() for
device events and call post_json() only with INGEST_URL as its first argument.
Every Pin() call must use a compiled PIN_* constant. Keep mutable state local
to run(); global and nonlocal declarations are forbidden. Never generate host
commands, credentials, bootloaders, flash commands, arbitrary file operations,
dynamic imports, or invented helper APIs.
"""
);
sem author_micropython = "Author the constrained MicroPython application for a validated hardware intent.";
sem author_micropython.request = "Original coordinator request and backend integration contract.";
sem author_micropython.intent = "Validated component, signal, behavior, and telemetry plan.";


def default_phone_snatch_intent(request: HardwareRequest) -> HardwareIntent {
    return HardwareIntent(
        project_summary=(
            "Detect phone-snatching motion with an MPU6050 and emit structured "
            "events from an ESP32."
        ),
        board_profile=request.board_profile,
        components=[
            ComponentIntent(
                reference="esp32",
                kind="doit-esp32-devkit-v1-30pin",
                purpose="Runs detection, telemetry, and controls."
            ),
            ComponentIntent(
                reference="imu",
                kind="gy-521-mpu6050",
                purpose="Measures acceleration and angular velocity."
            ),
            ComponentIntent(
                reference="status_led",
                kind="led-with-220-ohm-resistor",
                purpose="Shows a detected event locally."
            ),
            ComponentIntent(
                reference="test_button",
                kind="momentary-button",
                purpose="Emits a manual test event."
            ),
            ComponentIntent(
                reference="breadboard",
                kind="400-point-half-breadboard",
                purpose="Carries the prototype wiring."
            ),
        ],
        signals=[
            SignalIntent(
                name="imu_sda",
                direction="bidirectional",
                protocol="i2c",
                component_reference="imu",
                preferred_gpio=21,
                electrical_note="3.3 V I2C data."
            ),
            SignalIntent(
                name="imu_scl",
                direction="output",
                protocol="i2c",
                component_reference="imu",
                preferred_gpio=22,
                electrical_note="3.3 V I2C clock."
            ),
            SignalIntent(
                name="status_led",
                direction="output",
                protocol="digital-out",
                component_reference="status_led",
                preferred_gpio=18,
                electrical_note="Series 220 ohm resistor to LED anode."
            ),
            SignalIntent(
                name="test_button",
                direction="input",
                protocol="digital-in",
                component_reference="test_button",
                preferred_gpio=19,
                electrical_note="Active low with the ESP32 internal pull-up."
            ),
        ],
        device_behaviors=[
            "Verify MPU6050 identity at startup.",
            "Sample acceleration and gyroscope data at 100 Hz.",
            "Emit a snatch event after combined acceleration and rotation.",
            "Debounce detections with a two-second cooldown.",
            "Emit a manual event when the button is pressed.",
            "Continue sampling when backend delivery is unavailable.",
        ],
        telemetry_events=[
            "sensor.detected",
            "wirejac.ready",
            "wirejac.heartbeat",
            "snatch.detected",
            "button.pressed",
            "backend.delivery",
            "backend.delivery_failed",
        ],
        source=PlanningSource.REVIEWED_FIXTURE,
        assumptions=[
            "The MPU6050 uses its default I2C address 0x68.",
            "All peripherals are operated at 3.3 V logic.",
        ],
        warnings=[
            "Do not connect the GY-521 VCC pin to both 3V3 and 5V.",
            "Disconnect external battery power before USB flashing.",
        ]
    );
}


def default_phone_snatch_application -> FirmwareApplication {
    return FirmwareApplication(
        app_source=firmware_tools.reviewed_phone_snatch_app(),
        summary="Reviewed MPU6050 phone-snatch detector with LED, button, and JSON telemetry.",
        expected_events=[
            "sensor.detected",
            "wirejac.ready",
            "wirejac.heartbeat",
            "snatch.detected",
            "button.pressed",
        ],
        self_test_steps=[
            "Confirm the I2C scan contains address 0x68.",
            "Confirm sensor.detected reports identity 0x68.",
            "Confirm wirejac.ready reports self_test pass.",
            "Press the button and observe button.pressed.",
            "Move and rotate the assembly and observe snatch.detected.",
        ],
        source=PlanningSource.REVIEWED_FIXTURE
    );
}


def default_motion_test_intent(request: HardwareRequest) -> HardwareIntent {
    return HardwareIntent(
        project_summary=(
            "Capture MPU6050 motion data for phone-snatch training while a "
            "button-controlled recording session is active."
        ),
        board_profile=request.board_profile,
        components=[
            ComponentIntent(
                reference="esp32",
                kind="doit-esp32-devkit-v1-30pin",
                purpose="Reads the sensor and emits structured motion telemetry."
            ),
            ComponentIntent(
                reference="imu",
                kind="gy-521-mpu6050",
                purpose="Measures acceleration and angular velocity."
            ),
            ComponentIntent(
                reference="record_button",
                kind="momentary-button",
                purpose="Starts and stops a motion recording session."
            ),
            ComponentIntent(
                reference="breadboard",
                kind="400-point-half-breadboard",
                purpose="Carries the prototype wiring."
            ),
        ],
        signals=[
            SignalIntent(
                name="imu_sda",
                direction="bidirectional",
                protocol="i2c",
                component_reference="imu",
                preferred_gpio=21,
                electrical_note="3.3 V I2C data."
            ),
            SignalIntent(
                name="imu_scl",
                direction="output",
                protocol="i2c",
                component_reference="imu",
                preferred_gpio=22,
                electrical_note="3.3 V I2C clock."
            ),
            SignalIntent(
                name="record_button",
                direction="input",
                protocol="digital-in",
                component_reference="record_button",
                preferred_gpio=19,
                electrical_note="Active low with the ESP32 internal pull-up."
            ),
        ],
        device_behaviors=[
            "Verify MPU6050 identity at startup.",
            "Toggle recording on each debounced button press.",
            "Sample the MPU6050 at 100 Hz while recording.",
            "Emit a motion sample every 250 milliseconds while recording.",
            "Emit a snatch event after combined acceleration and rotation.",
            "Continue sampling when backend delivery is unavailable.",
        ],
        telemetry_events=[
            "sensor.detected",
            "wirejac.ready",
            "wirejac.heartbeat",
            "recording.started",
            "motion.sample",
            "snatch.detected",
            "recording.stopped",
            "backend.delivery",
            "backend.delivery_failed",
        ],
        source=PlanningSource.REVIEWED_FIXTURE,
        assumptions=[
            "The ESP-WROOM-32 module is mounted on the supported 30-pin DOIT DevKit carrier.",
            "The MPU6050 uses its default I2C address 0x68.",
            "All peripherals are operated at 3.3 V logic.",
        ],
        warnings=[
            "Do not use these hole positions with a bare ESP-WROOM-32 module or a 38-pin carrier.",
            "Do not connect the GY-521 VCC pin to both 3V3 and 5V.",
            "Disconnect external battery power before USB flashing.",
        ]
    );
}


def default_motion_test_application -> FirmwareApplication {
    return FirmwareApplication(
        app_source=firmware_tools.reviewed_motion_test_app(),
        summary=(
            "Reviewed button-controlled MPU6050 recorder with serial JSON "
            "motion and phone-snatch telemetry."
        ),
        expected_events=[
            "sensor.detected",
            "wirejac.ready",
            "wirejac.heartbeat",
            "recording.started",
            "motion.sample",
            "snatch.detected",
            "recording.stopped",
        ],
        self_test_steps=[
            "Confirm the I2C scan contains address 0x68.",
            "Confirm sensor.detected reports identity 0x68.",
            "Confirm wirejac.ready reports self_test pass.",
            "Press the button once and observe recording.started.",
            "Move the assembly and observe changing motion.sample values.",
            "Move and rotate it sharply and observe snatch.detected.",
            "Press the button again and observe recording.stopped.",
        ],
        source=PlanningSource.REVIEWED_FIXTURE
    );
}


def hardware_intent_json(intent: HardwareIntent) -> str {
    return json.dumps(
        {
            "schema": "wirejac.hardware.intent/v1",
            "project_summary": intent.project_summary,
            "board_profile": intent.board_profile,
            "source": intent.source,
            "components": [
                {
                    "reference": component.reference,
                    "kind": component.kind,
                    "purpose": component.purpose,
                    "required": component.required,
                    "quantity": component.quantity,
                }
                for component in intent.components
            ],
            "signals": [
                {
                    "name": signal.name,
                    "direction": signal.direction,
                    "protocol": signal.protocol,
                    "component_reference": signal.component_reference,
                    "preferred_gpio": signal.preferred_gpio,
                    "electrical_note": signal.electrical_note,
                }
                for signal in intent.signals
            ],
            "device_behaviors": intent.device_behaviors,
            "telemetry_events": intent.telemetry_events,
            "assumptions": intent.assumptions,
            "warnings": intent.warnings,
        },
        sort_keys=True,
        indent=2
    ) as str;
}
