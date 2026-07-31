require recipes-core/images/ark-compatible-machine.inc

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
}
