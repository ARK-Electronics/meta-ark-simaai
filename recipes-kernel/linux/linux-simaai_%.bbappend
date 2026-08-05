require recipes-core/images/ark-compatible-machine.inc

# Kernel config fragments (merged into simaai_modalix_defconfig via linux-yocto)
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI:append = " file://ina238.cfg"

# Future: inject ARK board DT sources via FILESEXTRAPATHS + SRC_URI
# SRC_URI:append:ark-jaj = " file://ark-jaj.dts"
