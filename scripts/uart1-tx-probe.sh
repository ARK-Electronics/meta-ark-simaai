#!/bin/sh
# Diagnose "UART1 TX never toggles on the carrier" on a Modalix SoM.
#
# Run this ON THE TARGET (eLxr / Yocto), as root.
#
#   ./uart1-tx-probe.sh report            # non-invasive: what the kernel thinks is set up
#   ./uart1-tx-probe.sh spam [seconds]    # transmit 0x55 on UART1 so there is an edge to scope
#   ./uart1-tx-probe.sh rx [seconds]      # hexdump whatever arrives on UART1 RX
#   ./uart1-tx-probe.sh loopback [secs]   # send a pattern, report whether it comes back
#   ./uart1-tx-probe.sh mux               # read the usb_uart12 line
#   ./uart1-tx-probe.sh mux carrier       # drive usb_uart12 low
#   ./uart1-tx-probe.sh mux usb           # drive usb_uart12 high (stock SoM default)
#
# WARNING: UART1 is the console on stock images.
#   - "mux carrier" is a DEAD END on JAJ: measured, it disables the on-module
#     FTDI (USB device disconnects) and puts nothing on the carrier. Kept only
#     so the line can be characterised. Leave it HIGH.
#   - "rx" and "loopback" stop serial-getty@ttyS0 for the duration.
# Run all of these over SSH/Ethernet, not over the console they disturb.
#
# Background (see docs/bringup-jaj.md):
#   UART1 = uart12 @ 0x0401a000 = SIO block 1, index 2 = SIO1 pins 4/5.
#   SIO1 GPIO controller (gpio10) is at 0x04011000; usb_uart12 is line 2 of port1.
set -eu

UART_DEV="${UART_DEV:-/dev/ttyS0}"
UART_MMIO=0401a000
PINMUX_DBG=/sys/kernel/debug/pinctrl/4010000.pinmux-simaai-sio-pinctrl/pinmux-pins

# DesignWare APB GPIO register block for SIO1
GPIO_BASE=0x04011000
GPIO_DR=0x04011000    # SWPORTA data
GPIO_DDR=0x04011004   # SWPORTA direction (1 = output)
MUX_BIT=2             # port1 line 2 = usb_uart12

die() { echo "ERROR: $*" >&2; exit 1; }

# ---- 32-bit MMIO helpers -------------------------------------------------
# Prefer busybox devmem / devmem2; fall back to python3 mmap on /dev/mem.
mmio_read() {
	addr=$1
	if command -v devmem >/dev/null 2>&1; then
		devmem "$addr"
	elif command -v devmem2 >/dev/null 2>&1; then
		devmem2 "$addr" w | sed -n 's/.*: 0x//p' | tail -1 | sed 's/^/0x/'
	else
		python3 - "$addr" <<-'EOF'
		import mmap, os, sys
		addr = int(sys.argv[1], 0)
		page = os.sysconf("SC_PAGE_SIZE")
		base, off = addr - addr % page, addr % page
		with open("/dev/mem", "rb") as f:
		    m = mmap.mmap(f.fileno(), page, mmap.MAP_SHARED,
		                  mmap.PROT_READ, offset=base)
		    print(hex(int.from_bytes(m[off:off + 4], "little")))
		    m.close()
		EOF
	fi
}

mmio_write() {
	addr=$1 val=$2
	if command -v devmem >/dev/null 2>&1; then
		devmem "$addr" 32 "$val"
	elif command -v devmem2 >/dev/null 2>&1; then
		devmem2 "$addr" w "$val" >/dev/null
	else
		python3 - "$addr" "$val" <<-'EOF'
		import mmap, os, sys
		addr, val = int(sys.argv[1], 0), int(sys.argv[2], 0)
		page = os.sysconf("SC_PAGE_SIZE")
		base, off = addr - addr % page, addr % page
		with open("/dev/mem", "r+b") as f:
		    m = mmap.mmap(f.fileno(), page, mmap.MAP_SHARED,
		                  mmap.PROT_READ | mmap.PROT_WRITE, offset=base)
		    m[off:off + 4] = (val & 0xffffffff).to_bytes(4, "little")
		    m.close()
		EOF
	fi
}

# ---- subcommands ---------------------------------------------------------
cmd_report() {
	echo "=== UART1 (uart12 @ 0x$UART_MMIO) ==="
	for n in /proc/device-tree/soc*/sio*/uart@0x$UART_MMIO \
	         /proc/device-tree/*/*/uart@0x$UART_MMIO; do
		[ -e "$n/status" ] || continue
		printf 'DT %s status=%s\n' "$n" "$(tr -d '\0' < "$n/status")"
	done

	echo
	echo "--- tty devices ---"
	ls -l /dev/ttyS* 2>/dev/null || echo "(no /dev/ttyS*)"
	if [ -d /sys/class/tty ]; then
		for t in /sys/class/tty/ttyS*; do
			[ -e "$t/device/of_node" ] || continue
			printf '%s -> %s\n' "${t##*/}" "$(readlink -f "$t/device/of_node")"
		done
	fi

	echo
	echo "--- who is using the console ---"
	tr -d '\0' < /proc/device-tree/chosen/bootargs 2>/dev/null | tr ' ' '\n' | grep -i console || true
	cat /sys/class/tty/console/active 2>/dev/null || true
	systemctl is-active "serial-getty@${UART_DEV##*/}.service" 2>/dev/null || true

	echo
	echo "--- pinmux (expect pins 4 and 5 owned by $UART_MMIO.uart / uart2_group) ---"
	if [ -r "$PINMUX_DBG" ]; then
		awk '$2 ~ /^[45]$/ || /uart2_group/' "$PINMUX_DBG" | head -20
	else
		echo "(no $PINMUX_DBG -- mount debugfs, or pinctrl name differs)"
		ls /sys/kernel/debug/pinctrl/ 2>/dev/null || true
	fi
	grep -i "$UART_MMIO" /sys/kernel/debug/pinctrl/pinctrl-handles 2>/dev/null || true

	echo
	cmd_mux_show

	echo
	echo "--- errors ---"
	dmesg 2>/dev/null | grep -iE "uart|pinctrl|serial" | tail -20 || true
}

cmd_mux_show() {
	dr=$(mmio_read $GPIO_DR)
	ddr=$(mmio_read $GPIO_DDR)
	# shell arithmetic understands 0x...
	bit=$(( ( dr >> MUX_BIT ) & 1 ))
	dir=$(( ( ddr >> MUX_BIT ) & 1 ))
	echo "--- usb_uart12 select (port1 line $MUX_BIT, SIO1_IO[$MUX_BIT]) ---"
	echo "SWPORTA_DR  = $dr"
	echo "SWPORTA_DDR = $ddr  (bit $MUX_BIT dir=$dir, 1=output)"
	if [ "$bit" = 1 ]; then
		echo "state       = HIGH  <- stock SoM default; UART1 pointed at the on-module USB/FTDI path"
	else
		echo "state       = LOW"
	fi
	command -v gpiofind >/dev/null 2>&1 && gpiofind usb_uart12 || true
}

cmd_mux() {
	case "${1:-show}" in
	show) cmd_mux_show ;;
	carrier|low|0)
		dr=$(mmio_read $GPIO_DR)
		new=$(( dr & ~(1 << MUX_BIT) ))
		echo "usb_uart12 -> LOW  (DR $dr -> $(printf '0x%08x' $new))"
		echo "NOTE: this may drop the SoM USB-C console. Scope now."
		mmio_write $GPIO_DR "$(printf '0x%08x' $new)"
		cmd_mux_show ;;
	usb|high|1)
		dr=$(mmio_read $GPIO_DR)
		new=$(( dr | (1 << MUX_BIT) ))
		echo "usb_uart12 -> HIGH (DR $dr -> $(printf '0x%08x' $new))"
		mmio_write $GPIO_DR "$(printf '0x%08x' $new)"
		cmd_mux_show ;;
	*) die "mux: expected show|carrier|usb" ;;
	esac
}

cmd_spam() {
	secs="${1:-30}"
	[ -c "$UART_DEV" ] || die "$UART_DEV is not a character device"
	stty -F "$UART_DEV" 115200 cs8 -cstopb -parenb -crtscts raw
	echo "Transmitting 0x55 on $UART_DEV for ${secs}s."
	echo "0x55 at 8N1 is an alternating bit pattern -- a clean 57.6 kHz square wave"
	echo "at 115200 baud. Scope SODIMM 203 *and* 205 (JAJ J6 TX and RX)."
	end=$(( $(cut -d. -f1 /proc/uptime) + secs ))
	# single open() for the whole burst, so the line stays keyed up
	while [ "$(cut -d. -f1 /proc/uptime)" -lt "$end" ]; do
		printf 'UUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUU'
	done > "$UART_DEV"
	echo "done"
}

# Take UART1 away from getty so injected bytes reach us instead of a login prompt.
GETTY=""
getty_stop() {
	GETTY="serial-getty@${UART_DEV##*/}.service"
	if systemctl is-active --quiet "$GETTY" 2>/dev/null; then
		echo "(stopping $GETTY for the duration)"
		systemctl stop "$GETTY"
	else
		GETTY=""
	fi
	trap getty_restore EXIT INT TERM
}
getty_restore() {
	[ -n "$GETTY" ] || return 0
	systemctl start "$GETTY" 2>/dev/null || true
	GETTY=""
}

cmd_rx() {
	secs="${1:-15}"
	[ -c "$UART_DEV" ] || die "$UART_DEV is not a character device"
	getty_stop
	stty -F "$UART_DEV" 115200 cs8 -cstopb -parenb -crtscts raw -echo
	echo "Listening on $UART_DEV for ${secs}s."
	echo "Drive the carrier UART1 pins from an external 3.3 V USB-serial adapter now."
	echo "Anything that shows up means the SoC's RX pad is reachable from that pin."
	timeout "$secs" cat "$UART_DEV" 2>/dev/null | od -An -tx1c || true
	getty_restore
	echo "done"
}

cmd_loopback() {
	secs="${1:-8}"
	pattern="ARKLOOPBACK0123456789"
	[ -c "$UART_DEV" ] || die "$UART_DEV is not a character device"
	echo "Jumper the two UART1 data pins together at the carrier connector first."
	getty_stop
	stty -F "$UART_DEV" 115200 cs8 -cstopb -parenb -crtscts raw -echo
	# keep the port open for the whole test so the reader does not race the writer
	( sleep 1; i=0; while [ $i -lt 20 ]; do printf '%s\r\n' "$pattern"; i=$((i + 1)); sleep 0.2; done > "$UART_DEV" ) &
	writer=$!
	got=$(timeout "$secs" cat "$UART_DEV" 2>/dev/null | tr -dc '[:print:]' || true)
	kill "$writer" 2>/dev/null || true
	wait "$writer" 2>/dev/null || true
	getty_restore
	echo "--- received ---"
	echo "$got" | cut -c1-200
	case "$got" in
	*"$pattern"*)
		echo
		echo "ECHO SEEN: the SoC drives AND receives on that connector."
		echo "The carrier path works -- your host TX/RX wiring is simply swapped." ;;
	*)
		echo
		echo "no echo: the loop is open somewhere between the SoC pads and the connector"
		echo "(gold finger not driven, translator direction/OE, or DNP in the path)." ;;
	esac
}

case "${1:-report}" in
report)   cmd_report ;;
spam)     shift; cmd_spam "$@" ;;
rx)       shift; cmd_rx "$@" ;;
loopback) shift; cmd_loopback "$@" ;;
mux)      shift; cmd_mux "$@" ;;
-h|--help|help) sed -n '2,25p' "$0" ;;
*) die "unknown command '$1' (try: report | spam | rx | loopback | mux)" ;;
esac
