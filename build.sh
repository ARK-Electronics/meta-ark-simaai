#!/usr/bin/env bash
# Build a SiMa/ARK Modalix image. Analogous to ark_jetson_kernel's build.sh.
#
# Usage:
#   ./build.sh                  # ark-jaj (default)
#   ./build.sh ark-jaj
#   ./build.sh ark-pab
#   ./build.sh ark-pab-v3
#   ./build.sh ark-can-pab
#   ./build.sh ark-jaj --upgrade   # also build SWU upgrade package
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACHINE="ark-jaj"
BUILD_UPGRADE=0
WS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        ark-jaj|ark-pab|ark-pab-v3|ark-can-pab|modalix)
            MACHINE="$1"
            shift ;;
        --upgrade)
            BUILD_UPGRADE=1
            shift ;;
        --workspace)
            WS="$2"
            shift 2 ;;
        -h|--help)
            sed -n '2,15p' "$0"
            exit 0 ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1 ;;
    esac
done

if [ -z "$WS" ]; then
    if [ -f "$SCRIPT_DIR/../ark-modalix-yocto/.ark-modalix-workspace" ]; then
        WS="$(cd "$SCRIPT_DIR/../ark-modalix-yocto" && pwd)"
    elif [ -f "$SCRIPT_DIR/../../ark-modalix-yocto/.ark-modalix-workspace" ]; then
        WS="$(cd "$SCRIPT_DIR/../../ark-modalix-yocto" && pwd)"
    else
        WS="$(cd "$SCRIPT_DIR/.." && pwd)/ark-modalix-yocto"
    fi
fi

if [ ! -d "$WS/poky" ] || [ ! -d "$WS/meta-simaai" ]; then
    echo "ERROR: Yocto workspace not found at $WS" >&2
    echo "       Run ./setup.sh first." >&2
    exit 1
fi

echo "==> Machine: $MACHINE"
echo "==> Workspace: $WS"

# GNU tar >= 1.35 uses openat2(), which pseudo cannot intercept; without this
# shim do_package fails in perform_packagecopy for every recipe.
# See scripts/hosttools/no_openat2.c
SHIM_DIR="$("$SCRIPT_DIR/scripts/hosttools/setup-hosttools-shim.sh" "$WS/hosttools-shim")"
export PATH="$SHIM_DIR:$PATH"
echo "==> hosttools shim: $SHIM_DIR (tar -> no_openat2 preload)"

set +u
# shellcheck disable=SC1091
source "$WS/poky/oe-init-build-env" "$WS/build" >/dev/null
set -u

# Ensure MACHINE is set for this invocation
export MACHINE
# Also write through for interactive follow-up shells
if grep -q '^MACHINE ' "$WS/build/conf/local.conf"; then
    sed -i "s/^MACHINE .*/MACHINE = \"$MACHINE\"/" "$WS/build/conf/local.conf"
else
    echo "MACHINE = \"$MACHINE\"" >> "$WS/build/conf/local.conf"
fi

# bitbake only populates tmp/hosttools when a link is missing, so an existing
# tar -> /usr/bin/tar symlink would bypass the shim. Drop it if it is stale.
STALE_TAR="${TMPDIR:-$WS/build/tmp}/hosttools/tar"
if [ -L "$STALE_TAR" ] && [ "$(readlink "$STALE_TAR")" != "$SHIM_DIR/tar" ]; then
    echo "==> refreshing stale hosttools tar symlink"
    rm -f "$STALE_TAR"
fi

echo "==> bitbake simaai-image-minimal (MACHINE=$MACHINE)"
bitbake simaai-image-minimal

if [ "$BUILD_UPGRADE" = "1" ]; then
    echo "==> bitbake simaai-image-minimal-upgrade"
    bitbake simaai-image-minimal-upgrade
fi

DEPLOY="$WS/build/tmp/deploy/images/$MACHINE"
echo
echo "Build complete. Artifacts:"
ls -lh "$DEPLOY"/*.{wic.gz,wic.bmap,Image,dtb,bin} 2>/dev/null || ls -lh "$DEPLOY" | head -40
echo
echo "Flash with:"
echo "  ./flash.sh $MACHINE --device /dev/sdX     # removable NVMe/USB (host-side)"
echo "  ./flash.sh $MACHINE --netboot             # sima-cli TFTP + eMMC (needs serial+eth)"
echo
echo "Deploy dir: $DEPLOY"
