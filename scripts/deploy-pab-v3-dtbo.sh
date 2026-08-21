#!/usr/bin/env bash
# Build ark-pab-v3.dtbo and install it on a live Modalix board (eLxr / Yocto).
# Sets U-Boot dtbos so the overlay is applied on every boot.
#
# Usage:
#   BOARD=sima@192.168.7.50 ./scripts/deploy-pab-v3-dtbo.sh
#   PASSWORD=edgeai BOARD=sima@192.168.7.50 ./scripts/deploy-pab-v3-dtbo.sh --reboot
#
# Serial-only (no eth yet — common when KSZ8795 is held in reset under JAJ DT):
#   ./scripts/deploy-pab-v3-dtbo.sh --serial /dev/ttyUSB1 --reboot
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DTSO="$REPO_DIR/recipes-kernel/ark-carrier-dtbo/files/ark-pab-v3.dtso"
# FUSB301 Type-C helper (same chip as JAJ @ i2c-0 0x25). Filenames are
# historical; this does not install ark-jaj.dtbo.
USB_INIT="$REPO_DIR/scripts/ark-jaj-usb-init.sh"
USB_SVC="$REPO_DIR/scripts/ark-jaj-usb.service"
HDMI_UNBLANK="$REPO_DIR/scripts/ark-hdmi-unblank.sh"
HDMI_XORG="$REPO_DIR/scripts/10-ark-no-blank.conf"
HDMI_LDM="$REPO_DIR/scripts/10-ark-hdmi-lightdm.conf"
HDMI_UDEV="$REPO_DIR/scripts/99-ark-hdmi.rules"
HDMI_INSTALL="$REPO_DIR/scripts/install-ark-hdmi.sh"
BOARD="${BOARD:-sima@192.168.7.50}"
PASSWORD="${PASSWORD:-edgeai}"
REBOOT=0
SERIAL=""
SSH_OPTS=(-o PreferredAuthentications=password -o PubkeyAuthentication=no -o StrictHostKeyChecking=accept-new)

while [[ $# -gt 0 ]]; do
    case "$1" in
        --reboot) REBOOT=1; shift ;;
        --board) BOARD="$2"; shift 2 ;;
        --serial) SERIAL="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,14p' "$0"
            exit 0 ;;
        *) echo "Unknown: $1" >&2; exit 1 ;;
    esac
done

if [ ! -f "$DTSO" ]; then
    echo "ERROR: missing $DTSO" >&2
    exit 1
fi

remote_install_body() {
    cat <<'EOS'
set -e
REMOTE_DIR=/tmp/ark-pab-v3-dtbo
dtc -@ -I dts -O dtb -o $REMOTE_DIR/ark-pab-v3.dtbo $REMOTE_DIR/ark-pab-v3.dtso
ls -la $REMOTE_DIR/ark-pab-v3.dtbo
install -m 0644 $REMOTE_DIR/ark-pab-v3.dtbo /boot/boot-0/ark-pab-v3.dtbo
install -m 0644 $REMOTE_DIR/ark-pab-v3.dtbo /boot/boot-1/ark-pab-v3.dtbo
mkdir -p /boot/boot-0/overlays /boot/boot-1/overlays 2>/dev/null || true
cp -f /boot/boot-0/ark-pab-v3.dtbo /boot/boot-0/overlays/ 2>/dev/null || true
cp -f /boot/boot-1/ark-pab-v3.dtbo /boot/boot-1/overlays/ 2>/dev/null || true
if [ -f $REMOTE_DIR/ark-jaj-usb-init.sh ]; then
  install -d /usr/local/sbin
  install -m 0755 $REMOTE_DIR/ark-jaj-usb-init.sh /usr/local/sbin/ark-jaj-usb-init.sh
fi
if [ -f $REMOTE_DIR/ark-jaj-usb.service ]; then
  install -m 0644 $REMOTE_DIR/ark-jaj-usb.service /etc/systemd/system/ark-jaj-usb.service
  mkdir -p /etc/systemd/system/ark-jaj-usb.service.d
  printf '%s\n' '[Service]' 'Environment=ROLE_POLICY=prefer-host' \
    > /etc/systemd/system/ark-jaj-usb.service.d/pab-v3.conf
  systemctl daemon-reload 2>/dev/null || true
  systemctl enable ark-jaj-usb.service 2>/dev/null || true
  ROLE_POLICY=prefer-host /usr/local/sbin/ark-jaj-usb-init.sh || true
fi
if [ -f $REMOTE_DIR/install-ark-hdmi.sh ]; then
  bash $REMOTE_DIR/install-ark-hdmi.sh $REMOTE_DIR
fi
mkdir -p /tmp/boot
cp -a /boot/uboot.env /boot/uboot-redund.env /tmp/boot/
cat > /tmp/fw_env.config << EOF
/tmp/boot/uboot.env 0x0000 0x80000
/tmp/boot/uboot-redund.env 0x0000 0x80000
EOF
if [ -f /boot/boot-0/modalix-som_16g.dtb ]; then
  fw_setenv -c /tmp/fw_env.config fdt_name modalix-som_16g.dtb
elif [ -f /boot/boot-0/modalix-som.dtb ]; then
  fw_setenv -c /tmp/fw_env.config fdt_name modalix-som.dtb
fi
fw_setenv -c /tmp/fw_env.config dtbos ark-pab-v3.dtbo
cp -a /tmp/boot/uboot.env /tmp/boot/uboot-redund.env /boot/
sync
echo "--- env check ---"
fw_printenv -c /tmp/fw_env.config fdt_name dtbos boot_path
ls -la /boot/boot-0/ark-pab-v3.dtbo
echo INSTALL_OK
EOS
}

if [ -n "$SERIAL" ]; then
    echo "==> Serial deploy via $SERIAL"
    # Prefer SSH once eth works; serial path stages as user and installs with sudo -S.
    python3 - "$SERIAL" "$DTSO" "$USB_INIT" "$USB_SVC" "$PASSWORD" "$REBOOT" <<'PY'
import sys, serial, time, base64, os

port, dtso, usb_init, usb_svc, password, reboot = sys.argv[1:7]
reboot = reboot == "1"

def open_ser():
    # Do not assert DTR/RTS: on this SoM they reset the board.
    s = serial.Serial()
    s.port = port
    s.baudrate = 115200
    s.timeout = 0.25
    s.dtr = False
    s.rts = False
    s.open()
    time.sleep(0.1)
    s.reset_input_buffer()
    return s

def wait_prompt(s, timeout=40.0):
    buf = b""
    end = time.time() + timeout
    last = time.time()
    while time.time() < end:
        chunk = s.read(8192)
        if chunk:
            buf += chunk
            last = time.time()
            if b"$ " in buf[-120:] or b"# " in buf[-120:]:
                time.sleep(0.1)
                buf += s.read(4096)
                return buf
        else:
            if time.time() - last > 1.0 and (b"$ " in buf[-80:] or b"# " in buf[-80:]):
                return buf
            time.sleep(0.03)
    return buf

def cmd(s, line, timeout=60.0):
    s.write(line.encode() + b"\r\n")
    return wait_prompt(s, timeout).decode("utf-8", "replace")

s = open_ser()
s.write(b"\r\n")
time.sleep(0.4)
pre = s.read(8000)
if b"login:" in pre:
    s.write(b"sima\r\n")
    time.sleep(0.4)
    s.read(3000)
    s.write(password.encode() + b"\r\n")
    print(wait_prompt(s, 12).decode("utf-8", "replace")[-300:])
elif b"Password:" in pre:
    s.write(password.encode() + b"\r\n")
    print(wait_prompt(s, 12).decode("utf-8", "replace")[-300:])

cmd(s, "rm -rf /tmp/ark-pab-v3-dtbo && mkdir -p /tmp/ark-pab-v3-dtbo")

def b64_upload(local_path, remote_path):
    data = open(local_path, "rb").read()
    b64 = base64.b64encode(data).decode("ascii")
    print(f"==> upload {local_path} ({len(data)} bytes)")
    cmd(s, f"rm -f {remote_path}.b64 {remote_path}")
    chunk = 400
    for i in range(0, len(b64), chunk):
        cmd(s, f"printf %s '{b64[i:i+chunk]}' >> {remote_path}.b64", timeout=20)
    out = cmd(s, f"base64 -d {remote_path}.b64 > {remote_path} && rm -f {remote_path}.b64 && wc -c {remote_path}", timeout=40)
    print(out[-200:])

b64_upload(dtso, "/tmp/ark-pab-v3-dtbo/ark-pab-v3.dtso")
if os.path.isfile(usb_init):
    b64_upload(usb_init, "/tmp/ark-pab-v3-dtbo/ark-jaj-usb-init.sh")
if os.path.isfile(usb_svc):
    b64_upload(usb_svc, "/tmp/ark-pab-v3-dtbo/ark-jaj-usb.service")

# One-line sudo install (multi-line paste breaks on serial with bracketed paste)
install = (
    f"echo {password} | sudo -S bash -c '"
    "set -e; R=/tmp/ark-pab-v3-dtbo; "
    "dtc -@ -I dts -O dtb -o $R/ark-pab-v3.dtbo $R/ark-pab-v3.dtso; "
    "install -m 0644 $R/ark-pab-v3.dtbo /boot/boot-0/ark-pab-v3.dtbo; "
    "install -m 0644 $R/ark-pab-v3.dtbo /boot/boot-1/ark-pab-v3.dtbo; "
    "mkdir -p /boot/boot-0/overlays /boot/boot-1/overlays; "
    "cp -f /boot/boot-0/ark-pab-v3.dtbo /boot/boot-0/overlays/; "
    "cp -f /boot/boot-1/ark-pab-v3.dtbo /boot/boot-1/overlays/; "
    "[ -f $R/ark-jaj-usb-init.sh ] && install -d /usr/local/sbin && "
    "install -m 0755 $R/ark-jaj-usb-init.sh /usr/local/sbin/ark-jaj-usb-init.sh || true; "
    "[ -f $R/ark-jaj-usb.service ] && install -m 0644 $R/ark-jaj-usb.service "
    "/etc/systemd/system/ark-jaj-usb.service && "
    "mkdir -p /etc/systemd/system/ark-jaj-usb.service.d && "
    "printf '%s\\n' '[Service]' 'Environment=ROLE_POLICY=prefer-host' "
    "> /etc/systemd/system/ark-jaj-usb.service.d/pab-v3.conf && "
    "systemctl daemon-reload && systemctl enable ark-jaj-usb.service || true; "
    "mkdir -p /tmp/boot; cp -a /boot/uboot.env /boot/uboot-redund.env /tmp/boot/; "
    "printf \"%s\\n\" \"/tmp/boot/uboot.env 0x0000 0x80000\" "
    "\"/tmp/boot/uboot-redund.env 0x0000 0x80000\" > /tmp/fw_env.config; "
    "if [ -f /boot/boot-0/modalix-som_16g.dtb ]; then "
    "fw_setenv -c /tmp/fw_env.config fdt_name modalix-som_16g.dtb; "
    "elif [ -f /boot/boot-0/modalix-som.dtb ]; then "
    "fw_setenv -c /tmp/fw_env.config fdt_name modalix-som.dtb; fi; "
    "fw_setenv -c /tmp/fw_env.config dtbos ark-pab-v3.dtbo; "
    "cp -a /tmp/boot/uboot.env /tmp/boot/uboot-redund.env /boot/; sync; "
    "fw_printenv -c /tmp/fw_env.config fdt_name dtbos; "
    "ls -la /boot/boot-0/ark-pab-v3.dtbo; echo INSTALL_OK'"
)
print("==> install")
out = cmd(s, install, timeout=90)
print(out[-2500:])
if "INSTALL_OK" not in out:
    raise SystemExit("install failed")

if reboot:
    print("==> rebooting")
    cmd(s, f"echo {password} | sudo -S reboot", timeout=10)
else:
    print("Installed. Reboot when ready (or re-run with --reboot).")
s.close()
PY
    exit 0
fi

# --- SSH path (when ethernet works) ---
ASKPASS=$(mktemp)
trap 'rm -f "$ASKPASS"' EXIT
cat > "$ASKPASS" <<EOF
#!/bin/sh
echo '$PASSWORD'
EOF
chmod 700 "$ASKPASS"
export DISPLAY= SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force

ssh_() { ssh "${SSH_OPTS[@]}" "$BOARD" "$@"; }
scp_() { scp "${SSH_OPTS[@]}" "$@"; }

echo "==> Target: $BOARD"
echo "==> Source: $DTSO"

REMOTE_DIR=/tmp/ark-pab-v3-dtbo
ssh_ "rm -rf $REMOTE_DIR && mkdir -p $REMOTE_DIR"
scp_ "$DTSO" "$BOARD:$REMOTE_DIR/ark-pab-v3.dtso"
[[ -f "$USB_INIT" ]] && scp_ "$USB_INIT" "$BOARD:$REMOTE_DIR/" || true
[[ -f "$USB_SVC" ]] && scp_ "$USB_SVC" "$BOARD:$REMOTE_DIR/" || true
[[ -f "$HDMI_UNBLANK" ]] && scp_ "$HDMI_UNBLANK" "$BOARD:$REMOTE_DIR/" || true
[[ -f "$HDMI_XORG" ]] && scp_ "$HDMI_XORG" "$BOARD:$REMOTE_DIR/" || true
[[ -f "$HDMI_LDM" ]] && scp_ "$HDMI_LDM" "$BOARD:$REMOTE_DIR/" || true
[[ -f "$HDMI_UDEV" ]] && scp_ "$HDMI_UDEV" "$BOARD:$REMOTE_DIR/" || true
[[ -f "$HDMI_INSTALL" ]] && scp_ "$HDMI_INSTALL" "$BOARD:$REMOTE_DIR/" || true

echo "==> Compiling + installing overlay on target"
ssh_ "echo '$PASSWORD' | sudo -S bash -c '
$(remote_install_body)
'"

if [ "$REBOOT" = "1" ]; then
    echo "==> Rebooting target"
    ssh_ "echo '$PASSWORD' | sudo -S reboot" || true
    echo "Wait for the board, then verify:"
    echo "  cat /proc/device-tree/model"
    echo "  # expect: ARK Jetson PAB V3 with SiMa Modalix SoM"
    echo "  ip -br a   # end0 should come up once SWITCH_RSTn is high"
else
    echo
    echo "Installed. Reboot when ready:"
    echo "  ssh $BOARD 'sudo reboot'"
    echo "  # or re-run with --reboot"
fi
