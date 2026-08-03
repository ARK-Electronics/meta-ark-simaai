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

### `USB0_VBUS_DETn` (SODIMM 87) — needed a pull-up on Modalix

JAJ drives this net from the FUSB301's **open-drain `INT_N`** (U24 pin 10) and leaves
**R70 — the 47 kΩ pull-up to 1V8 — DNP** in the Production variant, because a Jetson SoM
presents that pin as an **input with an internal pull-up**, making the external one redundant.

Modalix did not. The SoM DTS hogs the pad as **`output-low`** under the name `usb_uart60`
(SIO6[0]), so the module drove the net low and could never read it; with the hog simply removed
and nothing pulling the net, an open-drain driver has no valid high either. `ark-jaj.dtbo` now
claims SIO6[0] as an **input with `bias-pull-up`**, matching what the carrier expects:

```dts
&{/sio@6/gpio@0x04061000/gpio@0/uart-hog} { status = "disabled"; };
&pins_gpio60_deafult { bias-pull-up; input-enable; };   /* SiMa spells it "deafult" */
&port6 { usb0-vbus-det-hog { gpio-hog; gpios = <0 0>; input; line-name = "usb0_vbus_det"; }; };
```

Disabling the SoM's hog is **not** sufficient on its own: the DesignWare GPIO keeps whatever
direction the previous boot stage left in `SWPORTA_DDR` and the driver never resets it — measured
still an output with no hog present. The `input` hog is what forces the direction.

Verified on hardware, reading `EXT_PORTA` (0x04061050) bit 0 while driving the FUSB301:

| FUSB301 state | SODIMM 87 |
|---|---|
| `INTERRUPT` (0x13) cleared → `INT_N` released | **1** (pull-up) |
| re-attach: `STATUS`=0x19, `TYPE`=0x10, `0x13`=0x01 latched | **0** (`INT_N` asserted) |
| `0x13` cleared again | **1** |

That tracking also **identifies SIO6[0] as SODIMM 87 / `GPIO00_VBUS_DET`**, which the SoM data
sheet does not document — Table 3-2 starts at GPIO01 = SIO6[1] and omits GPIO00.

**`INT_N` is an interrupt, not a VBUS level.** It latches on attach *or* detach and stays low
until someone reads register 0x13 — and nothing in Linux services it, so after boot it sits low
indefinitely regardless of what is plugged in. A low there does not mean "VBUS present", and any
diagnostic read of 0x13 changes the pin. Read VBUS from **`STATUS` (0x11) bit 3**, and the role
from **`TYPE` (0x12)** — bit 4 = SINK attached (we are the host), bit 3 = SOURCE attached (a PC
is feeding us). Note JAJ names the net active low (`..._DETn`) while the SoM pin name implies
active high; confirm polarity before making anything depend on it.

## Software we ship

- DT: `fusb301@25` dual-role connector node in `ark-jaj.dtso`
- Runtime: `ark-jaj-usb-init.sh` / `ark-jaj-usb.service`
  - `ROLE_POLICY=auto` — if VBUS already present, program SNK; else DRP try-SRC
    - **Known bug:** VBUS alone is the wrong discriminator. With a device attached to the
      USB-C port *the board is sourcing VBUS*, so `VBUSOK` is set and `auto` forces **SNK**,
      which drops the downstream device (observed: a thumb drive disappearing from `lsusb`,
      restored by `i2cset -y 0 0x25 0x02 0x20` = DRP_ACC). Decide from `TYPE` (0x12) instead:
      bit 4 SINK attached → we are the host, bit 3 SOURCE attached → SNK. The script already
      computes `is_snk`/`is_src` in its status helper but does not use them in the policy.
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
