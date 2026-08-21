#!/usr/bin/env bash
# Build ark-jaj.dtbo and install it on a live Modalix board (eLxr / Yocto).
# Sets U-Boot dtbos so the overlay is applied on every boot.
#
# Usage:
#   BOARD=sima@192.168.7.50 ./scripts/deploy-jaj-dtbo.sh
#   PASSWORD=edgeai BOARD=sima@192.168.7.50 ./scripts/deploy-jaj-dtbo.sh --reboot
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DTSO="$REPO_DIR/recipes-kernel/ark-carrier-dtbo/files/ark-jaj.dtso"
UART1_PROBE="$REPO_DIR/scripts/uart1-tx-probe.sh"
SYS_POWER_PY="$REPO_DIR/scripts/ark-jaj-sys-power.py"
SYS_POWER_SVC="$REPO_DIR/scripts/ark-jaj-sys-power.service"
I2C_TEST="$REPO_DIR/scripts/i2c-jaj-test.sh"
SPI_TEST="$REPO_DIR/scripts/spi-jaj-test.sh"
SCH16T_C="$REPO_DIR/scripts/sch16t-spi-test.c"
ICM42688_C="$REPO_DIR/scripts/icm42688-spi-test.c"
BOARD="${BOARD:-sima@192.168.7.50}"
PASSWORD="${PASSWORD:-edgeai}"
REBOOT=0
SSH_OPTS=(-o PreferredAuthentications=password -o PubkeyAuthentication=no -o StrictHostKeyChecking=accept-new)

while [[ $# -gt 0 ]]; do
    case "$1" in
        --reboot) REBOOT=1; shift ;;
        --board) BOARD="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,12p' "$0"
            exit 0 ;;
        *) echo "Unknown: $1" >&2; exit 1 ;;
    esac
done

if [ ! -f "$DTSO" ]; then
    echo "ERROR: missing $DTSO" >&2
    exit 1
fi

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

# Stage sources on board and compile with target dtc (has correct version)
REMOTE_DIR=/tmp/ark-jaj-dtbo
ssh_ "rm -rf $REMOTE_DIR && mkdir -p $REMOTE_DIR"
scp_ "$DTSO" "$BOARD:$REMOTE_DIR/ark-jaj.dtso"
[[ -f "$UART1_PROBE" ]] && scp_ "$UART1_PROBE" "$BOARD:$REMOTE_DIR/" || true
scp_ "$SYS_POWER_PY" "$SYS_POWER_SVC" "$BOARD:$REMOTE_DIR/"
[[ -f "$I2C_TEST" ]] && scp_ "$I2C_TEST" "$BOARD:$REMOTE_DIR/" || true
[[ -f "$SPI_TEST" ]] && scp_ "$SPI_TEST" "$BOARD:$REMOTE_DIR/" || true
[[ -f "$SCH16T_C" ]] && scp_ "$SCH16T_C" "$BOARD:$REMOTE_DIR/" || true
[[ -f "$ICM42688_C" ]] && scp_ "$ICM42688_C" "$BOARD:$REMOTE_DIR/" || true

# USB init (FUSB301 dual-role + SuperSpeed PM) — works without full kernel TCPM
USB_INIT="$REPO_DIR/scripts/ark-jaj-usb-init.sh"
USB_SVC="$REPO_DIR/scripts/ark-jaj-usb.service"
HDMI_UNBLANK="$REPO_DIR/scripts/ark-hdmi-unblank.sh"
HDMI_XORG="$REPO_DIR/scripts/10-ark-no-blank.conf"
HDMI_LDM="$REPO_DIR/scripts/10-ark-hdmi-lightdm.conf"
HDMI_UDEV="$REPO_DIR/scripts/99-ark-hdmi.rules"
HDMI_INSTALL="$REPO_DIR/scripts/install-ark-hdmi.sh"
scp_ "$USB_INIT" "$USB_SVC" "$BOARD:$REMOTE_DIR/"
[[ -f "$HDMI_UNBLANK" ]] && scp_ "$HDMI_UNBLANK" "$BOARD:$REMOTE_DIR/" || true
[[ -f "$HDMI_XORG" ]] && scp_ "$HDMI_XORG" "$BOARD:$REMOTE_DIR/" || true
[[ -f "$HDMI_LDM" ]] && scp_ "$HDMI_LDM" "$BOARD:$REMOTE_DIR/" || true
[[ -f "$HDMI_UDEV" ]] && scp_ "$HDMI_UDEV" "$BOARD:$REMOTE_DIR/" || true
[[ -f "$HDMI_INSTALL" ]] && scp_ "$HDMI_INSTALL" "$BOARD:$REMOTE_DIR/" || true

echo "==> Compiling overlay on target"
ssh_ "dtc -@ -I dts -O dtb -o $REMOTE_DIR/ark-jaj.dtbo $REMOTE_DIR/ark-jaj.dtso && ls -la $REMOTE_DIR/ark-jaj.dtbo"
if [[ -f "$SCH16T_C" ]]; then
    echo "==> Building sch16t-spi-test on target"
    ssh_ "gcc -O2 -Wall -o $REMOTE_DIR/sch16t-spi-test $REMOTE_DIR/sch16t-spi-test.c"
fi
if [[ -f "$ICM42688_C" ]]; then
    echo "==> Building icm42688-spi-test on target"
    ssh_ "gcc -O2 -Wall -o $REMOTE_DIR/icm42688-spi-test $REMOTE_DIR/icm42688-spi-test.c"
fi

echo "==> Installing DTBO + USB init into /boot and /usr/local"
ssh_ "echo '$PASSWORD' | sudo -S bash -c '
set -e
install -m 0644 $REMOTE_DIR/ark-jaj.dtbo /boot/boot-0/ark-jaj.dtbo
install -m 0644 $REMOTE_DIR/ark-jaj.dtbo /boot/boot-1/ark-jaj.dtbo
mkdir -p /boot/boot-0/overlays /boot/boot-1/overlays 2>/dev/null || true
cp -f /boot/boot-0/ark-jaj.dtbo /boot/boot-0/overlays/ 2>/dev/null || true
cp -f /boot/boot-1/ark-jaj.dtbo /boot/boot-1/overlays/ 2>/dev/null || true
install -d /usr/local/sbin
install -m 0755 $REMOTE_DIR/ark-jaj-usb-init.sh /usr/local/sbin/ark-jaj-usb-init.sh
[ -f $REMOTE_DIR/uart1-tx-probe.sh ] && install -m 0755 $REMOTE_DIR/uart1-tx-probe.sh /usr/local/sbin/uart1-tx-probe.sh || true
[ -f $REMOTE_DIR/i2c-jaj-test.sh ] && install -m 0755 $REMOTE_DIR/i2c-jaj-test.sh /usr/local/sbin/i2c-jaj-test.sh || true
[ -f $REMOTE_DIR/spi-jaj-test.sh ] && install -m 0755 $REMOTE_DIR/spi-jaj-test.sh /usr/local/sbin/spi-jaj-test.sh || true
[ -f $REMOTE_DIR/sch16t-spi-test ] && install -m 0755 $REMOTE_DIR/sch16t-spi-test /usr/local/sbin/sch16t-spi-test || true
[ -f $REMOTE_DIR/icm42688-spi-test ] && install -m 0755 $REMOTE_DIR/icm42688-spi-test /usr/local/sbin/icm42688-spi-test || true
install -m 0755 $REMOTE_DIR/ark-jaj-sys-power.py /usr/local/sbin/ark-jaj-sys-power.py
install -m 0644 $REMOTE_DIR/ark-jaj-usb.service /etc/systemd/system/ark-jaj-usb.service
install -m 0644 $REMOTE_DIR/ark-jaj-sys-power.service /etc/systemd/system/ark-jaj-sys-power.service
# Prefer i2c-tools for FUSB programming
command -v i2cget >/dev/null || apt-get install -y i2c-tools 2>/dev/null || true
systemctl daemon-reload
systemctl enable ark-jaj-usb.service
systemctl enable ark-jaj-sys-power.service
# Apply immediately (pre-reboot) so USB-C dual-role is live now
/usr/local/sbin/ark-jaj-usb-init.sh || true
# Same SM768 HDMI as PAB V3: do not let LightDM DPMS sleep the panel
[ -f $REMOTE_DIR/install-ark-hdmi.sh ] && bash $REMOTE_DIR/install-ark-hdmi.sh $REMOTE_DIR || true
# Start power publisher now (no reboot required for userspace path)
systemctl restart ark-jaj-sys-power.service || /usr/local/sbin/ark-jaj-sys-power.py once || true
sync
ls -la /boot/boot-0/ark-jaj.dtbo /usr/local/sbin/ark-jaj-usb-init.sh /usr/local/sbin/ark-jaj-sys-power.py
'"

echo "==> Configuring U-Boot env (dtbos=ark-jaj.dtbo)"
ssh_ "echo '$PASSWORD' | sudo -S bash -c '
set -e
mkdir -p /tmp/boot
cp -a /boot/uboot.env /boot/uboot-redund.env /tmp/boot/
# eLxr ships a broken fw_env.config (wrong size + /tmp path without mount)
cat > /tmp/fw_env.config << EOF
/tmp/boot/uboot.env 0x0000 0x80000
/tmp/boot/uboot-redund.env 0x0000 0x80000
EOF
# Prefer modalix-som_16g if fdt_name empty (matches running model)
fdt=\$(fw_printenv -c /tmp/fw_env.config fdt_name 2>/dev/null | cut -d= -f2- || true)
if [ -z \"\$fdt\" ]; then
  if [ -f /boot/boot-0/modalix-som_16g.dtb ]; then
    fw_setenv -c /tmp/fw_env.config fdt_name modalix-som_16g.dtb
  elif [ -f /boot/boot-0/modalix-som.dtb ]; then
    fw_setenv -c /tmp/fw_env.config fdt_name modalix-som.dtb
  fi
fi
fw_setenv -c /tmp/fw_env.config dtbos ark-jaj.dtbo
# Write back to the real boot partition files
cp -a /tmp/boot/uboot.env /tmp/boot/uboot-redund.env /boot/
sync
echo \"--- env check ---\"
fw_printenv -c /tmp/fw_env.config fdt_name dtbos boot_path
'"

if [ "$REBOOT" = "1" ]; then
    echo "==> Rebooting target"
    ssh_ "echo '$PASSWORD' | sudo -S reboot" || true
    echo "Wait for the board to come back, then verify:"
    echo "  ssh $BOARD 'cat /proc/device-tree/model; cat /proc/device-tree/compatible'"
else
    echo
    echo "Installed. Reboot when ready:"
    echo "  ssh $BOARD 'sudo reboot'"
    echo "  # or re-run with --reboot"
fi
