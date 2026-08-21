# ARK Jetson PAB V3 — U-Boot GPIO defaults
# Add carrier pads that must be set on every boot (baked into boot.scr + uboot.env).
#
# SIO7 is NOT inited by stock Modalix U-Boot (gpio70 is Linux-only).
# Pin 211 = GPIO09_AUD_MCLK = SIO7[1] = Jetson GPIO09 = KSZ SWITCH_RSTn.
# Do not *read* SIO RSTCLR (0x04070210); a read abort-resets U-Boot.
# A write of 0x3ff deasserts all 10 function resets. Drive strength 7 is
# required or the pad does not actually switch.
#
# These GPIOs unreset the KSZ before U-Boot TFTP / Linux. The MAC must
# stay 1G GMII for in-band SGMII (see 0001-xgmac-sgmii-keep-mac-at-1g.patch);
# programming SS=100M_MII when copper is 100M sends no frames.
#
#   SODIMM  Net                         SIO      Dir/val
#   87      USB0_VBUS_DETn (FUSB INT)   SIO6[0]  in  + pull-up
#   206     VBUS_SENSE_BOOTLOADER       SIO6[7]  out hi   (FMU USB)
#   211     SWITCH_RSTn (KSZ8795 RST_N) SIO7[1]  out hi
#   216     SW_PMEn     (KSZ PME_N)     SIO7[3]  out hi
#   228     FMU_RST_REQ                 SIO7[5]  out lo
#
# Do not drive CAM0/CAM1 PWDN (SIO5[6]/[7]) here: with the KSZ rails they
# brown out this SoM on 5 V PAB power.

echo ARK PAB-V3 GPIOs: KSZ RST_N high, VBUS_SENSE high, FMU_RST_REQ low

# --- SIO6: VBUS_DET input+pull-up, VBUS_SENSE output-high ---
mw.l 0x04060108 0x01
mw.l 0x04060104 0x00
mw.l 0x04060118 0xfe
mw.l 0x0406011c 0xff
mw.l 0x04061008 0x00
mw.l 0x04061004 0x80
mw.l 0x04061000 0x80

# --- SIO7: take the block out of reset, clock it, mux GPIO, then KSZ + FMU ---
mw.l 0x04070210 0x3ff
mw.l 0x04070300 0x1
mw.l 0x04070300 0x80000001
mw.l 0x04070110 0x77777777
mw.l 0x04070118 0xff
mw.l 0x0407011c 0xff
mw.l 0x04070204 0x0101
mw.l 0x04070208 0x02020202
mw.l 0x04071008 0x00
mw.l 0x04071004 0x2a
mw.l 0x04071000 0x0a

# KSZ copper is 10/100 — stop advertising 1000BASE-T
mii write 0 4 0x0181
mii write 0 9 0x0000
mii write 0 0 0x3300
