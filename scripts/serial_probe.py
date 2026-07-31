#!/usr/bin/env python3
"""Login over Modalix serial console and run diagnostic / flash-prep commands."""
import argparse
import serial
import sys
import time


def read_for(ser, seconds=2.0):
    end = time.time() + seconds
    data = b""
    while time.time() < end:
        chunk = ser.read(4096)
        if chunk:
            data += chunk
        else:
            time.sleep(0.05)
    return data.decode("utf-8", errors="replace")


def send(ser, cmd, wait=1.5):
    ser.write((cmd + "\r\n").encode())
    ser.flush()
    return read_for(ser, wait)


def ensure_login(ser, user="sima", password="edgeai"):
    ser.reset_input_buffer()
    ser.write(b"\r\n")
    time.sleep(0.4)
    out = read_for(ser, 1.5)
    print("=== initial ===")
    print(out)

    # Already at shell?
    if any(p in out for p in ("$", "#", "sima@", "root@", "modalix:")) and "login:" not in out.lower():
        # might still be password prompt
        if "assword" in out.lower():
            print("=== sending password ===")
            ser.write((password + "\r\n").encode())
            print(read_for(ser, 3.0))
        return

    if "login:" in out.lower():
        print(f"=== login as {user} ===")
        ser.write((user + "\r\n").encode())
        time.sleep(0.8)
        out = read_for(ser, 2.0)
        print(out)
        if "assword" in out.lower():
            ser.write((password + "\r\n").encode())
            print(read_for(ser, 4.0))
    elif "assword" in out.lower():
        ser.write((password + "\r\n").encode())
        print(read_for(ser, 4.0))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default="/dev/ttyUSB0")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument(
        "--cmd",
        action="append",
        default=[],
        help="Extra command to run after login (repeatable)",
    )
    ap.add_argument("--probe", action="store_true", help="Run standard probe commands")
    args = ap.parse_args()

    ser = serial.Serial(args.port, args.baud, timeout=0.5)
    time.sleep(0.2)
    try:
        ensure_login(ser)
        cmds = list(args.cmd)
        if args.probe or not cmds:
            cmds = [
                "whoami",
                "uname -a",
                "hostname",
                "cat /etc/os-release 2>/dev/null; echo ---; cat /etc/build 2>/dev/null; cat /etc/buildinfo 2>/dev/null; true",
                "ip -br addr 2>/dev/null || ifconfig",
                "lsblk",
                "df -h",
                "ping -c 1 -W 2 192.168.7.125 2>&1; ping -c 1 -W 2 8.8.8.8 2>&1; true",
            ]
        for cmd in cmds:
            # crude wait heuristic
            wait = 6.0 if cmd.startswith("ping") else 2.5
            if "cat " in cmd:
                wait = 3.5
            print(f"\n=== CMD: {cmd} ===")
            print(send(ser, cmd, wait))
    finally:
        ser.close()
    print("DONE")


if __name__ == "__main__":
    main()
