# ESP32 Breadboard Profile

This is the exact physical profile compiled by WireJac. Do not substitute a
38-pin ESP32 board or a split-rail breadboard and assume the generated hole
coordinates still apply.

## Bill of Materials

| Quantity | Part | WireJac profile |
| --- | --- | --- |
| 1 | DOIT ESP32 DevKit V1, 30-pin | `doit-esp32-devkit-v1-30pin` |
| 1 | GY-521 MPU6050 breakout | `gy521-mpu6050` |
| 1 | Red 5 mm LED | `led-5mm-red` |
| 1 | 220 ohm resistor | `resistor-220ohm` |
| 1 | 6 mm tactile pushbutton | `button-6mm` |
| 1 | 400-point half breadboard | `half-breadboard-400` |
| 10 | Male-to-male jumpers | red, black, green, yellow, orange, and blue |

The generated SVG calls the continuous top positive rail `TP` and the
continuous top negative rail `TN`. Confirm your board's rail continuity before
using it. The bottom rails are unused.

## Place Components

Disconnect the ESP32 USB cable before touching the breadboard.

1. Insert only the ESP32 right-side header along J1-J15. Put `GPIO23` in J1,
   `GPIO22` in J2, `GPIO21` in J5, `GND` in J14, and `3V3` in J15. The board
   body and unused header overhang past the J edge. Keep the USB connector past
   the row-15 end and support the overhang on a nonconductive surface.
2. Insert the GY-521 header along J18-J25: VCC J18, GND J19, SCL J20, SDA J21,
   XDA J22, XCL J23, AD0 J24, and INT J25.
3. Place the 220 ohm resistor from B20 to B24.
4. Place the LED long anode leg in A24 and short cathode leg in A25. A24 and
   B24 share one terminal strip, connecting the resistor to the anode.
5. Place the recording button between the ESP32 and GY-521. Its black-ground leg goes in I16,
   directly beside ESP32 3V3 at J15; its blue GPIO19 leg goes in I17. Both
   live jumpers leave the same physical side of the button. Leave the
   opposite-side legs unused.

## Add Jumpers

| Color | From | To | Electrical connection |
| --- | --- | --- | --- |
| Red | I15 | TP15 | ESP32 3V3 to positive rail |
| Red | I18 | TP18 | Positive rail to GY-521 VCC |
| Black | I14 | TN14 | ESP32 right-side GND to negative rail |
| Black | I19 | TN19 | GY-521 GND to negative rail |
| Black | A25 | TN25 | LED cathode to negative rail |
| Black | H16 | TN16 | Terminal strip for button P2 ground leg at I16 to negative rail |
| Green | I5 | I21 | ESP32 GPIO21 to GY-521 SDA |
| Yellow | I2 | I20 | ESP32 GPIO22 to GY-521 SCL |
| Orange | I7 | C20 | ESP32 GPIO18 to resistor lead 1 |
| Blue | I6 | H17 | ESP32 GPIO19 to terminal strip for button P1 at I17 |

The resistor lead at B24 and LED anode at A24 need no jumper because they share
row 24 on the A-E terminal strip. The button uses the ESP32 internal pull-up,
so pressing it connects GPIO19 to ground and reads active-low. I16 and I17
are separate breadboard rows: the black and blue wires are on the same
physical side of the button, but they must never share one terminal strip.

## Logical Pin Map

| Role | ESP32 pin | Peripheral pin | Constraint |
| --- | --- | --- | --- |
| I2C data | GPIO21 | GY-521 SDA | 3.3 V logic |
| I2C clock | GPIO22 | GY-521 SCL | 3.3 V logic |
| Status LED | GPIO18 | 220 ohm resistor, then LED anode | Output |
| Test button | GPIO19 | Button I17 / blue lead | Input with internal pull-up |
| Sensor power | 3V3 | GY-521 VCC | Never connect this build to VIN/5V |
| Common ground | Right-side GND | GY-521 GND, LED cathode, button P2 at I16 | Required |

The MPU6050 remains at its default I2C address `0x68`; leave AD0 unconnected.
XDA, XCL, and INT are also unused in this profile.

Do not fully insert both ESP32 header rows in this half breadboard. That hides
the adjacent terminal strips and makes the jumpers inaccessible. WireJac's
electrical/layout validator rejects generated nets that use the unsupported
header side for this profile.

## Inspect and Power

Before reconnecting USB:

1. Confirm the red rail does not connect to the black rail.
2. Confirm the GY-521 VCC wire reaches J15/ESP32 3V3, not VIN.
3. Confirm the LED cathode is in A25 and its anode reaches the resistor.
4. Confirm the button ground lead is at I16 beside ESP32 3V3 J15, and the
   blue GPIO19 lead is at I17 on the same physical button side.
5. Compare the completed board with the final generated `step-*.svg`.

Stop immediately if a component becomes warm, emits an odor, or behaves
erratically after power is connected.

Physical verification expects JSON serial events at 115200 baud. Within 12
seconds it must observe `sensor.detected`, `wirejac.ready`, and
`wirejac.heartbeat`. The reviewed application also emits `button.pressed` and
`snatch.detected` for manual interaction.
