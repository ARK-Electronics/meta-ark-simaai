#!/usr/bin/env bash
# JAJ + Modalix: map and scan I2C0 / I2C1 (and list other buses).
#
# Run ON THE TARGET as root (or: ssh … 'sudo bash -s' < scripts/i2c-jaj-test.sh).
#
#   sudo ./i2c-jaj-test.sh              # full report + detect on i2c00/i2c01
#   sudo I2C_BUS=1 ./i2c-jaj-test.sh    # only scan /dev/i2c-1 (after map)
#
# Expected (Modalix stock + ark-jaj.dtbo):
#   i2c00 → gold-finger I2C0 (SODIMM 185/187) — FUSB301 @ 0x25 usually present
#   i2c01 → gold-finger I2C1 (SODIMM 189/191) — carrier / 40-pin I2C1
#   i2c52 → CAM_I2C parent (often /dev/i2c-4) — IMX219 behind mux
#
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
	echo "ERROR: run as root (need /dev/i2c-* and i2cdetect)" >&2
	exit 1
fi

if ! command -v i2cdetect >/dev/null 2>&1; then
	echo "Installing i2c-tools..."
	apt-get install -y i2c-tools 2>/dev/null || true
fi
if ! command -v i2cdetect >/dev/null 2>&1; then
	echo "ERROR: i2cdetect not found" >&2
	exit 1
fi

echo "=== board ==="
tr '\0' ' ' </proc/device-tree/model 2>/dev/null; echo
uname -r

echo
echo "=== I2C adapters (name + platform path) ==="
declare -A BUS_OF
# Modalix sysfs uses i2c-dev + platform/sio@N/... (not always i2c-adapter/)
for d in /sys/class/i2c-dev/i2c-*; do
	[ -e "$d" ] || continue
	n=$(basename "$d")
	bus=${n#i2c-}
	dev=$(readlink -f "$d/device" 2>/dev/null || true)
	name=$(cat "$dev/name" 2>/dev/null || echo "?")
	of="(no of_node)"
	if [ -L "$dev/of_node" ]; then
		of=$(cat "$dev/of_node/full_name" 2>/dev/null || basename "$(readlink -f "$dev/of_node")")
	fi
	printf '  /dev/i2c-%-2s  name=%-36s  %s\n' "$bus" "$name" "$of"
	BUS_OF[$bus]=$of
done

# Prefer matching DT node names i2c00 / i2c01 if present in of graph
map_bus() {
	local want=$1
	local target unit d bus op fn
	if [ -e "/proc/device-tree/aliases/$want" ]; then
		target=$(tr '\0' ' ' <"/proc/device-tree/aliases/$want" | tr -d ' ')
		unit=${target##*/}
		for d in /sys/class/i2c-adapter/i2c-*; do
			[ -e "$d" ] || continue
			bus=${d##*-}
			op=$(readlink -f "$d/device/of_node" 2>/dev/null || true)
			[ -n "$op" ] || continue
			fn=$(cat "$d/device/of_node/full_name" 2>/dev/null || true)
			# Match alias path, full_name, or unit address (i2c@0x...)
			if [ -n "$fn" ] && [ "$fn" = "$target" ]; then echo "$bus"; return; fi
			if [ -n "$fn" ] && [ "${fn##*/}" = "$unit" ]; then echo "$bus"; return; fi
			if [ "$(basename "$op")" = "$unit" ]; then echo "$bus"; return; fi
			case "$op" in *"$unit"*) echo "$bus"; return ;; esac
		done
	fi
	# fallback: common Modalix eLxr numbering
	case "$want" in
		i2c00) echo 0 ;;
		i2c01) echo 1 ;;
		i2c02) echo 2 ;;
		i2c52) echo 4 ;;
		*) echo "" ;;
	esac
}

echo
echo "=== aliases (if any) ==="
if [ -d /proc/device-tree/aliases ]; then
	for a in i2c00 i2c01 i2c02 i2c52; do
		if [ -e "/proc/device-tree/aliases/$a" ]; then
			printf '  %s -> %s\n' "$a" "$(tr '\0' ' ' <"/proc/device-tree/aliases/$a")"
		fi
	done
else
	echo "  (no /proc/device-tree/aliases)"
fi

B0=$(map_bus i2c00)
B1=$(map_bus i2c01)
B2=$(map_bus i2c02)
BC=$(map_bus i2c52)

echo
echo "=== mapped buses (best effort) ==="
echo "  I2C0  (i2c00 / gold finger 185-187 / J36+40pin I2C0):  /dev/i2c-${B0:-?}"
echo "  I2C1  (i2c01 / gold finger 189-191 / 40pin I2C1):       /dev/i2c-${B1:-?}"
echo "  I2C2  (i2c02 / gold finger 232-234 @ 1.8V):            /dev/i2c-${B2:-?}"
echo "  CAM   (i2c52 / FSUSB42 parent):                        /dev/i2c-${BC:-?}"

scan_one() {
	local label=$1
	local bus=$2
	echo
	echo "=== i2cdetect -y $bus  ($label) ==="
	if [ -z "$bus" ] || [ ! -c "/dev/i2c-$bus" ]; then
		echo "  SKIP: no /dev/i2c-$bus"
		return
	fi
	# -r: use read byte (avoids SMBus Quick issues on DesignWare)
	i2cdetect -y -r "$bus" || i2cdetect -y "$bus" || true
}

if [ -n "${I2C_BUS:-}" ]; then
	scan_one "user I2C_BUS" "$I2C_BUS"
else
	scan_one "I2C0 / i2c00" "$B0"
	scan_one "I2C1 / i2c01" "$B1"
	echo
	echo "=== CAM parent (optional) ==="
	scan_one "CAM i2c52" "$BC"
fi

echo
echo "=== pass hints ==="
echo "  I2C0: look for 0x25 (FUSB301). Optional external part on J36 I2C0 or 40-pin 27/28."
echo "  I2C1: empty is OK until a device is wired; 40-pin pin3=SDA pin5=SCL pin6=GND pin1=3V3."
echo "  Do NOT load SiMa uart01 overlay (steals I2C1 pins)."
echo "done"
