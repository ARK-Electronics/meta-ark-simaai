#!/usr/bin/env bash
# Clone Yocto / SiMa layers and create a build workspace for ARK Modalix carriers.
# Mirrors the one-shot setup flow of ark_jetson_kernel's setup.sh.
#
# Usage:
#   ./setup.sh                  # workspace defaults to ../ark-modalix-yocto
#   ./setup.sh /path/to/ws
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAYER_DIR="$SCRIPT_DIR"
WS="${1:-$(cd "$LAYER_DIR/.." && pwd)/ark-modalix-yocto}"

# Pin revisions from meta-simaai documentation/build-manual.rst (SDK ~2.1.1)
POKY_TAG="scarthgap-5.0.6"
META_PYTHON_AI_REV="698c48b2d490fa58643dcbe93a95f62165884712"
META_CLANG_REV="8c77b427408db01b8de4c04bd3d247c13c154f92"
META_CLANG_REVIVAL_REV="1855a8e8be9e600d48fa354670f8d968ed1b1d02"
META_OE_REV="dda0d53326017d6758ec6bdfdaf2f484c089d13f"
META_SWUPDATE_REV="4a65b1ed36c0b6ee4942d5f23c4984552b17cfe6"
META_ARM_REV="0f1e7bf92c89759f0ab74cfa5be4ee47b092ad46"

echo "==> Workspace: $WS"
mkdir -p "$WS"
cd "$WS"

clone_pin() {
    local url="$1" dir="$2" rev="$3" branch="${4:-}"
    if [ -d "$dir/.git" ]; then
        echo "    [skip] $dir (already present)"
        return 0
    fi
    echo "    [clone] $dir"
    if [ -n "$branch" ]; then
        git clone --branch "$branch" "$url" "$dir"
    else
        git clone "$url" "$dir"
    fi
    (
        cd "$dir"
        git fetch --tags --quiet || true
        git checkout --detach "$rev" 2>/dev/null || git checkout "$rev"
    )
}

echo "==> Host packages (Ubuntu)"
if command -v apt-get >/dev/null 2>&1; then
    pkgs=(chrpath diffstat g++ gawk make cmake git python3 \
          python3-pip python3-pexpect xz-utils debianutils \
          iputils-ping libegl1-mesa libsdl1.2-dev \
          xterm zstd liblz4-tool file wget curl bmap-tools \
          minicom picocom gfortran)
    missing=()
    for p in "${pkgs[@]}"; do
        dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        echo "    Need: ${missing[*]}"
        echo "    Run:  sudo apt-get install -y ${missing[*]}"
        if [ "${SETUP_INSTALL_DEPS:-0}" = "1" ]; then
            sudo apt-get update
            sudo apt-get install -y "${missing[@]}"
        else
            echo "    (set SETUP_INSTALL_DEPS=1 to auto-install, or install manually and re-run)"
        fi
    else
        echo "    All required packages present"
    fi
fi

echo "==> Cloning layers"
clone_pin "https://git.yoctoproject.org/poky" "poky" "$POKY_TAG" "scarthgap"
# poky tag checkout may need full history for the tag
if [ -d poky/.git ]; then
    (
        cd poky
        git fetch --tags
        git checkout "$POKY_TAG" 2>/dev/null || git checkout -b "work-$POKY_TAG" "$POKY_TAG"
    )
fi

clone_pin "https://github.com/zboszor/meta-python-ai.git" "meta-python-ai" "$META_PYTHON_AI_REV" "scarthgap"
clone_pin "https://github.com/kraj/meta-clang.git" "meta-clang" "$META_CLANG_REV" "scarthgap"
clone_pin "https://github.com/zboszor/meta-clang-revival.git" "meta-clang-revival" "$META_CLANG_REVIVAL_REV" "scarthgap"
clone_pin "https://github.com/openembedded/meta-openembedded.git" "meta-openembedded" "$META_OE_REV" "scarthgap"
clone_pin "https://github.com/sbabic/meta-swupdate.git" "meta-swupdate" "$META_SWUPDATE_REV" "scarthgap"
clone_pin "https://git.yoctoproject.org/git/meta-arm" "meta-arm" "$META_ARM_REV" "scarthgap"

if [ ! -d meta-simaai/.git ]; then
    echo "    [clone] meta-simaai"
    git clone https://github.com/SiMa-ai/meta-simaai.git meta-simaai
else
    echo "    [skip] meta-simaai (already present)"
fi

# Point workspace at this meta-ark-simaai checkout (symlink so edits live in-repo)
if [ ! -e meta-ark-simaai ]; then
    ln -sfn "$LAYER_DIR" meta-ark-simaai
    echo "    [link] meta-ark-simaai -> $LAYER_DIR"
elif [ -L meta-ark-simaai ]; then
    ln -sfn "$LAYER_DIR" meta-ark-simaai
    echo "    [link] meta-ark-simaai refreshed"
else
    echo "    [skip] meta-ark-simaai (directory already present)"
fi

echo "==> Initializing build environment"
export TEMPLATECONF="$WS/meta-simaai/conf/templates/custom"
# oe-init-build-env references optional vars (e.g. BBSERVER); allow unbound while sourcing
set +u
# shellcheck disable=SC1091
source "$WS/poky/oe-init-build-env" "$WS/build" >/dev/null
set -u

# Merge ARK layer + machine into conf (idempotent)
BBLAYERS_CONF="$WS/build/conf/bblayers.conf"
LOCAL_CONF="$WS/build/conf/local.conf"

if ! grep -q 'meta-ark-simaai' "$BBLAYERS_CONF"; then
    # Insert before the closing quote of BBLAYERS
    if grep -q 'meta-swupdate' "$BBLAYERS_CONF"; then
        sed -i 's|${TOPDIR}/../meta-swupdate \\|${TOPDIR}/../meta-swupdate \\\n  ${TOPDIR}/../meta-ark-simaai \\|' "$BBLAYERS_CONF"
    else
        echo "WARNING: could not auto-patch bblayers.conf — add meta-ark-simaai manually"
    fi
fi

# Prefer ark-jaj; drop internal SiMa package mirror that does not exist off-prem
if ! grep -q 'ARK Modalix carrier overrides' "$LOCAL_CONF" 2>/dev/null; then
    cat >> "$LOCAL_CONF" <<'EOF'

# --- ARK Modalix carrier overrides (added by meta-ark-simaai/setup.sh) ---
MACHINE = "ark-jaj"
LICENSE_FLAGS_ACCEPTED += "commercial"

# meta-simaai sample points at an internal mirror; use public sources
SOURCE_MIRROR_URL = ""
INHERIT:remove = "own-mirrors"

# Kernel recipe in meta-simaai is 6.18.x (sample preferred 6.1% is stale)
PREFERRED_VERSION_linux-simaai = "6.18%"

# Parallelism (override if needed)
BB_NUMBER_THREADS ?= "${@oe.utils.cpu_count()}"
PARALLEL_MAKE ?= "-j ${@oe.utils.cpu_count()}"
EOF
fi

# Marker for build.sh / flash.sh
cat > "$WS/.ark-modalix-workspace" <<EOF
LAYER_DIR=$LAYER_DIR
MACHINE_DEFAULT=ark-jaj
CREATED=$(date -Iseconds)
EOF

cat <<EOF

========================================================================
  ARK Modalix Yocto workspace ready
========================================================================

  Workspace : $WS
  Machine   : ark-jaj  (Just a Jetson + Modalix SoM)
  Build dir : $WS/build

Next steps (from the meta-ark-simaai repo):

  1. Serial console (FTDI on USB-C debug):
       sudo usermod -aG dialout \$USER && newgrp dialout
       picocom -b 115200 /dev/ttyUSB0
       # power-cycle the board; stop at U-Boot with a key if needed

  2. Build image:
       ./build.sh ark-jaj

  3. Flash (after build, board recoverable via netboot or removable NVMe):
       ./flash.sh --help

Docs: docs/bringup-jaj.md
========================================================================
EOF
