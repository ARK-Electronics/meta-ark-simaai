#!/bin/bash
# Wake the SM768 HDMI panel on JAJ and PAB V3 (same Micro HDMI path).
# eLxr LightDM enables DPMS (10 min) by default; with no keyboard/mouse the
# monitor stays Off even when the connector is already connected. Also run
# from LightDM display-setup-script and udev on DRM change so a cable
# plugged after boot lights up.
set -euo pipefail

echo 0 > /sys/class/graphics/fb0/blank 2>/dev/null || true

if [ ! -S /tmp/.X11-unix/X0 ]; then
	exit 0
fi

export DISPLAY=:0
for auth in /var/run/lightdm/root/:0 /var/lib/lightdm/.Xauthority; do
	if [ -r "$auth" ]; then
		export XAUTHORITY="$auth"
		break
	fi
done

xset s off 2>/dev/null || true
xset s noblank 2>/dev/null || true
xset dpms force on 2>/dev/null || true
xset -dpms 2>/dev/null || true
exit 0
