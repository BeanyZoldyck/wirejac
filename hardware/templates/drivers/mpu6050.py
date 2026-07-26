"""Small MPU6050 driver with no third-party dependencies."""

PWR_MGMT_1 = 0x6B
WHO_AM_I = 0x75
ACCEL_XOUT_H = 0x3B


def _signed16(high, low):
    value = (high << 8) | low
    return value - 65536 if value & 0x8000 else value


class MPU6050:
    def __init__(self, i2c, address=0x68):
        self.i2c = i2c
        self.address = address

    def initialize(self):
        identity = self.who_am_i()
        if identity != 0x68:
            raise RuntimeError("MPU6050 WHO_AM_I expected 0x68, got 0x%02x" % identity)
        self.i2c.writeto_mem(self.address, PWR_MGMT_1, b"\x00")
        return identity

    def who_am_i(self):
        return self.i2c.readfrom_mem(self.address, WHO_AM_I, 1)[0]

    def read(self):
        raw = self.i2c.readfrom_mem(self.address, ACCEL_XOUT_H, 14)
        accel = (
            _signed16(raw[0], raw[1]) / 16384.0,
            _signed16(raw[2], raw[3]) / 16384.0,
            _signed16(raw[4], raw[5]) / 16384.0,
        )
        temperature = _signed16(raw[6], raw[7]) / 340.0 + 36.53
        gyro = (
            _signed16(raw[8], raw[9]) / 131.0,
            _signed16(raw[10], raw[11]) / 131.0,
            _signed16(raw[12], raw[13]) / 131.0,
        )
        return accel, gyro, temperature

