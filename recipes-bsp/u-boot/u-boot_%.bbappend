require recipes-core/images/ark-compatible-machine.inc

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Per-machine U-Boot GPIO defaults. Edit gpios-<machine>.cmd to add pads;
# they are prepended to boot.scr / netboot.scr and stored as preboot in uboot.env.
SRC_URI:append:ark-jaj = " file://gpios-ark-jaj.cmd"
SRC_URI:append:ark-pab-v3 = " file://gpios-ark-pab-v3.cmd"

# In-band SGMII on PAB V3 (KSZ8795 10/100): keep MAC SS at 1G GMII and
# program XPCS C37 speed from copper. JAJ is direct 1G; leave it unpatched.
SRC_URI:append:ark-pab-v3 = " \
    file://0001-xgmac-sgmii-keep-mac-at-1g.patch \
    file://0002-xgmac-sgmii-xpcs-c37-speed.patch \
"

# SiMa's do_deploy builds bootscripts from board/sima/${MACHINE}/.
# Until ARK has dedicated U-Boot board dirs, alias each ARK machine
# to the upstream Modalix board (ARK_UBOOT_BOARD, default "modalix").
do_deploy:prepend() {
    if [ -n "${ARK_UBOOT_BOARD}" ] && [ "${MACHINE}" != "${ARK_UBOOT_BOARD}" ]; then
        if [ -d "${S}/board/sima/${ARK_UBOOT_BOARD}" ]; then
            mkdir -p "${S}/board/sima"
            if [ ! -e "${S}/board/sima/${MACHINE}" ]; then
                ln -sfn "${ARK_UBOOT_BOARD}" "${S}/board/sima/${MACHINE}"
            fi
        fi
    fi

    gpio_cmd=""
    for _d in "${UNPACKDIR}" "${WORKDIR}"; do
        if [ -n "$_d" ] && [ -f "$_d/gpios-${MACHINE}.cmd" ]; then
            gpio_cmd="$_d/gpios-${MACHINE}.cmd"
            break
        fi
    done

    bootscr="${S}/board/sima/${MACHINE}/bootscripts"
    if [ -n "$gpio_cmd" ] && [ -d "$bootscr" ]; then
        for scr in mmcboot.cmd netboot.cmd; do
            [ -f "$bootscr/$scr" ] || continue
            if [ ! -f "$bootscr/$scr.orig" ]; then
                cp "$bootscr/$scr" "$bootscr/$scr.orig"
            fi
            {
                echo "# ARK carrier GPIO defaults (${MACHINE}) — see recipes-bsp/u-boot/files/gpios-${MACHINE}.cmd"
                cat "$gpio_cmd"
                echo
                cat "$bootscr/$scr.orig"
            } > "$bootscr/$scr"
        done
    fi

    envf="${B}/${UBOOT_INITIAL_ENV}"
    [ -f "$envf" ] || envf="${B}/uboot.txt"
    if [ -f "$envf" ]; then
        if [ -n "${ARK_DEFAULT_DTBO}" ]; then
            if grep -q '^dtbos=' "$envf"; then
                sed -i "s|^dtbos=.*|dtbos=${ARK_DEFAULT_DTBO}|" "$envf"
            else
                echo "dtbos=${ARK_DEFAULT_DTBO}" >> "$envf"
            fi
        fi
        if [ -n "$gpio_cmd" ]; then
            gpios=$(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$gpio_cmd" | tr '\n' ';' | sed 's/;*$//')
            if grep -q '^ark_gpios=' "$envf"; then
                # replace whole line; value has no spaces that confuse sed if we use |
                sed -i "s|^ark_gpios=.*|ark_gpios=${gpios}|" "$envf"
            else
                echo "ark_gpios=${gpios}" >> "$envf"
            fi
            if ! grep -q 'run ark_gpios' "$envf"; then
                if grep -q '^preboot=' "$envf"; then
                    sed -i 's|^preboot=|preboot=run ark_gpios; |' "$envf"
                else
                    echo "preboot=run ark_gpios" >> "$envf"
                fi
            fi
        fi
    fi
}
