#!/usr/bin/env bash
# Build ark-pab.dtbo and install it on a live Modalix board (eLxr / Yocto).
# Sets U-Boot dtbos so the overlay is applied on every boot.
#
# Usage:
#   BOARD=sima@192.168.7.50 ./scripts/deploy-pab-dtbo.sh
#   PASSWORD=edgeai BOARD=sima@192.168.7.50 ./scripts/deploy-pab-dtbo.sh --reboot
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DTSO="$REPO_DIR/recipes-kernel/ark-carrier-dtbo/files/ark-pab.dtso"
# Shared JAJ-era host helpers (FUSB dual-role, SPI probe tools)
USB_INIT="$REPO_DIR/scripts/ark-jaj-usb-init.sh"
USB_SVC="$REPO_DIR/scripts/ark-jaj-usb.service"
SPI_TEST="$REPO_DIR/scripts/spi-jaj-test.sh"
SCH16T_C="$REPO_DIR/scripts/sch16t-spi-test.c"
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

REMOTE_DIR=/tmp/ark-pab-dtbo
ssh_ "rm -rf $REMOTE_DIR && mkdir -p $REMOTE_DIR"
scp_ "$DTSO" "$BOARD:$REMOTE_DIR/ark-pab.dtso"
[[ -f "$USB_INIT" ]] && scp_ "$USB_INIT" "$BOARD:$REMOTE_DIR/" || true
[[ -f "$USB_SVC" ]] && scp_ "$USB_SVC" "$BOARD:$REMOTE_DIR/" || true
[[ -f "$SPI_TEST" ]] && scp_ "$SPI_TEST" "$BOARD:$REMOTE_DIR/" || true
[[ -f "$SCH16T_C" ]] && scp_ "$SCH16T_C" "$BOARD:$REMOTE_DIR/" || true

echo "==> Compiling overlay on target"
ssh_ "dtc -@ -I dts -O dtb -o $REMOTE_DIR/ark-pab.dtbo $REMOTE_DIR/ark-pab.dtso && ls -la $REMOTE_DIR/ark-pab.dtbo"
if [[ -f "$SCH16T_C" ]]; then
    echo "==> Building sch16t-spi-test on target"
    ssh_ "gcc -O2 -Wall -o $REMOTE_DIR/sch16t-spi-test $REMOTE_DIR/sch16t-spi-test.c" || true
fi

echo "==> Installing DTBO into /boot (clear JAJ overlay env → ark-pab.dtbo)"
ssh_ "echo '$PASSWORD' | sudo -S bash -c '
set -e
install -m 0644 $REMOTE_DIR/ark-pab.dtbo /boot/boot-0/ark-pab.dtbo
install -m 0644 $REMOTE_DIR/ark-pab.dtbo /boot/boot-1/ark-pab.dtbo
mkdir -p /boot/boot-0/overlays /boot/boot-1/overlays 2>/dev/null || true
cp -f /boot/boot-0/ark-pab.dtbo /boot/boot-0/overlays/ 2>/dev/null || true
cp -f /boot/boot-1/ark-pab.dtbo /boot/boot-1/overlays/ 2>/dev/null || true
# Stop applying JAJ identity if still present as only overlay
install -d /usr/local/sbin
if [ -f $REMOTE_DIR/ark-jaj-usb-init.sh ]; then
  install -m 0755 $REMOTE_DIR/ark-jaj-usb-init.sh /usr/local/sbin/ark-jaj-usb-init.sh
fi
if [ -f $REMOTE_DIR/ark-jaj-usb.service ]; then
  install -m 0644 $REMOTE_DIR/ark-jaj-usb.service /etc/systemd/system/ark-jaj-usb.service
  systemctl daemon-reload
  systemctl enable ark-jaj-usb.service 2>/dev/null || true
  /usr/local/sbin/ark-jaj-usb-init.sh || true
fi
[ -f $REMOTE_DIR/spi-jaj-test.sh ] && install -m 0755 $REMOTE_DIR/spi-jaj-test.sh /usr/local/sbin/spi-jaj-test.sh || true
[ -f $REMOTE_DIR/sch16t-spi-test ] && install -m 0755 $REMOTE_DIR/sch16t-spi-test /usr/local/sbin/sch16t-spi-test || true
sync
ls -la /boot/boot-0/ark-pab.dtbo
'"

echo "==> Configuring U-Boot env (dtbos=ark-pab.dtbo, fdt_name=modalix-som_16g.dtb)"
ssh_ "echo '$PASSWORD' | sudo -S bash -c '
set -e
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
fw_setenv -c /tmp/fw_env.config dtbos ark-pab.dtbo
cp -a /tmp/boot/uboot.env /tmp/boot/uboot-redund.env /boot/
sync
echo \"--- env check ---\"
fw_printenv -c /tmp/fw_env.config fdt_name dtbos boot_path
'"

if [ "$REBOOT" = "1" ]; then
    echo "==> Rebooting target"
    ssh_ "echo '$PASSWORD' | sudo -S reboot" || true
    echo "Wait for the board, then verify:"
    echo "  cat /proc/device-tree/model"
    echo "  # expect: ARK Jetson PAB with SiMa Modalix SoM"
else
    echo
    echo "Installed. Reboot when ready:"
    echo "  ssh $BOARD 'sudo reboot'"
    echo "  # or re-run with --reboot"
fi
