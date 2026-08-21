# ARK Just a Jetson — U-Boot GPIO defaults
# Add carrier pads that must be set on every boot (baked into boot.scr + uboot.env).
# Do not touch SIO RSTCLR (base+0x210); a read/write there abort-resets U-Boot.
#
# SIO6 is already muxed GPIO by Modalix init_sio. Stock U-Boot hogs SIO6[0] as
# output-low (usb_uart60). JAJ wires that pad to FUSB301 INT_N (USB0_VBUS_DETn,
# SODIMM 87) which must be an input with pull-up.

echo ARK JAJ GPIOs: USB0_VBUS_DET input

# SIO6 PUP bit0, PDN bit0 clear
mw.l 0x04060108 0x01
mw.l 0x04060104 0x00
# OE bit0 off, IE all on
mw.l 0x04060118 0xfe
mw.l 0x0406011c 0xff
# DW GPIO: software control, all inputs (clears stock DDR bit0 output)
mw.l 0x04061008 0x00
mw.l 0x04061004 0x00
mw.l 0x04061000 0x00
