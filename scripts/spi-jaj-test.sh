#!/usr/bin/env bash
# Probe gold-finger SPI0 (nvs_spi0 → /dev/spidev*) on JAJ + Modalix.
# Optional: Murata SCH16T-K10 SafeSPI48 ID/temp read if sch16t-spi-test is present.
#
# Run ON THE TARGET as root:
#   sudo bash /usr/local/sbin/spi-jaj-test.sh
#   sudo bash /usr/local/sbin/spi-jaj-test.sh /dev/spidev0.0
set -euo pipefail

echo "=== SPI masters ==="
ls -la /sys/class/spi_master/ 2>/dev/null || echo "(none)"
ls -la /sys/bus/spi/devices/ 2>/dev/null || true

echo
echo "=== spidev nodes ==="
ls -la /dev/spidev* 2>/dev/null || echo "no /dev/spidev* — is nvs_spi0 enabled in DT?"

echo
echo "=== dmesg (spi) ==="
dmesg | grep -iE 'spi|spidev|dw_spi|4088000|nvs' | tail -30 || true

echo
echo "=== DT nvs_spi0 status ==="
n=/proc/device-tree/nvs@0/spi@0x04088000
if [ -d "$n" ]; then
	echo -n "status: "; tr '\0' ' ' < "$n/status" 2>/dev/null; echo
	find "$n" -maxdepth 2 -type d | head -20
else
	echo "missing $n"
fi

DEV="${1:-}"
if [ -z "$DEV" ]; then
	# Prefer first spidev
	DEV=$(ls /dev/spidev* 2>/dev/null | head -1 || true)
fi

if [ -z "${DEV}" ] || [ ! -c "$DEV" ]; then
	echo
	echo "FAIL: no spidev character device. Deploy ark-jaj.dtbo with &nvs_spi0 and reboot."
	exit 1
fi

echo
echo "=== Using $DEV ==="
if command -v spi-config >/dev/null 2>&1; then
	spi-config -d "$DEV" -m 0 -s 1000000 -b 8 -q || true
fi

# Raw loopback-style clocking: transfer 6 bytes of 0x00 / 0xFF (no loopback expected)
if command -v spi-pipe >/dev/null 2>&1; then
	echo "spi-pipe 6-byte 0xA5 dump:"
	printf '\xa5\xa5\xa5\xa5\xa5\xa5' | spi-pipe -d "$DEV" -s 1000000 -b 8 | od -An -tx1
fi

TEST_BIN=""
for p in /usr/local/sbin/sch16t-spi-test ./sch16t-spi-test /tmp/ark-jaj-dtbo/sch16t-spi-test; do
	if [ -x "$p" ]; then TEST_BIN=$p; break; fi
done

if [ -n "$TEST_BIN" ]; then
	echo
	echo "=== SCH16T-K10 SafeSPI48 ($TEST_BIN) ==="
	"$TEST_BIN" "$DEV" 1000000
else
	echo
	echo "(sch16t-spi-test not installed — raw spidev only)"
	# Minimal python-free hex dump via dd + spi ioctl would need the C tool
fi
