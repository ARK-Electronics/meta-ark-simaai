#!/usr/bin/env bash
# One-time bring-up of a *stock* Modalix SoM on ARK Jetson PAB V3.
#
# Stock Modalix U-Boot programs MAC SS=100M_MII when the KSZ links at
# 100 Mb/s, so TFTP sends no frames. This script uses USB-C serial
# (DTR/RTS off) to unreset the KSZ. Install ark-pab-v3 U-Boot (patches
# 0001/0002 keep MAC at 1G GMII and set XPCS C37 to copper speed) plus
# ark-pab-v3.dtbo; then USB-C + Ethernet TFTP matches JAJ.
#
# Usage:
#   ./scripts/pab-v3-firstboot.sh
#   SERIAL=/dev/serial/by-id/usb-FTDI_FT230X_Basic_UART_*-if00-port0 ./scripts/pab-v3-firstboot.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASSWORD="${PASSWORD:-edgeai}"
BOARD_IP="${BOARD_IP:-192.168.1.20}"

if [ -z "${SERIAL:-}" ]; then
    shopt -s nullglob
    ids=(/dev/serial/by-id/usb-FTDI_FT230X_Basic_UART_*-if00-port0)
    shopt -u nullglob
    if [ "${#ids[@]}" -eq 0 ]; then
        echo "No FT230X USB-C console (SoM debug). Plug USB-C." >&2
        exit 1
    fi
    SERIAL="${ids[0]}"
fi
echo "==> serial $SERIAL"

python3 - "$SERIAL" "$PASSWORD" "$BOARD_IP" <<'PY'
import os, mmap, struct, serial, sys, time, base64

port, password, board_ip = sys.argv[1:4]

def open_ser():
    s = serial.Serial()
    s.port = port
    s.baudrate = 115200
    s.timeout = 0.2
    s.dtr = False
    s.rts = False
    s.open()
    time.sleep(0.08)
    try:
        s.reset_input_buffer()
    except Exception:
        pass
    return s

def wait_prompt(s, timeout=20.0):
    buf = b""
    end = time.time() + timeout
    while time.time() < end:
        chunk = s.read(8192)
        if chunk:
            buf += chunk
            if any(x in buf[-100:] for x in (b"login:", b"Password:", b"sima$ ", b"$ ", b"# ")):
                time.sleep(0.12)
                buf += s.read(4096)
                return buf
        else:
            time.sleep(0.03)
    return buf

def cmd(s, line, timeout=20.0):
    s.write(line.encode() + b"\r")
    s.flush()
    out = wait_prompt(s, timeout).decode("utf-8", "replace")
    print(out[-800:])
    return out

ksz_py = r'''
import os, mmap, struct, time
def w32(addr, val):
    page = addr & ~0xfff
    fd = os.open("/dev/mem", os.O_RDWR|os.O_SYNC)
    m = mmap.mmap(fd, 0x1000, offset=page)
    struct.pack_into("<I", m, addr-page, val)
    m.close(); os.close(fd)
w32(0x04070210, 0x3ff)
w32(0x04070300, 0x1)
w32(0x04070300, 0x80000001)
w32(0x04070110, 0x77777777)
w32(0x04070118, 0xff)
w32(0x0407011c, 0xff)
w32(0x04070204, 0x0101)
w32(0x04070208, 0x02020202)
w32(0x04071008, 0x00)
w32(0x04071004, 0x2a)
w32(0x04071000, 0x0a)
print("KSZ_GPIO_DONE")
'''

uboot_gpios = [
    "mw.l 0x04070210 0x3ff",
    "mw.l 0x04070300 0x1",
    "mw.l 0x04070300 0x80000001",
    "mw.l 0x04070110 0x77777777",
    "mw.l 0x04070118 0xff",
    "mw.l 0x0407011c 0xff",
    "mw.l 0x04070204 0x0101",
    "mw.l 0x04070208 0x02020202",
    "mw.l 0x04071008 0x00",
    "mw.l 0x04071004 0x2a",
    "mw.l 0x04071000 0x0a",
    "mii write 0 4 0x0181",
    "mii write 0 9 0x0000",
    "mii write 0 0 0x3300",
]

s = open_ser()
s.write(b"\r")
pre = wait_prompt(s, 8).decode("utf-8", "replace")
print(pre[-400:])

if "sima$ " in pre[-80:] and "login:" not in pre and "@" not in pre[-120:]:
    print("==> U-Boot: release KSZ, boot eMMC")
    for c in uboot_gpios:
        cmd(s, c, 8)
    time.sleep(1)
    cmd(s, "mii info", 8)
    cmd(s, "setenv boot_targets mmc0", 6)
    s.write(b"boot\r")
    s.flush()
    buf = b""
    end = time.time() + 80
    while time.time() < end:
        chunk = s.read(16384)
        if chunk:
            buf += chunk
            if b"login:" in buf[-400:]:
                break
        else:
            time.sleep(0.05)
    print(buf.decode("utf-8", "replace")[-400:])
    if b"login:" in buf[-400:]:
        pre = "login:"
    else:
        pre = wait_prompt(s, 8).decode("utf-8", "replace")

if "login:" in pre:
    cmd(s, "sima", 8)
    cmd(s, password, 12)
elif "Password:" in pre:
    cmd(s, password, 12)

print("==> Linux: SIO7 KSZ poke +", board_ip)
b64 = base64.b64encode(ksz_py.encode()).decode()
cmd(s, "rm -f /tmp/ksz.py /tmp/ksz.b64; touch /tmp/ksz.b64")
# short printf chunks — a single python -c line breaks under serial/resize
for i in range(0, len(b64), 80):
    cmd(s, "printf '%s' '" + b64[i:i+80] + "' >> /tmp/ksz.b64")
cmd(s, "python3 -c 'import base64; open(\"/tmp/ksz.py\",\"wb\").write(base64.b64decode(open(\"/tmp/ksz.b64\").read()))'")
cmd(s, f"echo {password} | sudo -S python3 /tmp/ksz.py", 15)
cmd(s, f"echo {password} | sudo -S bash -c 'ip addr flush dev end0; ip addr add {board_ip}/24 dev end0; ip link set end0 up'", 15)
# stmmac SGMII + KSZ AN is often ~4s; USB-C can re-enum around end0-up
time.sleep(6)
cmd(s, "ip -br a; echo edgeai | sudo -S ethtool end0 2>/dev/null | grep -E 'Speed|Duplex|Link|detected' || true; echo FIRSTBOOT_ETH")
s.close()
time.sleep(2)
print("==> serial KSZ done")
PY

echo "==> deploy ark-pab-v3.dtbo"
PASSWORD="$PASSWORD" "$SCRIPT_DIR/deploy-pab-v3-dtbo.sh" --serial "$SERIAL"

echo
echo "Linux Ethernet should be 100 Mb/s at $BOARD_IP."
echo "deploy-pab-v3-dtbo.sh also stages ark-jaj-usb-init.sh (FUSB301 helper;"
echo "filenames are from JAJ — this is not ark-jaj.dtbo)."
echo "Stock eLxr U-Boot still will not TFTP on PAB V3 until ark-pab-v3 U-Boot"
echo "(SGMII 1G-MAC + XPCS C37 patches) is programmed from a Yocto build."
