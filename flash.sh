#!/usr/bin/env bash
# Flash a built (or pre-downloaded) Modalix image for ARK carriers.
# Analogous to ark_jetson_kernel's flash.sh — but Modalix uses WIC images,
# not NVIDIA L4T recovery mode.
#
# Usage:
#   ./flash.sh ark-jaj --device /dev/sdX          # write WIC to block device
#   ./flash.sh ark-jaj --device /dev/nvme1n1
#   ./flash.sh ark-jaj --netboot                  # guide + invoke sima-cli netboot
#   ./flash.sh ark-jaj --image /path/to.wic.gz
#
# Notes:
#   - Modalix SoM boots from on-module eMMC by default (16 GB).
#   - The M.2 SSD on the carrier is typically data / optional root.
#   - Host-side --device is for: USB stick, externally attached NVMe, or
#     the carrier SSD if you remove it and plug into the host.
#   - For on-board eMMC recovery use --netboot (Ethernet + serial).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACHINE="ark-jaj"
DEVICE=""
IMAGE=""
NETBOOT=0
DRY_RUN=0
WS=""

usage() {
    sed -n '2,20p' "$0"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        ark-jaj|ark-pab|ark-pab-v3|ark-can-pab|modalix)
            MACHINE="$1"
            shift ;;
        --device)
            DEVICE="$2"
            shift 2 ;;
        --image)
            IMAGE="$2"
            shift 2 ;;
        --netboot)
            NETBOOT=1
            shift ;;
        --dry-run)
            DRY_RUN=1
            shift ;;
        --workspace)
            WS="$2"
            shift 2 ;;
        -h|--help)
            usage
            exit 0 ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            exit 1 ;;
    esac
done

if [ -z "$WS" ]; then
    if [ -f "$SCRIPT_DIR/../ark-modalix-yocto/.ark-modalix-workspace" ]; then
        WS="$(cd "$SCRIPT_DIR/../ark-modalix-yocto" && pwd)"
    else
        WS="$(cd "$SCRIPT_DIR/.." && pwd)/ark-modalix-yocto"
    fi
fi

DEPLOY="$WS/build/tmp/deploy/images/$MACHINE"

if [ "$NETBOOT" = "1" ]; then
    cat <<'EOF'
========================================================================
  Netboot + eMMC flash (SiMa recovery path)
========================================================================

Hardware:
  1. Serial:  USB-C debug (FTDI) -> host  =>  /dev/ttyUSB0 @ 115200
  2. Ethernet: carrier GbE <-> host NIC (direct cable is fine)
  3. Host NIC static IP: 192.168.1.10/24
  4. Board default U-Boot: ipaddr=192.168.1.20  serverip=192.168.1.10

Host packages / sima-cli:
  curl https://docs.sima.ai/_static/tools/sima-cli-installer.sh | bash
  sima-cli login          # SiMa developer portal account required

Terminal A — serial:
  picocom -b 115200 /dev/ttyUSB0
  # power-cycle board, hit a key at "Hit any key to stop autoboot"

Terminal B — TFTP / flash server (Yocto image if you built one is custom;
use sima-cli for official Modalix images, or serve your own TFTP later):
  sudo ~/.sima-cli/.venv/bin/sima-cli bootimg \
      --boardtype modalix --fwtype yocto -v 2.1.1 --netboot

U-Boot on the board:
  setenv boot_targets net
  saveenv
  boot

After Linux nets in, at the host netboot> prompt:
  c          # list clients
  f          # flash eMMC of 192.168.1.20
  # or: f <ip>

Then power-cycle. Apply ARK overlay once at U-Boot if needed:
  setenv dtbos ark-jaj.dtbo
  saveenv
  boot

See docs/bringup-jaj.md for details.
========================================================================
EOF
    if command -v sima-cli >/dev/null 2>&1 || [ -x "$HOME/.sima-cli/.venv/bin/sima-cli" ]; then
        SIMA_CLI="${SIMA_CLI:-$HOME/.sima-cli/.venv/bin/sima-cli}"
        [ -x "$SIMA_CLI" ] || SIMA_CLI="$(command -v sima-cli)"
        echo
        read -r -p "Start sima-cli netboot now for modalix yocto 2.1.1? [y/N] " ans
        if [[ "${ans,,}" == "y" ]]; then
            exec sudo "$SIMA_CLI" bootimg --boardtype modalix --fwtype yocto -v 2.1.1 --netboot
        fi
    else
        echo "(sima-cli not installed yet — follow the steps above.)"
    fi
    exit 0
fi

if [ -z "$DEVICE" ]; then
    echo "ERROR: pass --device /dev/XXX or use --netboot" >&2
    usage
    exit 1
fi

if [ ! -b "$DEVICE" ]; then
    echo "ERROR: $DEVICE is not a block device" >&2
    exit 1
fi

# Refuse to wipe the host root disk
ROOT_SRC="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
if [ -n "$ROOT_SRC" ]; then
    ROOT_DISK="$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null || true)"
    DEV_BASE="$(basename "$DEVICE")"
    if [ "$DEV_BASE" = "$ROOT_DISK" ] || [[ "$ROOT_SRC" == "$DEVICE"* ]]; then
        echo "ERROR: refusing to write to host root disk ($DEVICE)" >&2
        exit 1
    fi
fi

if [ -z "$IMAGE" ]; then
    if [ -f "$DEPLOY/simaai-image-minimal-$MACHINE.wic.gz" ]; then
        IMAGE="$DEPLOY/simaai-image-minimal-$MACHINE.wic.gz"
    elif [ -f "$DEPLOY/simaai-image-minimal-$MACHINE.wic" ]; then
        IMAGE="$DEPLOY/simaai-image-minimal-$MACHINE.wic"
    else
        echo "ERROR: no WIC image under $DEPLOY" >&2
        echo "       Run ./build.sh $MACHINE first, or pass --image PATH" >&2
        exit 1
    fi
fi

BMAP="${IMAGE%.gz}.bmap"
[ -f "$BMAP" ] || BMAP="${IMAGE}.bmap"
[ -f "$BMAP" ] || BMAP=""

echo "Image : $IMAGE"
echo "Device: $DEVICE"
lsblk "$DEVICE"
echo
read -r -p "This will ERASE $DEVICE. Type YES to continue: " conf
if [ "$conf" != "YES" ]; then
    echo "Aborted."
    exit 1
fi

if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] would flash $IMAGE -> $DEVICE"
    exit 0
fi

if command -v bmaptool >/dev/null 2>&1 && [ -n "$BMAP" ] && [ -f "$BMAP" ]; then
    echo "==> bmaptool copy $IMAGE -> $DEVICE"
    sudo bmaptool copy --bmap "$BMAP" "$IMAGE" "$DEVICE"
else
    echo "==> dd (no bmaptool / bmap); this is slower"
    if [[ "$IMAGE" == *.gz ]]; then
        gzip -dc "$IMAGE" | sudo dd of="$DEVICE" bs=4M status=progress conv=fsync
    else
        sudo dd if="$IMAGE" of="$DEVICE" bs=4M status=progress conv=fsync
    fi
fi

sync
echo "Done. Reinstall media in the carrier and power on."
echo "Serial: picocom -b 115200 /dev/ttyUSB0"
