"""Versioned physical and electrical profiles for the WireJac MVP kit."""


obj BoardPinProfile {
    has pin_id: str,
        label: str,
        header_side: str,
        header_row: int;
    has gpio: int = -1,
        voltage: float = 0.0,
        is_ground: bool = False,
        input_only: bool = False,
        strapping: bool = False,
        reserved: bool = False;
}


obj BoardProfile {
    has profile_id: str,
        name: str,
        wokwi_type: str,
        pins: list[BoardPinProfile];
    has logic_voltage: float = 3.3,
        header_rows: int = 15;
}


obj PartPinProfile {
    has pin_id: str,
        label: str,
        electrical_kind: str;
    has voltage: float = 0.0,
        drive: str = "passive";
}


obj PartProfile {
    has profile_id: str,
        name: str,
        wokwi_type: str,
        pins: list[PartPinProfile];
    has category: str = "component",
        default_i2c_address: int = -1,
        required_series_resistance_ohms: int = 0,
        description: str = "";
}


obj BreadboardProfile {
    has profile_id: str,
        name: str,
        wokwi_type: str;
    has terminal_rows: int = 30,
        terminal_columns: str = "ABCDEFGHIJ",
        rail_positions: int = 30,
        split_rails: bool = False;
}


def _board_pin(
    pin_id: str,
    label: str,
    side: str,
    row: int,
    gpio: int = -1,
    voltage: float = 0.0,
    is_ground: bool = False,
    input_only: bool = False,
    strapping: bool = False,
    reserved: bool = False,
) -> BoardPinProfile {
    return BoardPinProfile(
        pin_id=pin_id,
        label=label,
        header_side=side,
        header_row=row,
        gpio=gpio,
        voltage=voltage,
        is_ground=is_ground,
        input_only=input_only,
        strapping=strapping,
        reserved=reserved,
    );
}


"""Return the exact 30-pin DOIT ESP32 DevKit V1 physical profile."""
def doit_esp32_devkit_v1_30pin() -> BoardProfile {
    pins: list[BoardPinProfile] = [
        _board_pin("EN", "EN", "left", 1, reserved=True),
        _board_pin("GPIO36", "VP / GPIO36", "left", 2, gpio=36, input_only=True),
        _board_pin("GPIO39", "VN / GPIO39", "left", 3, gpio=39, input_only=True),
        _board_pin("GPIO34", "GPIO34", "left", 4, gpio=34, input_only=True),
        _board_pin("GPIO35", "GPIO35", "left", 5, gpio=35, input_only=True),
        _board_pin("GPIO32", "GPIO32", "left", 6, gpio=32),
        _board_pin("GPIO33", "GPIO33", "left", 7, gpio=33),
        _board_pin("GPIO25", "GPIO25", "left", 8, gpio=25),
        _board_pin("GPIO26", "GPIO26", "left", 9, gpio=26),
        _board_pin("GPIO27", "GPIO27", "left", 10, gpio=27),
        _board_pin("GPIO14", "GPIO14", "left", 11, gpio=14),
        _board_pin("GPIO12", "GPIO12", "left", 12, gpio=12, strapping=True),
        _board_pin("GPIO13", "GPIO13", "left", 13, gpio=13),
        _board_pin("GND", "GND", "left", 14, is_ground=True),
        _board_pin("VIN", "VIN / 5V", "left", 15, voltage=5.0),
        _board_pin("GPIO23", "GPIO23", "right", 1, gpio=23),
        _board_pin("GPIO22", "GPIO22", "right", 2, gpio=22),
        _board_pin("GPIO1", "TX0 / GPIO1", "right", 3, gpio=1),
        _board_pin("GPIO3", "RX0 / GPIO3", "right", 4, gpio=3),
        _board_pin("GPIO21", "GPIO21", "right", 5, gpio=21),
        _board_pin("GPIO19", "GPIO19", "right", 6, gpio=19),
        _board_pin("GPIO18", "GPIO18", "right", 7, gpio=18),
        _board_pin("GPIO5", "GPIO5", "right", 8, gpio=5, strapping=True),
        _board_pin("GPIO17", "TX2 / GPIO17", "right", 9, gpio=17),
        _board_pin("GPIO16", "RX2 / GPIO16", "right", 10, gpio=16),
        _board_pin("GPIO4", "GPIO4", "right", 11, gpio=4, strapping=True),
        _board_pin("GPIO2", "GPIO2", "right", 12, gpio=2, strapping=True),
        _board_pin("GPIO15", "GPIO15", "right", 13, gpio=15, strapping=True),
        _board_pin("GND_R", "GND", "right", 14, is_ground=True),
        _board_pin("3V3", "3V3", "right", 15, voltage=3.3),
    ];
    return BoardProfile(
        profile_id="doit-esp32-devkit-v1-30pin",
        name="DOIT ESP32 DevKit V1 (30 pin)",
        wokwi_type="wokwi-esp32-devkit-v1",
        pins=pins,
    );
}


def half_breadboard_400() -> BreadboardProfile {
    return BreadboardProfile(
        profile_id="half-breadboard-400",
        name="400-point half breadboard",
        wokwi_type="wokwi-breadboard-half",
    );
}


def supported_part_profiles() -> list[PartProfile] {
    return [
        PartProfile(
            profile_id="gy521-mpu6050",
            name="GY-521 MPU6050 accelerometer/gyroscope",
            wokwi_type="wokwi-mpu6050",
            category="sensor",
            default_i2c_address=104,
            description="3.3V I2C inertial sensor breakout",
            pins=[
                PartPinProfile("VCC", "VCC", "power", voltage=3.3),
                PartPinProfile("GND", "GND", "ground"),
                PartPinProfile("SCL", "SCL", "i2c_clock", drive="open_drain"),
                PartPinProfile("SDA", "SDA", "i2c_data", drive="open_drain"),
                PartPinProfile("XDA", "XDA", "i2c_data", drive="open_drain"),
                PartPinProfile("XCL", "XCL", "i2c_clock", drive="open_drain"),
                PartPinProfile("AD0", "AD0", "input"),
                PartPinProfile("INT", "INT", "output"),
            ],
        ),
        PartProfile(
            profile_id="led-5mm-red",
            name="5 mm red LED",
            wokwi_type="wokwi-led",
            category="indicator",
            required_series_resistance_ohms=220,
            description="Red status LED, approximately 2V forward voltage",
            pins=[
                PartPinProfile("A", "Anode (+)", "input"),
                PartPinProfile("K", "Cathode (-)", "ground"),
            ],
        ),
        PartProfile(
            profile_id="resistor-220ohm",
            name="220 ohm resistor",
            wokwi_type="wokwi-resistor",
            category="passive",
            description="LED current-limiting resistor",
            pins=[
                PartPinProfile("P1", "Lead 1", "passive"),
                PartPinProfile("P2", "Lead 2", "passive"),
            ],
        ),
        PartProfile(
            profile_id="button-6mm",
            name="6 mm tactile pushbutton",
            wokwi_type="wokwi-pushbutton",
            category="input",
            description="Normally-open tactile switch used with an internal pull-up",
            pins=[
                PartPinProfile("P1", "Switch side 1", "passive"),
                PartPinProfile("P2", "Switch side 2", "passive"),
            ],
        ),
    ];
}


def get_board_profile(profile_id: str) -> BoardProfile {
    profile = doit_esp32_devkit_v1_30pin();
    if profile.profile_id != profile_id {
        raise ValueError(f"Unsupported board profile: {profile_id}");
    }
    return profile;
}


def get_breadboard_profile(profile_id: str) -> BreadboardProfile {
    profile = half_breadboard_400();
    if profile.profile_id != profile_id {
        raise ValueError(f"Unsupported breadboard profile: {profile_id}");
    }
    return profile;
}


def get_part_profile(profile_id: str) -> PartProfile {
    for profile in supported_part_profiles() {
        if profile.profile_id == profile_id {
            return profile;
        }
    }
    raise ValueError(f"Unsupported part profile: {profile_id}");
}


def board_pin_by_id(board: BoardProfile, pin_id: str) -> BoardPinProfile | None {
    for pin in board.pins {
        if pin.pin_id == pin_id {
            return pin;
        }
    }
    return None;
}


def board_pin_by_gpio(board: BoardProfile, gpio: int) -> BoardPinProfile | None {
    for pin in board.pins {
        if pin.gpio == gpio {
            return pin;
        }
    }
    return None;
}


def part_pin_by_id(part: PartProfile, pin_id: str) -> PartPinProfile | None {
    for pin in part.pins {
        if pin.pin_id == pin_id {
            return pin;
        }
    }
    return None;
}
