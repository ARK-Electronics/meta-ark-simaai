#!/bin/sh
# ARK JAJ + Modalix: FUSB301 dual-role Type-C + USB SuperSpeed host bring-up
#
# FUSB301 @ i2c-0 0x25 (i2c00): stock chip comes up as SNK-only (MODES=0x04),
# which breaks dual-mode USB-C. Reprogram DRP+ACC like Jetson JAJ host carriers.
#
# TUSB73x0 xHCI: keep SuperSpeed root hub (usb2) runtime-active; autosuspend
# left the SS bus suspended and prevented SuperSpeed attach.
#
# Safe to run repeatedly (systemd oneshot + after hotplug rescan).

set -eu

I2C_BUS="${I2C_BUS:-0}"
FUSB_ADDR="${FUSB_ADDR:-0x25}"

log() { echo "ark-jaj-usb: $*"; }

# --- FUSB301 (ON Semi) register map ---
# 0x01 DEVICEID  0x12 = rev 1.2
# 0x02 MODES     BIT4=DRP BIT5=DRP_ACC BIT0=SRC BIT2=SNK
# 0x03 CONTROL   bits[2:1] host current (0/default/1.5A/3A), bit0 int-disable
# 0x04 MANUAL    BIT2=UNATT_SRC BIT3=UNATT_SNK BIT1=DISABLED
# 0x05 RESET     BIT0=SW_RESET
# 0x11 STATUS    BIT0=ATTACH BIT3=VBUS_OK BIT4=CC1 BIT5=CC2
# 0x12 TYPE      BIT3=SRC BIT4=SNK

FUSB_REG_DEVICEID=0x01
FUSB_REG_MODES=0x02
FUSB_REG_CONTROL=0x03
FUSB_REG_MANUAL=0x04
FUSB_REG_RESET=0x05

FUSB_MODE_DRP_ACC=0x20
FUSB_MODE_DRP=0x10
FUSB_MODE_SRC=0x01
FUSB_CTRL_HOST_1500MA=0x04   # ints enabled, 1.5A host present
FUSB_MANUAL_UNATT_SRC=0x04

fusb_present() {
	command -v i2cget >/dev/null 2>&1 || return 1
	id=$(i2cget -y "$I2C_BUS" "$FUSB_ADDR" "$FUSB_REG_DEVICEID" 2>/dev/null || true)
	# FUSB301 rev 1.0/1.1/1.2 => 0x10/0x11/0x12
	case "$id" in
		0x10|0x11|0x12) return 0 ;;
		*) return 1 ;;
	esac
}

fusb_init_dual_role() {
	if ! fusb_present; then
		log "FUSB301 not found on i2c-${I2C_BUS}@${FUSB_ADDR} (skip Type-C init)"
		return 0
	fi

	id=$(i2cget -y "$I2C_BUS" "$FUSB_ADDR" "$FUSB_REG_DEVICEID")
	modes_before=$(i2cget -y "$I2C_BUS" "$FUSB_ADDR" "$FUSB_REG_MODES")
	log "FUSB301 id=$id modes_before=$modes_before"

	# Soft reset then dual-role (DRP + accessory), host-try
	i2cset -y "$I2C_BUS" "$FUSB_ADDR" "$FUSB_REG_RESET" 0x01 || true
	sleep 0.05
	i2cset -y "$I2C_BUS" "$FUSB_ADDR" "$FUSB_REG_CONTROL" "$FUSB_CTRL_HOST_1500MA"
	i2cset -y "$I2C_BUS" "$FUSB_ADDR" "$FUSB_REG_MODES" "$FUSB_MODE_DRP_ACC"
	# Prefer source/host when toggling dual-role
	i2cset -y "$I2C_BUS" "$FUSB_ADDR" "$FUSB_REG_MANUAL" "$FUSB_MANUAL_UNATT_SRC" || true
	sleep 0.1

	modes=$(i2cget -y "$I2C_BUS" "$FUSB_ADDR" "$FUSB_REG_MODES")
	ctrl=$(i2cget -y "$I2C_BUS" "$FUSB_ADDR" "$FUSB_REG_CONTROL")
	stat=$(i2cget -y "$I2C_BUS" "$FUSB_ADDR" 0x11 2>/dev/null || echo "?")
	typ=$(i2cget -y "$I2C_BUS" "$FUSB_ADDR" 0x12 2>/dev/null || echo "?")
	log "FUSB301 dual-role OK modes=$modes control=$ctrl status=$stat type=$typ"
}

usb_ss_power_on() {
	# Global: do not autosuspend USB devices after 2s idle
	if [ -w /sys/module/usbcore/parameters/autosuspend ]; then
		echo -1 > /sys/module/usbcore/parameters/autosuspend || true
	fi

	# SuperSpeed + HS root hubs and the TUSB73x0 PCI function
	for path in \
		/sys/bus/usb/devices/usb1/power/control \
		/sys/bus/usb/devices/usb2/power/control \
		/sys/bus/pci/devices/0003:01:00.0/power/control
	do
		if [ -w "$path" ]; then
			echo on > "$path" || true
			log "power on: $path"
		fi
	done

	# Disable per-device autosuspend delay under both root hubs
	for d in /sys/bus/usb/devices/usb1 /sys/bus/usb/devices/usb2 \
		 /sys/bus/usb/devices/1-* /sys/bus/usb/devices/2-*; do
		[ -d "$d/power" ] || continue
		[ -w "$d/power/control" ] && echo on > "$d/power/control" || true
		[ -w "$d/power/autosuspend" ] && echo -1 > "$d/power/autosuspend" || true
		[ -w "$d/power/autosuspend_delay_ms" ] && echo -1 > "$d/power/autosuspend_delay_ms" || true
	done

	if [ -r /sys/bus/usb/devices/usb2/speed ]; then
		log "SS root hub speed=$(cat /sys/bus/usb/devices/usb2/speed) runtime=$(cat /sys/bus/usb/devices/usb2/power/runtime_status 2>/dev/null || echo n/a)"
	fi
}

main() {
	log "starting"
	fusb_init_dual_role
	usb_ss_power_on
	log "done"
}

main "$@"
