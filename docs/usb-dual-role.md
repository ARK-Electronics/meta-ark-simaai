# USB-C dual-role on JAJ + Modalix

## What works today

| Direction | Status |
|-----------|--------|
| USB-C as **host** (SuperSpeed stick) | Yes (TUSB73x0 xHCI + FUSB301 DRP) |
| USB-A as **host** USB2 | Yes (USB4715 hub) |
| USB-C as **device** to a PC | **No data gadget** (see below) |

## Why device mode cannot work on stock eLxr

Live kernel (`6.18.3-modalix`):

```
# CONFIG_USB_GADGET is not set
# CONFIG_USB_DWC3 is not set
# CONFIG_USB_DWC2 is not set
# CONFIG_USB_ROLE_SWITCH is not set
```

- `/sys/class/udc` is empty — **no USB device controller**
- Only USB controller in `iomem` / PCI: **TI TUSB73x0** (xHCI **host**)
- FUSB301 can be programmed to SNK for CC/VBUS, but nothing implements the
  USB peripheral data path to the PC

So dual-role **CC** can be improved in software; dual-role **device enumeration**
needs SiMa to ship a UDC + `CONFIG_USB_GADGET` (and role-switch wiring to USB0).

## Carrier schematic (JAJ Rev 2.0)

- USB-C: `USBSS0` + `USB0_D±` + FUSB301 + FUSB340 mux
- USB-A: `USBSS1`/`USBSS2` + hub `HUB_USB2`/`HUB_USB4` companions

## Software we ship

- DT: `fusb301@25` dual-role connector node in `ark-jaj.dtso`
- Runtime: `ark-jaj-usb-init.sh` / `ark-jaj-usb.service`
  - `ROLE_POLICY=auto` — if VBUS already present, program SNK; else DRP try-SRC
  - `ROLE_POLICY=prefer-device` — force SNK
  - `ROLE_POLICY=prefer-host` — force DRP try-SRC
  - Always keep SuperSpeed root hub out of autosuspend

```bash
# re-run after plugging PC cable
ROLE_POLICY=prefer-device sudo /usr/local/sbin/ark-jaj-usb-init.sh
# check CC role (SNK bit in TYPE register 0x12 = 0x10)
sudo i2cget -y 0 0x25 0x12
```

Even with TYPE=SNK, `lsusb` on the PC will not show a Modalix gadget until a
UDC exists.
