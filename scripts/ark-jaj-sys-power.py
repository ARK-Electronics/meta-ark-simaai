#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""
JAJ system power + board unique ID (userspace).

I2C1 (/dev/i2c-1), gold-finger I2C1:
  - INA238 @ 0x45  — VBAT rail (R14 = 1 mΩ shunt on JAJ)
  - AT24CSW010 @ 0x50 / security @ 0x58 — factory unique ID @ word 0x80

Modalix eLxr has ina2xx.ko but not ina238 (different regs). This path works now
and publishes sys-power data under /run/ark-jaj/ for apps to consume. Device
tree nodes in ark-jaj.dtso document the hardware for a future in-kernel
CONFIG_SENSORS_INA238 bind.

  /run/ark-jaj/sys-power/voltage_uV
  /run/ark-jaj/sys-power/current_uA
  /run/ark-jaj/sys-power/power_uW
  /run/ark-jaj/sys-power/temp_mC
  /run/ark-jaj/sys-power/shunt_uV
  /run/ark-jaj/sys-power/online
  /run/ark-jaj/board/unique_id
  /run/ark-jaj/board/unique_id_text

Usage:
  sudo ./ark-jaj-sys-power.py once
  sudo ./ark-jaj-sys-power.py daemon
  sudo ./ark-jaj-sys-power.py id
"""
from __future__ import annotations

import argparse
import ctypes
import fcntl
import os
import sys
import time
from pathlib import Path

I2C_BUS = int(os.environ.get("I2C_BUS", "1"))
INA_ADDR = int(os.environ.get("INA_ADDR", "0x45"), 0)
EEPROM_ADDR = int(os.environ.get("EEPROM_ADDR", "0x50"), 0)
SEC_ADDR = int(os.environ.get("SEC_ADDR", hex(EEPROM_ADDR | 0x08)), 0)
RSHUNT_OHM = float(os.environ.get("RSHUNT_OHM", "0.001"))
RUNDIR = Path(os.environ.get("ARK_JAJ_RUNDIR", "/run/ark-jaj"))

REG_CONFIG = 0x00
REG_ADC_CONFIG = 0x01
REG_SHUNT_CAL = 0x02
REG_VSHUNT = 0x04
REG_VBUS = 0x05
REG_DIETEMP = 0x06
REG_CURRENT = 0x07
REG_POWER = 0x08

# Continuous shunt+bus, reasonable conversion/avg (TI-style default for monitoring)
ADC_CONFIG_DEFAULT = 0xFB6A
CONFIG_DEFAULT = 0x0000  # ADCRANGE = 0 (±163.84 mV)

I2C_M_RD = 0x0001
I2C_RDWR = 0x0707


class I2CMsg(ctypes.Structure):
	_fields_ = [
		("addr", ctypes.c_uint16),
		("flags", ctypes.c_uint16),
		("len", ctypes.c_uint16),
		("buf", ctypes.POINTER(ctypes.c_uint8)),
	]


class I2CRdwrIoctlData(ctypes.Structure):
	_fields_ = [
		("msgs", ctypes.POINTER(I2CMsg)),
		("nmsgs", ctypes.c_uint32),
	]


class I2C:
	def __init__(self, bus: int):
		self.fd = os.open(f"/dev/i2c-{bus}", os.O_RDWR)

	def close(self) -> None:
		os.close(self.fd)

	def transfer(self, addr: int, write: bytes | None = None, read_len: int = 0) -> bytes:
		msgs = []
		keep = []  # prevent GC of buffers

		if write is not None:
			w = (ctypes.c_uint8 * len(write))(*write)
			keep.append(w)
			m = I2CMsg(addr, 0, len(write), ctypes.cast(w, ctypes.POINTER(ctypes.c_uint8)))
			msgs.append(m)

		r = None
		if read_len:
			r = (ctypes.c_uint8 * read_len)()
			keep.append(r)
			m = I2CMsg(
				addr,
				I2C_M_RD,
				read_len,
				ctypes.cast(r, ctypes.POINTER(ctypes.c_uint8)),
			)
			msgs.append(m)

		arr = (I2CMsg * len(msgs))(*msgs)
		data = I2CRdwrIoctlData(arr, len(msgs))
		fcntl.ioctl(self.fd, I2C_RDWR, data)
		if read_len and r is not None:
			return bytes(r)
		return b""

	def read_u16(self, addr: int, reg: int) -> int:
		b = self.transfer(addr, bytes([reg]), 2)
		return (b[0] << 8) | b[1]

	def read_u24(self, addr: int, reg: int) -> int:
		b = self.transfer(addr, bytes([reg]), 3)
		return (b[0] << 16) | (b[1] << 8) | b[2]

	def write_u16(self, addr: int, reg: int, val: int) -> None:
		self.transfer(addr, bytes([reg, (val >> 8) & 0xFF, val & 0xFF]), 0)


def s16(u: int) -> int:
	return u - 0x10000 if u & 0x8000 else u


def configure_ina(bus: I2C, rshunt: float) -> float:
	"""Program ADC + shunt calibration. Returns CURRENT_LSB (A/bit)."""
	# Full-scale ~50 A with 1 mΩ in ±163.84 mV range
	current_lsb = 50.0 / 32768.0
	cal = int(round(819.2e6 * current_lsb * rshunt))
	cal = max(1, min(cal, 0x7FFF))
	bus.write_u16(INA_ADDR, REG_CONFIG, CONFIG_DEFAULT)
	bus.write_u16(INA_ADDR, REG_ADC_CONFIG, ADC_CONFIG_DEFAULT)
	bus.write_u16(INA_ADDR, REG_SHUNT_CAL, cal)
	return current_lsb


def read_ina(bus: I2C, current_lsb: float) -> dict:
	vshunt_raw = s16(bus.read_u16(INA_ADDR, REG_VSHUNT))
	vbus_raw = bus.read_u16(INA_ADDR, REG_VBUS)
	temp_raw = s16(bus.read_u16(INA_ADDR, REG_DIETEMP))
	curr_raw = s16(bus.read_u16(INA_ADDR, REG_CURRENT))
	# POWER is 24-bit on INA238 (not 16-bit like older ina2xx)
	power_raw = bus.read_u24(INA_ADDR, REG_POWER)

	# ADCRANGE=0: 5 µV / bit shunt; 3.125 mV / bit bus; 7.8125 m°C / bit temp
	# POWER LSB = 0.2 * CURRENT_LSB (W) per TI datasheet
	return {
		"voltage_uV": int(round(vbus_raw * 3.125e-3 * 1e6)),
		"current_uA": int(round(curr_raw * current_lsb * 1e6)),
		"power_uW": int(round(power_raw * (0.2 * current_lsb) * 1e6)),
		"temp_mC": int(round(temp_raw * 7.8125e-3 * 1e3)),
		"shunt_uV": int(round(vshunt_raw * 5.0)),
		"online": 1,
	}


def read_unique_id(bus: I2C) -> bytes:
	"""AT24CSW010: 128-bit ID at security register word address 0x80, addr 0x58."""
	return bus.transfer(SEC_ADDR, bytes([0x80]), 16)


def publish(data: dict, uid: bytes | None) -> None:
	pwr = RUNDIR / "sys-power"
	brd = RUNDIR / "board"
	pwr.mkdir(parents=True, exist_ok=True)
	brd.mkdir(parents=True, exist_ok=True)
	for k, v in data.items():
		(pwr / k).write_text(f"{v}\n")
	if uid is not None:
		(brd / "unique_id").write_text(uid.hex() + "\n")
		(brd / "unique_id_text").write_text(
			":".join(f"{b:02x}" for b in uid) + "\n"
		)


def main() -> int:
	ap = argparse.ArgumentParser(description="JAJ INA238 sys-power + AT24CSW unique ID")
	ap.add_argument("mode", nargs="?", default="once", choices=("once", "daemon", "id"))
	ap.add_argument("--interval", type=float, default=1.0)
	ap.add_argument("--bus", type=int, default=I2C_BUS)
	args = ap.parse_args()

	bus = I2C(args.bus)
	try:
		if args.mode == "id":
			uid = read_unique_id(bus)
			print(uid.hex())
			publish({"online": 0}, uid)
			return 0

		current_lsb = configure_ina(bus, RSHUNT_OHM)
		time.sleep(0.05)  # first conversion
		uid = None
		try:
			uid = read_unique_id(bus)
		except OSError as e:
			print(f"unique_id: {e}", file=sys.stderr)

		def tick() -> dict:
			d = read_ina(bus, current_lsb)
			publish(d, uid)
			return d

		if args.mode == "once":
			d = tick()
			print(
				f"Vbus={d['voltage_uV'] / 1e6:.3f} V  "
				f"I={d['current_uA'] / 1e6:.3f} A  "
				f"P={d['power_uW'] / 1e6:.3f} W  "
				f"T={d['temp_mC'] / 1e3:.1f} C  "
				f"Vshunt={d['shunt_uV']} uV"
			)
			if uid:
				print(f"unique_id={uid.hex()}")
			print(f"published under {RUNDIR}/sys-power and {RUNDIR}/board")
			return 0

		while True:
			try:
				tick()
			except OSError as e:
				publish({"online": 0}, uid)
				print(f"read error: {e}", file=sys.stderr)
			time.sleep(args.interval)
	finally:
		bus.close()


if __name__ == "__main__":
	sys.exit(main())
