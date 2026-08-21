FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# SiMa base-files copies 90-network.rules.${MACHINE}; provide ARK Modalix copies.
SRC_URI += "\
    file://90-network.rules.ark-jaj \
    file://90-network.rules.ark-pab \
    file://90-network.rules.ark-pab-v3 \
    file://90-network.rules.ark-can-pab \
"
