#!/usr/bin/env python3
"""Test a JAJ J6 UART link end to end, from the host, and name the failure mode.

Runs on the HOST. Drives the USB-serial adapter wired to J6 while driving the board
over SSH, so both directions get checked without a scope and without guessing.

    ./scripts/uart1-j6-linktest.py                       # ttyS0 (uart12), J6 pins 2/3
    ./scripts/uart1-j6-linktest.py --dev /dev/ttyS2      # uart13, J6 pins 5/4
    ./scripts/uart1-j6-linktest.py --port /dev/ttyUSB1 --bauds 115200

Board -> host is measured by looking for a marker string on the adapter.
Host -> board is measured from the kernel's own receive counter in
/proc/tty/driver/serial, which counts bytes that actually reached the SoC's RX pad
regardless of whether anything is consuming them.

Wiring note (see docs/bringup-jaj.md): on J6 the UART1 pair is reversed relative to
the silkscreen, so host TX belongs on pin 2 and host RX on pin 3, and pin 3 needs a
604R-2k2 pull-up to 3.3 V. Testing at both 115200 and 9600 separates those two
faults: an adapter's own weak internal pull-up is too slow at 115200 but often
sufficient at 9600, so "9600 passes, 115200 fails" means the pull-up is missing.

Needs pyserial + paramiko, and read/write access to the adapter (group dialout).
"""
import argparse
import re
import sys
import threading
import time

try:
    import serial
except ImportError:
    sys.exit("need pyserial: apt install python3-serial")
try:
    import paramiko
except ImportError:
    sys.exit("need paramiko: apt install python3-paramiko")

MARKER = "ARKJ6"


class Board:
    def __init__(self, host, user, password):
        self.password = password
        self.c = paramiko.SSHClient()
        self.c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        self.c.connect(host, username=user, password=password, timeout=15,
                       allow_agent=False, look_for_keys=False)

    def run(self, cmd, sudo=False, timeout=120):
        if sudo:
            cmd = "echo %s | sudo -S bash -c '%s'" % (self.password, cmd.replace("'", "'\\''"))
        _, out, err = self.c.exec_command(cmd, timeout=timeout)
        return out.read().decode("utf-8", "replace") + err.read().decode("utf-8", "replace")

    def rx_count(self, mmio):
        """Kernel's received-byte count for the UART at this MMIO address."""
        txt = self.run("cat /proc/tty/driver/serial", sudo=True)
        for line in txt.splitlines():
            if mmio.lower() in line.lower():
                m = re.search(r"\brx:(\d+)", line)
                if m:
                    return int(m.group(1))
        return None

    def close(self):
        self.c.close()


class Listener:
    """Background reader so the adapter never overflows while the board talks."""

    def __init__(self, ser):
        self.ser = ser
        self.buf = bytearray()
        self.stop = threading.Event()
        self.t = threading.Thread(target=self._run, daemon=True)
        self.t.start()

    def _run(self):
        while not self.stop.is_set():
            try:
                n = self.ser.in_waiting
                self.buf += self.ser.read(n) if n else b""
            except Exception:
                return
            if not n:
                time.sleep(0.02)

    def take(self):
        b = bytes(self.buf)
        self.buf.clear()
        return b

    def done(self):
        self.stop.set()
        self.t.join(timeout=2)


DEV_INFO = {
    "/dev/ttyS0": ("0x0401A000", "uart12 / UART1", "J6 pins 2 (TX) and 3 (RX)"),
    "/dev/ttyS1": ("0x0404A000", "uart42 / UART0", "J5 header (reference, known good)"),
    "/dev/ttyS2": ("0x0401C000", "uart13", "J6 pins 5 and 4"),
}


def phase_board_to_host(board, dev, listener, baud, count=12):
    listener.take()
    board.run("stty -F %s %d cs8 -cstopb -parenb -crtscts raw" % (dev, baud), sudo=True)
    board.run("for i in $(seq 1 %d); do printf '%s_%%d\\r\\n' $i > %s; sleep 0.15; done"
              % (count, MARKER, dev), sudo=True)
    time.sleep(0.6)
    got = listener.take()
    hits = got.count(MARKER.encode())
    return hits, got


def phase_host_to_board(board, dev, ser, mmio, count=12):
    before = board.rx_count(mmio)
    payload = ("".join("%s_HOST_%d\r\n" % (MARKER, i) for i in range(1, count + 1))).encode()
    ser.write(payload)
    ser.flush()
    time.sleep(1.0)
    after = board.rx_count(mmio)
    if before is None or after is None:
        return None, None, len(payload)
    return after - before, before, len(payload)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default="/dev/ttyUSB0", help="host adapter wired to J6")
    ap.add_argument("--dev", default="/dev/ttyS0", help="board tty under test")
    ap.add_argument("--board", default="sima@192.168.7.50")
    ap.add_argument("--password", default="edgeai")
    ap.add_argument("--bauds", nargs="+", type=int, default=[115200, 9600])
    args = ap.parse_args()

    user, _, host = args.board.rpartition("@")
    mmio, name, wiring = DEV_INFO.get(args.dev, ("?", args.dev, "?"))
    print("board tty : %s  (%s @ %s)" % (args.dev, name, mmio))
    print("expected  : %s" % wiring)
    print("host port : %s" % args.port)

    try:
        serial.Serial(args.port).close()
    except serial.SerialException as e:
        if "Permission denied" in str(e):
            sys.exit("cannot open %s: add yourself to dialout and re-login:\n"
                     "  sudo usermod -aG dialout $USER && newgrp dialout" % args.port)
        sys.exit("cannot open %s: %s" % (args.port, e))

    board = Board(host, user or "sima", args.password)
    getty = "serial-getty@%s.service" % args.dev.split("/")[-1]
    was_active = "active" == board.run("systemctl is-active %s" % getty).strip()
    if was_active:
        print("stopping %s for the duration" % getty)
        board.run("systemctl stop %s" % getty, sudo=True)

    results = {}
    try:
        for baud in args.bauds:
            print("\n=== %d baud ===" % baud)
            ser = serial.Serial(args.port, baud, timeout=0.2, rtscts=False, dsrdtr=False)
            lst = Listener(ser)
            try:
                hits, raw = phase_board_to_host(board, args.dev, lst, baud)
                print("board -> host : %d/12 markers%s" % (hits, "" if hits else "   <-- nothing"))
                if raw and not hits:
                    print("                saw %d bytes of something else: %r" % (len(raw), raw[:80]))
                delta, before, sent = phase_host_to_board(board, args.dev, ser, mmio)
                if delta is None:
                    print("host -> board : could not read rx counter")
                else:
                    print("host -> board : rx counter +%d of %d bytes sent (was %s)"
                          % (delta, sent, before))
                results[baud] = (hits, delta)
            finally:
                lst.done()
                ser.close()
    finally:
        if was_active:
            board.run("systemctl start %s" % getty, sudo=True)
        board.close()

    # ---- verdict -----------------------------------------------------------
    print("\n=== verdict ===")
    tx_any = any(h for h, _ in results.values())
    rx_any = any((d or 0) > 0 for _, d in results.values())
    tx_fast = results.get(115200, (0, 0))[0]
    tx_slow = results.get(9600, (0, 0))[0]

    if tx_any and rx_any:
        print("LINK UP in both directions on %s." % args.dev)
        if tx_slow and not tx_fast:
            print("But board->host only worked at 9600: the 3V3 pull-up is still missing,")
            print("and 115200 is riding the adapter's weak internal pull-up. Fit 604R-2k2")
            print("from the board's TX pin to 3.3 V for a reliable 115200 link.")
    elif rx_any and not tx_any:
        print("host -> board works, board -> host does not.")
        print("That is the missing 3V3 pull-up on the net carrying the SoC's TX: the")
        print("LSF0108 cannot source a high, so a mark only reaches ~1.8 V. Fit 604R-2k2")
        print("to 3.3 V on that pin -- not to J6 pin 1, which is 5 V.")
    elif tx_any and not rx_any:
        print("board -> host works, host -> board does not.")
        print("Check GND, and unplug the SoM USB-C cable: the on-module FT230X drives the")
        print("same SoC RX net directly and beats a J6 host coming through the translator.")
    else:
        print("Dead both ways -- the data wires are most likely still not swapped.")
        print("On J6 wire host TX -> pin 2 and host RX -> pin 3 (pin 1 is 5 V, pin 6 GND).")
        print("If a swap does not help, jumper the two data pins and run")
        print("  sudo ./uart1-tx-probe.sh loopback")
        print("on the board: an echo proves the module does reach the connector.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
