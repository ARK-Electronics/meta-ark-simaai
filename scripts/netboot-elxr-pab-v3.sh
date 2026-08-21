#!/usr/bin/env bash
# Host-side helper: add netboot IP and launch sima-cli eLxr netboot for Modalix.
# Run with: sudo ./scripts/netboot-elxr-pab-v3.sh
#
# Note: plain `sudo` drops ~/.local/bin from PATH and sets HOME=/root, which
# breaks sima-cli. This script restores the invoking user's install.
set -euo pipefail
# Direct USB-Ethernet to the carrier RJ45. Do NOT put 192.168.1.10 on
# the office NIC (enp5s0 / wlp4s0) — that poisons ARP.
IFACE="${IFACE:-enx9c69d38062de}"
HOST_IP="${HOST_IP:-192.168.1.10}"
FWVER="${FWVER:-2.1.2}"

# Prefer the user who invoked sudo (sima-cli lives under their home)
if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
    REAL_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
else
    REAL_HOME="${HOME}"
fi
export HOME="$REAL_HOME"
export PATH="${REAL_HOME}/.local/bin:${PATH}"
export PYTHONPATH="${REAL_HOME}/.sima-cli/lib${PYTHONPATH:+:$PYTHONPATH}"

echo "==> Adding $HOST_IP/24 on $IFACE (keeping existing addresses)"
ip addr show dev "$IFACE" | grep -q "inet $HOST_IP/" \
  || ip addr add "$HOST_IP/24" dev "$IFACE"

echo "==> Current addresses on $IFACE:"
ip -br addr show dev "$IFACE"

SIMA_CLI="${SIMA_CLI:-}"
if [ -z "$SIMA_CLI" ]; then
    if [ -x "${REAL_HOME}/.local/bin/sima-cli" ]; then
        SIMA_CLI="${REAL_HOME}/.local/bin/sima-cli"
    elif [ -x "${REAL_HOME}/.sima-cli/bin/sima-cli" ]; then
        SIMA_CLI="${REAL_HOME}/.sima-cli/bin/sima-cli"
    else
        SIMA_CLI="$(command -v sima-cli || true)"
    fi
fi
if [ -z "$SIMA_CLI" ] || [ ! -x "$SIMA_CLI" ]; then
    echo "sima-cli not found (looked in ${REAL_HOME}/.local/bin and PATH)" >&2
    exit 1
fi
echo "==> Using sima-cli: $SIMA_CLI (HOME=$HOME)"

cat <<MSG

========================================================================
  sima-cli netboot (Modalix eLxr $FWVER)
========================================================================
Just a Jetson (direct GbE): U-Boot TFTP works. At the SoM USB-C
console (FT230X, 115200, DTR/RTS off), U-Boot prompt sima$:

  setenv boot_targets net
  setenv ipaddr 192.168.1.20
  setenv serverip 192.168.1.10
  saveenv
  boot

PAB V3 (KSZ8795 10/100): stock U-Boot sets MAC SS=100M_MII at 100M
copper so TFTP sends no frames. One-time (close any serial console first):
  ./scripts/pab-v3-firstboot.sh
that unresets the KSZ over USB-C, brings Linux Ethernet at 100M, and
installs ark-pab-v3.dtbo. Yocto ark-pab-v3 U-Boot (SGMII 1G-MAC + XPCS
C37 patches + preboot=run ark_gpios) is what makes U-Boot TFTP match JAJ.

At the host netboot> prompt (only c / f / q — never U-Boot commands):
  c          # list clients
  f          # flash eMMC (wait until ramdisk SSH is up — U-Boot ping is not enough)
Then power-cycle. Stock eLxr U-Boot overwrites the SGMII patches; run
pab-v3-firstboot.sh again after a fresh flash.
========================================================================

MSG

exec "$SIMA_CLI" bootimg --boardtype modalix --fwtype elxr -v "$FWVER" --netboot
