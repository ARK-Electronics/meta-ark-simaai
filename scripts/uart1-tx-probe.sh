#!/bin/sh
# Bring up / diagnose UART1 on the JAJ J6 header with a Modalix SoM.
#
# Run this ON THE TARGET (eLxr / Yocto), as root.
#
#   ./uart1-tx-probe.sh report            # non-invasive: counters, pinmux, console owner
#   ./uart1-tx-probe.sh tx [secs] [baud]  # light paced printf -- the safe default test
#   ./uart1-tx-probe.sh rx [seconds]      # hexdump whatever arrives on UART1 RX
#   ./uart1-tx-probe.sh loopback [secs]   # send a pattern, report whether it comes back
#   ./uart1-tx-probe.sh spam [seconds]    # paced 0x55 when you need a scope trigger
#   ./uart1-tx-probe.sh mux [show|carrier|usb]   # read/drive the usb_uart12 line
#
# Pick the port with UART_DEV:
#   UART_DEV=/dev/ttyS0  (default) uart12, J6 pins 2/3 -- also the console + SoM USB-C
#   UART_DEV=/dev/ttyS2           uart13, J6 pins 5/4 -- no console, no getty
#   UART_DEV=/dev/ttyS1           uart42 = UART0 on J5 -- the known-good reference
#
# THE J6 HEADER NEEDS SWAPPED DATA WIRES. The UART1 pair is reversed on the gold
# finger (every SIO UART pair is even=RX / odd=TX, so SODIMM 205 -- the pin JAJ
# labels UART1_RXD, J6 pin 3 -- is the SoC's TX). Wire host TX to J6 pin 2 and
# host RX to J6 pin 3, and add a 604R-2k2 pull-up from pin 3 to 3.3 V: JAJ's U10
# is an LSF0108 pass-FET translator with one pull-up per channel on the receiving
# side, so the net carrying the SoC's TX only reaches ~1.8 V without it. Do not
# pull up to J6 pin 1 -- that is 5 V. See docs/bringup-jaj.md.
#
# The quickest progress check needs no scope: "report" prints the tx/rx byte
# counters. rx staying at 0 means nothing has ever reached the SoC's RX pad.
#
# HAZARD: do not flood a Modalix UART at wire speed. Sustained unpaced 0x55 on
# UART0 (/dev/ttyS1) correlated with a hard board hang -- Ethernet, SSH and the
# USB-C console all went away, and the next boots were ~30 s with an unclean FAT.
# "spam" is therefore paced (64 B / 100 ms) and capped at 60 s. Prefer "tx".
#
# WARNING: UART1 (ttyS0) is the console on stock images.
#   - "mux carrier" is a DEAD END on JAJ: measured, it disables the on-module
#     FTDI (USB device disconnects) and puts nothing on the carrier. Kept only
#     so the line can be characterised. Leave it HIGH.
#   - "rx" and "loopback" stop serial-getty@<port> for the duration.
#   - The SoM's FT230X shares the SoC's UART1 net and wins any contest against a
#     J6 host driving through U10 -- unplug USB-C when testing J6 rx on ttyS0.
# Run all of these over SSH/Ethernet, not over the console they disturb.
#
# Background (see docs/bringup-jaj.md):
#   UART1 = uart12 @ 0x0401a000 = SIO block 1, index 2 = SIO1 pins 4/5.
#   uart13 @ 0x0401c000 = SIO1 index 3 = SIO1 pins 6/7 = SODIMM 207/209 = J6 5/4.
#   SIO1 GPIO controller (gpio10) is at 0x04011000; usb_uart12 is line 2 of port1.
set -eu

UART_DEV="${UART_DEV:-/dev/ttyS0}"

# Which controller + SIO block the chosen tty belongs to. ark-jaj.dtbo pins these
# with serialN aliases, so the mapping is stable across boots.
case "$UART_DEV" in
*ttyS0) UART_NAME="UART1 / uart12"; UART_MMIO=0401a000; SIO_PINCTRL=4010000; SIO_PINS="4/5" ;;
*ttyS1) UART_NAME="UART0 / uart42"; UART_MMIO=0404a000; SIO_PINCTRL=4040000; SIO_PINS="4/5" ;;
*ttyS2) UART_NAME="uart13 (J6 pins 5/4)"; UART_MMIO=0401c000; SIO_PINCTRL=4010000; SIO_PINS="6/7" ;;
*)      UART_NAME="unknown"; UART_MMIO=0401a000; SIO_PINCTRL=4010000; SIO_PINS="4/5" ;;
esac
PINMUX_DBG=/sys/kernel/debug/pinctrl/${SIO_PINCTRL}.pinmux-simaai-sio-pinctrl/pinmux-pins

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
	echo "=== $UART_NAME @ 0x$UART_MMIO ($UART_DEV) ==="
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
	echo "--- byte counters (no scope needed) ---"
	# tx climbing with rx pegged at 0 means the SoC talks but nothing ever reaches
	# its RX pad: on J6 that is the reversed pair, not a dead UART.
	if [ -r /proc/tty/driver/serial ]; then
		awk 'NR==1 || /uart:16550A/' /proc/tty/driver/serial
	else
		echo "(no /proc/tty/driver/serial)"
	fi

	echo
	echo "--- who is using the console ---"
	tr -d '\0' < /proc/device-tree/chosen/bootargs 2>/dev/null | tr ' ' '\n' | grep -i console || true
	cat /sys/class/tty/console/active 2>/dev/null || true
	systemctl is-active "serial-getty@${UART_DEV##*/}.service" 2>/dev/null || true

	echo
	echo "--- pinmux (expect SIO pins $SIO_PINS owned by $UART_MMIO.uart) ---"
	if [ -r "$PINMUX_DBG" ]; then
		lo=${SIO_PINS%%/*}; hi=${SIO_PINS##*/}
		awk -v lo="$lo" -v hi="$hi" '$2 == lo || $2 == hi || /_group/' "$PINMUX_DBG" | head -20
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

# Light, human-readable traffic. This is the test to reach for first: enough to see
# on a terminal or a scope, nowhere near enough to wedge the board.
cmd_tx() {
	secs="${1:-10}"
	baud="${2:-115200}"
	[ -c "$UART_DEV" ] || die "$UART_DEV is not a character device"
	[ "$secs" -le 120 ] 2>/dev/null || die "refusing ${secs}s; keep tx bursts <= 120s"
	stty -F "$UART_DEV" "$baud" cs8 -cstopb -parenb -crtscts raw
	echo "Sending markers on $UART_DEV at $baud for ${secs}s."
	echo "Watch the host end of the header. On J6 remember the wires are swapped:"
	echo "  host RX <- J6 pin 3 (needs the 3V3 pull-up), host TX -> J6 pin 2."
	echo "If 9600 works and 115200 does not, the pull-up is what is missing."
	end=$(( $(cut -d. -f1 /proc/uptime) + secs ))
	i=0
	while [ "$(cut -d. -f1 /proc/uptime)" -lt "$end" ]; do
		i=$((i + 1))
		printf 'ARK_UART1_TX_OK %d\r\n' "$i" > "$UART_DEV"
		sleep 0.5
	done
	echo "sent $i markers"
}

cmd_spam() {
	secs="${1:-20}"
	[ -c "$UART_DEV" ] || die "$UART_DEV is not a character device"
	[ "$secs" -le 60 ] 2>/dev/null || die "refusing ${secs}s; keep bursts <= 60s (see hazard note)"
	stty -F "$UART_DEV" 115200 cs8 -cstopb -parenb -crtscts raw
	echo "Transmitting paced 0x55 bursts on $UART_DEV for ${secs}s."
	echo "0x55 at 8N1 is an alternating bit pattern -- a clean 57.6 kHz square wave"
	echo "at 115200 baud, easy to trigger on. Scope both connector data pins."
	end=$(( $(cut -d. -f1 /proc/uptime) + secs ))
	# PACED, not wire-speed. An unpaced flood on ttyS1/UART0 correlated with a hard
	# board hang (eth + SSH + USB-C all gone, unclean FAT on reboot). A 64-byte
	# burst every 100 ms is ~5% duty -- plenty of edges to scope, no sustained load.
	while [ "$(cut -d. -f1 /proc/uptime)" -lt "$end" ]; do
		printf 'UUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUU' > "$UART_DEV"
		sleep 0.1
	done
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
tx)       shift; cmd_tx "$@" ;;
spam)     shift; cmd_spam "$@" ;;
rx)       shift; cmd_rx "$@" ;;
loopback) shift; cmd_loopback "$@" ;;
mux)      shift; cmd_mux "$@" ;;
-h|--help|help) sed -n '2,44p' "$0" ;;
*) die "unknown command '$1' (try: report | tx | spam | rx | loopback | mux)" ;;
esac
