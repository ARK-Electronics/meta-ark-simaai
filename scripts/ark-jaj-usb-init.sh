#!/bin/sh
# ARK JAJ + Modalix: FUSB301 dual-role Type-C + USB SuperSpeed host bring-up
#
# FUSB301 @ i2c-0 0x25 (i2c00):
#   Stock power-on often SNK-only; we program DRP+ACC for dual-role CC logic.
#   Prefer host (SRC) for A-to-C sticks on USB-C; prefer device (SNK) when a
#   remote host is already providing VBUS (PC cable).
#
# IMPORTANT — USB device *data* mode (gadget to PC):
#   Stock Modalix eLxr has no USB gadget/UDC (# CONFIG_USB_GADGET is not set;
#   only TUSB73x0 xHCI host). FUSB can sit in SNK for CC/VBUS, but the PC will
#   not enumerate a gadget until SiMa ships a UDC + gadget-enabled kernel.
#
# TUSB73x0: keep SuperSpeed root hub runtime-active (autosuspend broke SS).

set -eu

I2C_BUS="${I2C_BUS:-0}"
FUSB_ADDR="${FUSB_ADDR:-0x25}"
# prefer-host | prefer-device | auto
# auto: if VBUS already present at init, force SNK (PC host); else DRP try-SRC
ROLE_POLICY="${ROLE_POLICY:-auto}"

log() { echo "ark-jaj-usb: $*"; }

FUSB_REG_DEVICEID=0x01
FUSB_REG_MODES=0x02
FUSB_REG_CONTROL=0x03
FUSB_REG_MANUAL=0x04
FUSB_REG_RESET=0x05
FUSB_REG_STATUS=0x11
FUSB_REG_TYPE=0x12

FUSB_MODE_DRP_ACC=0x20
FUSB_MODE_DRP=0x10
FUSB_MODE_SRC=0x01
FUSB_MODE_SNK=0x04
FUSB_CTRL_HOST_1500MA=0x04
FUSB_MANUAL_UNATT_SRC=0x04
FUSB_MANUAL_UNATT_SNK=0x08

fusb_present() {
	command -v i2cget >/dev/null 2>&1 || return 1
	id=$(i2cget -y "$I2C_BUS" "$FUSB_ADDR" "$FUSB_REG_DEVICEID" 2>/dev/null || true)
	case "$id" in
		0x10|0x11|0x12) return 0 ;;
		*) return 1 ;;
	esac
}

fusb_decode() {
	stat=$(i2cget -y "$I2C_BUS" "$FUSB_ADDR" "$FUSB_REG_STATUS" 2>/dev/null || echo 0x00)
	typ=$(i2cget -y "$I2C_BUS" "$FUSB_ADDR" "$FUSB_REG_TYPE" 2>/dev/null || echo 0x00)
	modes=$(i2cget -y "$I2C_BUS" "$FUSB_ADDR" "$FUSB_REG_MODES" 2>/dev/null || echo 0x00)
	# shell arithmetic needs decimal
	s=$(printf "%d" "$stat")
	t=$(printf "%d" "$typ")
	attach=$((s & 1))
	vbus=$(( (s >> 3) & 1 ))
	cc1=$(( (s >> 4) & 1 ))
	cc2=$(( (s >> 5) & 1 ))
	is_snk=$(( (t >> 4) & 1 ))
	is_src=$(( (t >> 3) & 1 ))
	if [ "$is_snk" -eq 1 ]; then
		role="DEVICE/SINK"
	elif [ "$is_src" -eq 1 ]; then
		role="HOST/SOURCE"
	else
		role="DETACHED"
	fi
	log "FUSB status=$stat type=$typ modes=$modes attach=$attach vbus=$vbus cc1=$cc1 cc2=$cc2 role=$role"
}

fusb_program() {
	mode="$1"
	manual="$2"
	i2cset -y "$I2C_BUS" "$FUSB_ADDR" "$FUSB_REG_RESET" 0x01 || true
	sleep 0.05
	i2cset -y "$I2C_BUS" "$FUSB_ADDR" "$FUSB_REG_CONTROL" "$FUSB_CTRL_HOST_1500MA"
	i2cset -y "$I2C_BUS" "$FUSB_ADDR" "$FUSB_REG_MODES" "$mode"
	i2cset -y "$I2C_BUS" "$FUSB_ADDR" "$FUSB_REG_MANUAL" "$manual" || true
	sleep 0.15
}

fusb_init_dual_role() {
	if ! fusb_present; then
		log "FUSB301 not found on i2c-${I2C_BUS}@${FUSB_ADDR} (skip Type-C init)"
		return 0
	fi

	id=$(i2cget -y "$I2C_BUS" "$FUSB_ADDR" "$FUSB_REG_DEVICEID")
	log "FUSB301 id=$id policy=$ROLE_POLICY"
	fusb_decode

	stat=$(i2cget -y "$I2C_BUS" "$FUSB_ADDR" "$FUSB_REG_STATUS")
	s=$(printf "%d" "$stat")
	vbus=$(( (s >> 3) & 1 ))
	attach=$((s & 1 ))

	case "$ROLE_POLICY" in
		prefer-device|device|snk)
			log "forcing SNK (device/sink) for dual-role device preference"
			fusb_program "$FUSB_MODE_SNK" "$FUSB_MANUAL_UNATT_SNK"
			;;
		prefer-host|host|src)
			log "forcing DRP try-SRC (host preference)"
			fusb_program "$FUSB_MODE_DRP_ACC" "$FUSB_MANUAL_UNATT_SRC"
			;;
		auto|*)
			# External host already providing VBUS → prefer sink/device CC role
			if [ "$vbus" -eq 1 ] && [ "$attach" -eq 1 ]; then
				log "VBUS present at attach — programming SNK (device CC role)"
				fusb_program "$FUSB_MODE_SNK" "$FUSB_MANUAL_UNATT_SNK"
			else
				log "no external host VBUS — DRP try-SRC (host for sticks on C)"
				fusb_program "$FUSB_MODE_DRP_ACC" "$FUSB_MANUAL_UNATT_SRC"
			fi
			;;
	esac

	fusb_decode

	# Gadget / UDC capability report (device *data* path)
	if [ -d /sys/class/udc ] && [ -n "$(ls -A /sys/class/udc 2>/dev/null || true)" ]; then
		log "UDC present: $(ls /sys/class/udc | tr '\n' ' ') — gadget possible"
	else
		log "WARNING: no UDC (/sys/class/udc empty). CC dual-role can be SNK but"
		log "WARNING: PC will not enumerate a USB gadget (kernel has no USB device controller)."
	fi
}

usb_ss_power_on() {
	if [ -w /sys/module/usbcore/parameters/autosuspend ]; then
		echo -1 > /sys/module/usbcore/parameters/autosuspend || true
	fi

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
