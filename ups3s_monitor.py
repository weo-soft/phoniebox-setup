#!/usr/bin/env python3
# =============================================================================
# ups3s_monitor.py
# -----------------------------------------------------------------------------
# Reads the operating data of a Waveshare UPS Module 3S over I2C and writes it
# to the journal and to a JSON status file.
#
# The module uses an INA219 at address 0x41. It measures the 3S battery pack
# (9.0 V empty to 12.6 V full) through a 0.01 Ohm shunt. The percentage follows
# the vendor formula (bus voltage - 9.0 V) / 3.6 V * 100.
#
# The service is installed by ups3s_install.sh and started by systemd. The
# values can be tuned through the environment file /etc/ups3s-monitor.conf.
# =============================================================================

import argparse
import json
import os
import signal
import sys
import time
from datetime import datetime, timezone

try:
    from smbus2 import SMBus
except ImportError:
    print("ERROR: python3-smbus2 is not installed.", file=sys.stderr)
    sys.exit(1)

INA219_REG_CONFIG = 0x00
INA219_REG_SHUNT_VOLTAGE = 0x01
INA219_REG_BUS_VOLTAGE = 0x02
INA219_REG_POWER = 0x03
INA219_REG_CURRENT = 0x04
INA219_REG_CALIBRATION = 0x05

# 16 V bus range, /2 gain (80 mV), 32 samples for bus and shunt,
# continuous shunt and bus conversion.
INA219_CONFIG = 0x0EEF

DEFAULT_BUS = 1
DEFAULT_ADDRESS = 0x41
DEFAULT_INTERVAL = 10.0
DEFAULT_SHUNT_OHMS = 0.01
DEFAULT_MAX_CURRENT_A = 5.0
DEFAULT_CELLS = 3
DEFAULT_CHARGING_MA = 50.0
DEFAULT_DISCHARGING_MA = 200.0
DEFAULT_CURRENT_SIGN = 1.0
DEFAULT_STATUS_FILE = "/run/ups3s/status.json"

STOP_REQUESTED = False


def _stop(signum, frame):
    del signum, frame
    global STOP_REQUESTED
    STOP_REQUESTED = True


def _env_int(name, default):
    value = os.environ.get(name)
    if value is None or value == "":
        return default
    return int(value, 0)


def _env_float(name, default):
    value = os.environ.get(name)
    if value is None or value == "":
        return default
    return float(value)


def _now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _clamp(value, low, high):
    return max(low, min(high, value))


class INA219:
    """Minimal INA219 reader for the Waveshare UPS Module 3S."""

    def __init__(self, bus_number, address, shunt_ohms, max_current_a):
        if shunt_ohms <= 0:
            raise ValueError("shunt_ohms must be positive")
        if max_current_a <= 0:
            raise ValueError("max_current_a must be positive")

        self.bus_number = bus_number
        self.address = address
        self.shunt_ohms = shunt_ohms
        self.current_lsb_a = max_current_a / 32767.0
        self.current_lsb_ma = self.current_lsb_a * 1000.0
        self.power_lsb_w = 20.0 * self.current_lsb_a
        self.calibration = int(0.04096 / (self.current_lsb_a * shunt_ohms))
        if not 0 < self.calibration <= 0xFFFF:
            raise ValueError("INA219 calibration value out of range")

        self.bus = SMBus(bus_number)
        self._write_word(INA219_REG_CALIBRATION, self.calibration)
        self._write_word(INA219_REG_CONFIG, INA219_CONFIG)
        # Let the first 32-sample conversion finish before the first read.
        time.sleep(0.05)

    def close(self):
        try:
            self.bus.close()
        except Exception:
            pass

    def _write_word(self, register, value):
        self.bus.write_i2c_block_data(
            self.address,
            register,
            [(value >> 8) & 0xFF, value & 0xFF],
        )

    def _read_word(self, register):
        data = self.bus.read_i2c_block_data(self.address, register, 2)
        return (data[0] << 8) | data[1]

    def read(self):
        bus_raw = self._read_word(INA219_REG_BUS_VOLTAGE)
        bus_voltage_v = (bus_raw >> 3) * 0.004

        shunt_raw = self._read_word(INA219_REG_SHUNT_VOLTAGE)
        if shunt_raw > 0x7FFF:
            shunt_raw -= 0x10000
        shunt_voltage_mv = shunt_raw * 0.01

        current_raw = self._read_word(INA219_REG_CURRENT)
        if current_raw > 0x7FFF:
            current_raw -= 0x10000
        current_ma = current_raw * self.current_lsb_ma

        power_raw = self._read_word(INA219_REG_POWER)
        power_w = power_raw * self.power_lsb_w

        return {
            "bus_voltage_v": bus_voltage_v,
            "shunt_voltage_mv": shunt_voltage_mv,
            "battery_voltage_v": bus_voltage_v + shunt_voltage_mv / 1000.0,
            "current_ma": current_ma,
            "power_w": power_w,
        }


def battery_percent(bus_voltage_v, cells):
    empty_v = cells * 3.0
    full_v = cells * 4.2
    value = (bus_voltage_v - empty_v) / (full_v - empty_v) * 100.0
    return round(_clamp(value, 0.0, 100.0), 1)


def battery_state(current_ma, charging_ma, discharging_ma):
    if current_ma > charging_ma:
        return "charging"
    if current_ma < -discharging_ma:
        return "discharging"
    return "idle"


def write_status(path, payload):
    if not path:
        return
    directory = os.path.dirname(path)
    try:
        if directory:
            os.makedirs(directory, exist_ok=True)
        temporary = path + ".tmp"
        with open(temporary, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, indent=2, sort_keys=True)
            handle.write("\n")
        os.replace(temporary, path)
    except OSError as exc:
        print(f"UPS3S: cannot write {path}: {exc}", file=sys.stderr, flush=True)


def parse_args(argv):
    parser = argparse.ArgumentParser(description="Read the Waveshare UPS Module 3S over I2C.")
    parser.add_argument("--bus", type=lambda value: int(value, 0),
                        default=_env_int("UPS3S_I2C_BUS", DEFAULT_BUS))
    parser.add_argument("--address", type=lambda value: int(value, 0),
                        default=_env_int("UPS3S_I2C_ADDRESS", DEFAULT_ADDRESS))
    parser.add_argument("--interval", type=float,
                        default=_env_float("UPS3S_INTERVAL", DEFAULT_INTERVAL))
    parser.add_argument("--shunt-ohms", type=float,
                        default=_env_float("UPS3S_SHUNT_OHMS", DEFAULT_SHUNT_OHMS))
    parser.add_argument("--max-current-a", type=float,
                        default=_env_float("UPS3S_MAX_CURRENT_A", DEFAULT_MAX_CURRENT_A))
    parser.add_argument("--cells", type=int,
                        default=_env_int("UPS3S_CELLS", DEFAULT_CELLS))
    parser.add_argument("--charging-threshold-ma", type=float,
                        default=_env_float("UPS3S_CHARGING_THRESHOLD_MA", DEFAULT_CHARGING_MA))
    parser.add_argument("--discharging-threshold-ma", type=float,
                        default=_env_float("UPS3S_DISCHARGING_THRESHOLD_MA", DEFAULT_DISCHARGING_MA))
    parser.add_argument("--current-sign", type=float,
                        default=_env_float("UPS3S_CURRENT_SIGN", DEFAULT_CURRENT_SIGN))
    parser.add_argument("--status-file",
                        default=os.environ.get("UPS3S_STATUS_FILE", DEFAULT_STATUS_FILE))
    args = parser.parse_args(argv)

    if not 0 <= args.bus <= 6:
        parser.error("--bus must be between 0 and 6")
    if not 0x40 <= args.address <= 0x4F:
        parser.error("--address must be between 0x40 and 0x4F")
    if args.interval <= 0:
        parser.error("--interval must be positive")
    if args.cells < 1:
        parser.error("--cells must be at least 1")
    if args.current_sign not in (-1.0, 1.0):
        parser.error("--current-sign must be 1 or -1")

    return args


def main(argv=None):
    args = parse_args(argv if argv is not None else sys.argv[1:])

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)

    sensor = None
    last_error = None
    last_error_time = 0.0

    while not STOP_REQUESTED:
        try:
            if sensor is None:
                sensor = INA219(args.bus, args.address, args.shunt_ohms, args.max_current_a)

            reading = sensor.read()
            current_ma = reading["current_ma"] * args.current_sign
            percent = battery_percent(reading["bus_voltage_v"], args.cells)
            state = battery_state(
                current_ma,
                args.charging_threshold_ma,
                args.discharging_threshold_ma,
            )

            payload = {
                "status": "ok",
                "timestamp": _now(),
                "bus": args.bus,
                "address": f"0x{args.address:02x}",
                "bus_voltage_v": round(reading["bus_voltage_v"], 3),
                "battery_voltage_v": round(reading["battery_voltage_v"], 3),
                "shunt_voltage_mv": round(reading["shunt_voltage_mv"], 3),
                "current_ma": round(current_ma, 1),
                "power_w": round(reading["power_w"], 3),
                "percent": round(percent, 1),
                "state": state,
                "cells": args.cells,
            }
            write_status(args.status_file, payload)

            if last_error is not None:
                print("UPS3S: device is readable again.", flush=True)
                last_error = None

            print(
                "UPS3S {bus:.2f} V {current:.3f} A {power:.2f} W {percent:.1f} % {state}".format(
                    bus=reading["bus_voltage_v"],
                    current=current_ma / 1000.0,
                    power=reading["power_w"],
                    percent=percent,
                    state=state,
                ),
                flush=True,
            )
        except Exception as exc:
            if sensor is not None:
                sensor.close()
                sensor = None
            now = time.monotonic()
            message = str(exc)
            if message != last_error or now - last_error_time >= 60.0:
                print(f"UPS3S: {message}", file=sys.stderr, flush=True)
                write_status(
                    args.status_file,
                    {
                        "status": "error",
                        "timestamp": _now(),
                        "bus": args.bus,
                        "address": f"0x{args.address:02x}",
                        "error": message,
                    },
                )
                last_error = message
                last_error_time = now

        deadline = time.monotonic() + args.interval
        while not STOP_REQUESTED:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            time.sleep(min(1.0, remaining))

    if sensor is not None:
        sensor.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
