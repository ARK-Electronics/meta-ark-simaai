SUMMARY = "Device tree overlays for ARK Jetson carriers with Modalix SoM"
DESCRIPTION = "Out-of-tree DT overlays for ARK Just a Jetson, PAB, PAB V3, and CAN PAB."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

COMPATIBLE_MACHINE = "ark-jaj|ark-pab|ark-pab-v3|ark-can-pab"

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI = " \
    file://Makefile \
    file://ark-jaj.dtso \
    file://ark-jaj-uart1-carrier.dtso \
    file://ark-pab.dtso \
    file://ark-pab-v3.dtso \
    file://ark-can-pab.dtso \
"

inherit deploy

S = "${WORKDIR}"

DEPENDS += "dtc-native"

do_compile() {
    oe_runmake
}

do_install() {
    install -d ${D}/boot/overlays
    install -m 0644 ${B}/*.dtbo ${D}/boot/overlays/
}

do_deploy() {
    install -d ${DEPLOYDIR}/overlays
    install -m 0644 ${B}/*.dtbo ${DEPLOYDIR}/overlays/
}

addtask do_deploy after do_compile before do_build

FILES:${PN} += "/boot/overlays/*.dtbo"
