#!/usr/bin/env bash
# Host-side Modalix eMMC flash via sima-cli netboot.
# Prerequisites:
#   - Ethernet cable: host <-> JAJ carrier GbE (or same L2 network)
#   - Serial: /dev/ttyUSB0 @ 115200 (FTDI)
#   - Host can sudo (TFTP binds port 69)
#   - SiMa developer login for image download
#
# Usage:
#   ./scripts/flash_netboot.sh              # default: modalix elxr 2.1.1
#   FWTYPE=yocto VERSION=2.1.1 ./scripts/flash_netboot.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION="${VERSION:-2.1.1}"
FWTYPE="${FWTYPE:-elxr}"   # elxr | yocto
BOARDTYPE="${BOARDTYPE:-modalix}"
HOST_IP="${HOST_IP:-192.168.1.10}"
BOARD_IP="${BOARD_IP:-192.168.1.20}"
IFACE="${IFACE:-}"
SIMA_CLI="${SIMA_CLI:-$HOME/.sima-cli/.venv/bin/sima-cli}"

echo "==> Modalix netboot flash ($BOARDTYPE $FWTYPE $VERSION)"

if [ ! -x "$SIMA_CLI" ]; then
    echo "Installing sima-cli..."
    curl -fsSL https://docs.sima.ai/_static/tools/sima-cli-installer.sh | bash
    SIMA_CLI="$HOME/.sima-cli/.venv/bin/sima-cli"
fi

if [ ! -x "$SIMA_CLI" ]; then
    echo "ERROR: sima-cli not found at $SIMA_CLI" >&2
    exit 1
fi

echo "==> Checking serial"
if [ ! -e /dev/ttyUSB0 ]; then
    echo "ERROR: /dev/ttyUSB0 missing — plug USB-C debug" >&2
    exit 1
fi

# Optional: configure host NIC for direct cable netboot
if [ -n "$IFACE" ]; then
    echo "==> Configuring $IFACE -> $HOST_IP/24"
    sudo ip link set "$IFACE" up
    sudo ip addr flush dev "$IFACE" || true
    sudo ip addr add "$HOST_IP/24" dev "$IFACE"
fi

echo
echo "========================================================================"
echo "  MANUAL STEP — serial console (second terminal):"
echo "    picocom -b 115200 /dev/ttyUSB0"
echo "    # reboot board, stop at U-Boot: Hit any key to stop autoboot"
echo "    setenv ipaddr $BOARD_IP"
echo "    setenv serverip $HOST_IP"
echo "    setenv boot_targets net"
echo "    saveenv"
echo "    boot"
echo
echo "  After Linux nets in, return here and type: f"
echo "========================================================================"
echo
read -r -p "Press Enter to start sima-cli netboot server (needs sudo)..."

# Login may be interactive
"$SIMA_CLI" login || true

exec sudo "$SIMA_CLI" bootimg \
    --boardtype "$BOARDTYPE" \
    --fwtype "$FWTYPE" \
    -v "$VERSION" \
    --netboot
