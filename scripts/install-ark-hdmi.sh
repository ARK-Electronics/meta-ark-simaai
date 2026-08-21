#!/bin/bash
# Install HDMI unblank / no-DPMS files from a staging directory onto the SoM.
# Same SM768 Micro HDMI path on JAJ and PAB V3. Run as root.
set -euo pipefail
R="${1:-.}"
[ -f "$R/ark-hdmi-unblank.sh" ] || exit 0
install -d /usr/local/sbin /etc/X11/xorg.conf.d /etc/lightdm/lightdm.conf.d /etc/udev/rules.d
install -m 0755 "$R/ark-hdmi-unblank.sh" /usr/local/sbin/ark-hdmi-unblank.sh
install -m 0644 "$R/10-ark-no-blank.conf" /etc/X11/xorg.conf.d/10-ark-no-blank.conf
install -m 0644 "$R/10-ark-hdmi-lightdm.conf" /etc/lightdm/lightdm.conf.d/10-ark-hdmi.conf
install -m 0644 "$R/99-ark-hdmi.rules" /etc/udev/rules.d/99-ark-hdmi.rules
udevadm control --reload-rules 2>/dev/null || true
/usr/local/sbin/ark-hdmi-unblank.sh || true
