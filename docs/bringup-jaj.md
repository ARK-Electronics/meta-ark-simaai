# Bring-up: Just a Jetson + SiMa Modalix SoM

This guide is the Modalix counterpart of
[ark_jetson_kernel](https://github.com/ARK-Electronics/ark_jetson_kernel)
(`setup.sh` → `build.sh` → `flash.sh`), adapted for Yocto / SiMa BSP.

| Jetson (ark_jetson_kernel) | Modalix (this layer) |
|----------------------------|----------------------|
| JetPack / L4T R36 | SiMa Yocto (scarthgap) + `meta-simaai` |
| `./setup.sh` | `./setup.sh` (clones poky + SiMa layers) |
| `./build.sh JAJ` | `./build.sh ark-jaj` |
| USB recovery + `./flash.sh JAJ` | WIC to media **or** `sima-cli` netboot → eMMC |
| `ssh jetson@jetson.local` | serial / SSH (`sima` / `edgeai` on stock images) |

## Hardware checklist

- [ ] Modalix SoM seated on **Just a Jetson** carrier  
- [ ] M.2 NVMe SSD installed (optional for first boot; eMMC is the default boot device)  
- [ ] **12 V** power connected to the carrier  
- [ ] **USB-C debug** (FTDI) → host PC → typically `/dev/ttyUSB0`  
- [ ] Ethernet (for netboot recovery / SSH) carrier ↔ host or LAN  

### What you should see on the host

```bash
lsusb | grep -i ftdi
# FTDI FT230X … Bridge
ls -l /dev/serial/by-id/
# usb-FTDI_FT230X_… -> ttyUSB0
```

There is **no** NVIDIA-style USB recovery gadget. Modalix is not flashable via
`flash.sh`-over-USB like Orin. Use serial + (optional) Ethernet.

## 0. Host serial access

```bash
sudo usermod -aG dialout $USER
# log out/in or:
newgrp dialout

# 115200 8N1
picocom -b 115200 /dev/ttyUSB0
# exit: Ctrl-A Ctrl-X
```

Power-cycle the board while watching the console.

| Observation | Meaning / next step |
|-------------|---------------------|
| U-Boot banner, `Hit any key to stop autoboot` | Bootloader OK — can netboot or boot existing eMMC |
| Linux login (`modalix` / `sima` prompt) | Stock image on eMMC — login and develop |
| Silence | Check 12 V power, SoM seating, correct USB port |

Default credentials on SiMa images: **`sima` / `edgeai`** (and often root via debug-tweaks on Yocto builds).

## 1. Setup build workspace (once)

From this repo (needs ~80+ GB free disk for a full Yocto build):

```bash
# optional: auto-apt install deps
SETUP_INSTALL_DEPS=1 ./setup.sh

# or:
./setup.sh /path/to/ark-modalix-yocto
```

This clones poky scarthgap, `meta-simaai`, OE layers, and links `meta-ark-simaai`.

## 2. Build

```bash
./build.sh ark-jaj
# optional SWU package:
./build.sh ark-jaj --upgrade
```

Artifacts land in:

```text
../ark-modalix-yocto/build/tmp/deploy/images/ark-jaj/
  simaai-image-minimal-ark-jaj.wic.gz
  simaai-image-minimal-ark-jaj.wic.bmap
  Image, *.dtb, u-boot.bin, overlays/ark-jaj.dtbo, …
```

Machine config uses stock `modalix-som.dtb` plus the placeholder
`ark-jaj.dtbo` overlay until a full board DTB exists.

## 3. Flash

### A. First recovery — netboot + eMMC (recommended)

Same idea as factory bring-up in SiMa’s docs. Needs serial + Ethernet.

```bash
./flash.sh ark-jaj --netboot
```

Summary:

1. Host Ethernet static **192.168.1.10/24** (direct to carrier GbE is fine).  
2. `sima-cli login` (SiMa developer account).  
3. Host: `sudo ~/.sima-cli/.venv/bin/sima-cli bootimg --boardtype modalix --fwtype yocto -v 2.1.1 --netboot`  
4. U-Boot: `setenv boot_targets net; saveenv; boot`  
5. Host netboot prompt: `f` to flash eMMC.  
6. Power-cycle.

### B. Host-side WIC write (removable media / external SSD)

If you remove the M.2 SSD (or use a USB drive) and attach it to the host:

```bash
lsblk   # identify the disk carefully
./flash.sh ark-jaj --device /dev/sdX
```

U-Boot must be told to boot that device if it is not the default eMMC path.

### C. On-target update (already booted)

Once Linux is running, SiMa’s `swupdate` / `sima-cli` on-device paths apply
(`simaai-image-minimal-upgrade` SWU package).

## 4. After first boot — ARK JAJ device tree

`ark-jaj.dtbo` sets board identity and enables dual CSI + IMX219 (same default
camera stack as `ark_jetson_kernel` JAJ). Source:

`recipes-kernel/ark-carrier-dtbo/files/ark-jaj.dtso`

### Deploy to a live board (eLxr already on eMMC)

```bash
BOARD=sima@192.168.7.50 ./scripts/deploy-jaj-dtbo.sh --reboot
```

This compiles the overlay on-target, installs it to `/boot/boot-{0,1}/`, and
sets U-Boot `fdt_name=modalix-som_16g.dtb` and `dtbos=ark-jaj.dtbo`.

### Manual U-Boot

```text
setenv fdt_name modalix-som_16g.dtb
setenv dtbos ark-jaj.dtbo
saveenv
boot
```

## 5. Verify

```bash
cat /proc/device-tree/model
# ARK Just a Jetson with SiMa Modalix SoM

tr '\0' ' ' < /proc/device-tree/compatible; echo
# ark,just-a-jetson simaai,modalix-som simaai,modalix

# CSI0/1 enabled; dual IMX219 nodes (I2C probe needs cameras attached)
dmesg | grep -i imx219
ip -br addr; lsusb; ls /sys/class/drm/; lsblk
```

Without cameras, `imx219` logs I2C NACK (`-121`) — expected until modules are plugged in.

## Architecture notes

- **SoM eMMC** (`/dev/mmcblk0`): default boot — see `wic/simaai-modalix-image.wks` in `meta-simaai`.
- **Carrier NVMe (M.2 Key M)**: optional storage on **PCIE0 x4** — **verified working** on JAJ + Modalix.
- **DT**: base `modalix-som_16g.dtb` + `ark-jaj.dtbo` overlay.
- **JAJ status**: overlay deployed and verified on hardware (identity + dual CSI cameras + host I/O + Key M NVMe).
- **USB-C dual-role**: see [usb-dual-role.md](usb-dual-role.md).

### PCIe / M.2: Jetson JAJ vs Modalix SoM

JAJ is laid out for **Jetson Orin NX/Nano** SODIMM PCIe. Modalix is pin-compatible for many
functions but **does not expose the same PCIe controllers** on the gold finger.

| Link | Jetson / JAJ use | Modalix SoM (005-HW-32 Rev 2.1) | JAJ + Modalix status |
|------|------------------|----------------------------------|----------------------|
| **PCIE0** x4 | M.2 NVMe (Key M), etc. | **Present** — full RX/TX 0–3 + CLK + PERST/CLKREQ/WAKE | **Works** — e.g. `lspci` NVMe (Silicon Motion), `lsblk` shows `nvme0n1` |
| **PCIE1** x1 | **M.2 Key E** (WiFi/BT modules) | **Not present as PCIe** — SODIMM pins in that region are **ETH1** (and related), plus `PCIE1_CLK_M2C` only; no `PCIE1_RX`/`PCIE1_TX` data pairs | **Unavailable** (SoM pinout) |
| **PCIE2** x2 | Shared / other | Present (often USB/HDMI bridge path on SiMa carriers) | Used on-module / bridges as applicable |
| **PCIE3** | — | Sideband (PERST/CLKREQ/CLK); not a free Key-E-style x1 | — |

**Key M (NVMe):** Confirmed on hardware with Modalix SoM on JAJ. Rootfs typically remains on
SoM eMMC (`mmcblk0`); the SSD appears as `nvme0n1` and may still hold a prior Jetson/L4T
partition layout until wiped/reformatted for Linux use.

**Key E (WiFi PCIe):** With Modalix on JAJ, **M.2 Key E will not get PCIe**. WiFi cards that
require PCIe on Key E will not enumerate. Workarounds: USB WiFi, SDIO/UART-only modules if
sidebands are wired, or a different host path. This cannot be fixed in device tree alone — the
SoM does not route a PCIe1 PHY to those pins.

Reference: *Modalix System on Module (SoM) Revision 2 Data Sheet* (Document 005-HW-32),
Table 2-3 / Chapter 3 pin listing (PCIE0 x4, PCIE2 x2; pins ~167–175 = ETH1 / not PCIE1 data).

### UART map (Jetson JAJ vs Modalix)

SiMa (bring-up guide): on **Jetson**, Linux console is typically **UART2**; on **Modalix SoM
Rev2**, Linux/U-Boot console is **UART1**, and **UART_B** is tRoot only. The SoM still
exposes three UARTs on the gold finger (005-HW-32 Table 2-9) — plus, on the UART1 RTS/CTS
pins, a fourth usable port (`uart13`, see below).

#### Ports

| SoM name | SODIMM | SoC pinmux | DT / Linux | JAJ connector | Verified (JAJ + Modalix) |
|----------|--------|------------|------------|---------------|---------------------------|
| **UART0** | 99 TX / 101 RX (RTS# 103, CTS# 105) | SIO4 pins 4–5, `uart2_group`, **`uart42`** @ `0x0404a000` | **`/dev/ttyS1`** | UART0 header (3.3 V, TX/RX/RTS/CTS) | **TX+RX work** @ 115200, no FC. **HW flow control does not work** (RTS/CTS not pinmuxed). |
| **UART1** | 203 / 205 — **reversed vs the labels**, see below | SIO1 pins 4–5, `uart2_group`, **`uart12`** @ `0x0401a000` | **`/dev/ttyS0`** (stock console) | **SoM USB-C FTDI** + JAJ **J6** pins 2/3 (3.3 V) | **USB-C: works.** **J6 works after swapping the two data wires and adding a 3V3 pull-up on pin 3** — the pair is reversed on the gold finger and JAJ's translator is direction-committed. See [Getting UART1 out of the J6 header](#getting-uart1-out-of-the-j6-header). |
| **UART1 RTS/CTS pins** | 207 / 209 | SIO1 pins 6–7, `uart3_group`, **`uart13`** @ `0x0401c000` | **`/dev/ttyS2`** | JAJ **J6** pins 5/4 (3.3 V) | **A second UART on the same J6 header**, enabled by `ark-jaj.dtbo`. No console, no getty, and not shared with the on-module FTDI. Flow control was never possible on these pins, so they were dead weight. |
| **UART_B** | 236 TX / 238 RX | tRoot (not APU `ttyS*`) | *(no Linux tty)* | JAJ silk **“UART2”** | **tRoot** interactive (`TROOT:>`, help, etc.) @ 115200. |

#### Pinmux (software)

SiMa SIO: each UART index uses a **2-pin** group only (TX/RX). Naming: `uart12` = SIO
block **1**, index **2** → group **`uart2_group`** → SIO1 **pin4 + pin5** (= DS
**SIO1[4]/[5]** = gold-finger UART1). Likewise `uart42` = SIO4 index 2 → SIO4 pin4+pin5
(= UART0).

Live check (example):

```bash
# UART1
grep 401a000 /sys/kernel/debug/pinctrl/pinctrl-handles
cat /sys/kernel/debug/pinctrl/4010000.pinmux-simaai-sio-pinctrl/pinmux-pins
# expect pin 4/5: 401a000.uart function uart group uart2_group

# UART0
grep 404a000 /sys/kernel/debug/pinctrl/pinctrl-handles
cat /sys/kernel/debug/pinctrl/4040000.pinmux-simaai-sio-pinctrl/pinmux-pins
# expect pin 4/5: 404a000.uart function uart group uart2_group
```

**RTS/CTS** appear on the gold finger and JAJ headers but are **not** part of these 2-pin
UART groups — a SIO UART group is only ever 2 pins wide, so the controller has no RTS/CTS
to put there. Enabling `crtscts` does **not** give working hardware flow control (CTS stays
false on the peer). Use **TX/RX only**.

That also means the UART1 RTS/CTS pins are free for something better: **SIO1 pins 6–7 are
`uart3_group` = `uart13`**, a whole second UART, and JAJ already wires those two pins to
**J6 pins 5 and 4**.

`ark-jaj.dtbo` enables **`uart12`** (UART1), **`uart42`** (UART0) and **`uart13`** (second
UART on the J6 header), and pins the numbering with `serialN` aliases so that
**ttyS0 = uart12, ttyS1 = uart42, ttyS2 = uart13**. The aliases are not cosmetic: `uart13`
probes before `uart42` (lower SIO block), so without them UART0 would have moved to
`/dev/ttyS2` and every `console=ttyS1` reference here would have pointed at the wrong port.

#### Getting UART1 out of the J6 header

**Status: two documented faults (below) plus a measured open somewhere in the path.**
No device-tree change reaches any of it. Findings 1 and 2 come from the hardware documents and
are certain; finding 3 is what the board actually measures today, and it has to be localised
before the wiring fix can matter.

##### 1. The UART1 pair is reversed on the gold finger

Every SIO UART group is **even pin = RX, odd pin = TX**. SiMa's bring-up guide gives the pin
math outright (§3.3.2.2: *“Index 2 will map to output port 4 and 5”*) and its Table 2 shows
the direction on every UART pair it documents — `SIO0[0]`=RX/`[1]`=TX, `SIO2[4]`=RX/`[5]`=TX,
`SIO2[6]`=RX/`[7]`=TX, `SIO5[2]`=RX/`[3]`=TX, `SIO5[4]`=RX/`[5]`=TX. The pinctrl driver agrees:
in `pinctrl-simaai-sio.c` only the **upper** pin of each pair is output-enabled
(`pcsimaai_uartoe` shifted by the pair index).

Now compare the SoM data sheet (005-HW-32 Table 2-9):

| SODIMM | DS signal name | DS SIO column | even=RX / odd=TX says | consistent? |
|--------|----------------|---------------|------------------------|-------------|
| 99 | UART0_TXD | SIO4**[5]** | TX | ✅ |
| 101 | UART0_RXD | SIO4**[4]** | RX | ✅ |
| 203 | UART1_TXD | SIO1**[4]** | **RX** | ❌ |
| 205 | UART1_RXD | SIO1**[5]** | **TX** | ❌ |

UART0's rows agree with themselves — and UART0 works exactly as labelled on JAJ. UART1's two
rows contradict each other, and UART1 is the one that fails. The pair is reversed:

- SODIMM **203** (JAJ `UART1_TXD_3V3`, **J6 pin 2**) is the SoC's **RX**
- SODIMM **205** (JAJ `UART1_RXD_3V3`, **J6 pin 3**) is the SoC's **TX**

Failing in *both* directions is what this predicts rather than evidence against it. A
conventionally wired adapter puts host TX onto the SoC's TX pad (contention, the board hears
nothing) and listens on the SoC's RX pad (nothing to read). Both directions go quiet with a
perfectly good adapter, which is why “the same FTDI works on UART0” only proves the adapter.

##### 2. JAJ's translator is direction-committed (LSF0108 pass-FET)

Schematic sheet 9, *Jetson GPIO Connectors 2*: both carrier UARTs cross **U10 =
LSF0108RKSR**, an 8-bit **passive pass-FET** translator — one NMOS per channel, no output
drivers. It cannot source a high; the high level must come from a pull-up on whichever side
is receiving. JAJ fits **one 604 Ω pull-up per channel, on the receiving side**, chosen from
the *Jetson* direction:

| U10 channel | JAJ net | Header pin | 1V8 side (A) | 3V3 side (B) | can up-shift |
|-------------|---------|-----------|--------------|--------------|--------------|
| A5/B5 | UART0_TXD | J5 pin 2 | — | **R57** | module → header ✅ |
| A6/B6 | UART0_RXD | J5 pin 3 | **R53** | — | header → module ✅ |
| A8/B8 | UART0_RTS | J5 pin 5 | — | **R58** | module → header |
| A7/B7 | UART0_CTS | J5 pin 4 | **R54** | — | header → module |
| A1/B1 | UART1_TXD | **J6 pin 2** | — | **R59** | module → header |
| A2/B2 | UART1_RXD | **J6 pin 3** | **R55** | — | header → module |
| A4/B4 | UART1_RTS | **J6 pin 5** | — | **R60** | module → header |
| A3/B3 | UART1_CTS | **J6 pin 4** | **R56** | — | header → module |

Because finding 1 reverses the pair, the SoC's TX comes out on **J6 pin 3** — the one net
whose pull-up sits on the 1.8 V side. The FET passes lows normally, but on a mark it pinches
off near Vref_A, so pin 3 tops out around **1.8 V** — below an FT232R's V_IH of 2.0 V. Hence:

- **host → board** works as soon as the wires are swapped. That channel (A1/B1) has no
  1.8 V pull-up on the SoC's RX pad and does not need one: a push-pull host both sinks and
  sources through the FET, and R59 on the 3V3 side holds the mark. Down-shifting is the easy
  direction — the pad only has to reach ~1.8 V, which is already a valid high for it.
- **board → host** stays broken until J6 pin 3 gets a 3.3 V pull-up.

A useful tell: an FTDI input has its own weak (≈200 kΩ) internal pull-up, which is far too slow
at 115200 but can be enough at **9600**. If a swapped link passes traffic at 9600 and fails at
115200, the missing pull-up is exactly what you are looking at.

U10 itself is exonerated — UART0 runs through the same package, the same 1V8/3V3 rails and the
same EN, so Vref and EN are good. Nothing else sits on the four UART1 3V3 nets except U10,
R59/R60, the D18 TVS array and J6: there is no carrier USB-serial bridge to contend with.

##### 3. Measured: nothing on J6 reaches the SoC at all (open in the path)

Enabling `uart13` turns J6 into a fully instrumented connector — all four signal pins now land
on live UART pads, so a host adapter on any of them must show up somewhere:

| J6 pin | SODIMM | SoC pad | Linux |
|--------|--------|---------|-------|
| 2 | 203 | SIO1[4] | `ttyS0` (uart12) |
| 3 | 205 | SIO1[5] | `ttyS0` (uart12) |
| 4 | 209 | SIO1[6] or [7] | `ttyS2` (uart13) |
| 5 | 207 | SIO1[7] or [6] | `ttyS2` (uart13) |

Measured with an FT232R on J6 and the SoM USB-C FT230X watching the same `uart12` net
on-module (`uart1-j6-linktest.py`, plus a held-low test):

| Test | Result |
|------|--------|
| Board transmits on `ttyS0`, adapter listens (115200 and 9600) | **0 bytes** |
| Board transmits on `ttyS2`, adapter listens (115200 and 9600) | **0 bytes** |
| Host transmits on adapter → `ttyS0`/`ttyS1`/`ttyS2` `rx` counters | **all stay 0** |
| Same host traffic, watching `uart12` output on SoM USB-C | **12/12 markers intact** |
| Adapter TX held **continuously low** (break) while the board transmits | **8/8 markers intact** |
| SoC `uart12` TX itself, on the SoM USB-C bridge | **works** |

The last two rows are the interesting ones. If J6 pin 3 were connected to the SoC's `uart12`
TX net through U10, holding that pin low for seconds could not leave the console output
untouched — the pass FET is ~10 Ω and the SoM's own FT230X taps the same net. It did leave it
untouched. **So the pin the adapter drives is not electrically on that net**, and the reversed
pair alone no longer explains the failure: there is an open as well.

Localise it cheapest-first — each step is under a minute:

1. **Validate the adapter and its wires.** Touch the adapter's TX and RX wire ends together,
   off the board, and loop back at the host. Proves the adapter, the crimps and the jumpers in
   one shot; this is the most likely culprit and the easiest to miss.
   Also confirm the breakout's logic jumper is on **3.3 V**, not 5 V.
2. **Loopback at the connector.** Jumper J6 pin 2 to pin 3 and run
   `sudo ./uart1-tx-probe.sh loopback` on the board. This bypasses the adapter entirely.
   An echo proves the module *does* route UART1 to the gold finger and U10 passes it, which
   would put the fault back in the adapter wiring. No echo means the open is on the carrier or
   the module.
3. **Continuity, powered down.** J6 pin 2 ↔ U10 pin 18, and U10 pin 3 ↔ SODIMM 203. That
   splits "the carrier eats it" from "the module never routes UART1 off-module".

U10 is still exonerated as a part: UART0 has passed real traffic through the same package,
rails and EN on this carrier (`rx` counted 54 bytes from J5). If step 2 fails and step 3 shows
the carrier intact up to the gold finger, then the module does not route SODIMM 203/205/207/209
and the UART1 header is genuinely unavailable — mark it N/A the way Key E PCIe and CAN are.

##### Ruled out on hardware (software levers are exhausted)

Every software control that could plausibly gate the header has now been toggled, with
detection on **all four** J6 pins in **both** directions (`uart12` + `uart13`), at 115200 and
9600. None of them changes anything:

| Lever | States tried | J6 result |
|-------|--------------|-----------|
| `usb_uart12` (SIO1 line 2) | HIGH (stock) and LOW | dead in both |
| `USB0_VBUS_DETn` = SODIMM 87 (SoM `GPIO00_VBUS_DET`) | driven LOW, and released/floating | dead in both |
| Pinmux | `uart2_group` on pins 4/5, `uart3_group` on 6/7, both confirmed claimed | dead |
| Baud | 115200 and 9600 | dead |

The `usb_uart12` retest matters because the original refutation scoped **J6 pin 2**, which is
the SoC's *RX* under the reversed pair — the wrong pin to watch. Retested properly with the
adapter and the `rx` counters on both pins: it still does nothing. The DTS naming is suggestive
(`usb-hog`/`output-high` for `usb_uart12` on SIO1 versus `uart-hog`/`output-low` for
`usb_uart60` on SIO6, which reads exactly like a USB-vs-UART select), but on this carrier
toggling it has no effect on the header either way.

**Worth knowing even though it is not the UART fault:** JAJ drives `USB0_VBUS_DETn` (SODIMM 87)
from the FUSB301's **open-drain INT_N**, and **R70 — the 47 kΩ pull-up to 1V8 — is DNP in the
Production variant**. Nothing else pulls that net. Since no Linux driver services the FUSB301
interrupt, `INTERRUPT` (0x13) latches (measured `0x07`, with `MASK` = 0x00 and global
`INT_MASK` clear) and INT_N therefore sits **driven LOW indefinitely after boot** — so SODIMM 87
reads asserted by accident, not by design, and floats undriven the moment anything clears that
register. JAJ names the net active-low (`..._DETn`) while the SoM names the pin active-high
(`GPIO00_VBUS_DET`), so the polarity is worth confirming before anything is made to depend on
it. Reading register 0x13 is enough to change the pin's state.

##### The fix

J6 is a 6-pin JST GH (BM06B-GHS-TBT): **1 = 5 V, 2 = UART1_TXD_3V3, 3 = UART1_RXD_3V3,
4 = CTS, 5 = RTS, 6 = GND.**

```text
host GND ---------------------------------- J6 pin 6
host TX  ---------------------------------- J6 pin 2   <- the pin silkscreened TX
host RX  ---------------------------------- J6 pin 3   <- the pin silkscreened RX
                     |
                     +--[ 1k ]--- adapter 3V3          <- the missing pull-up
```

Once finding 3 is resolved and the path is continuous:

1. **Swap the two data wires** relative to the usual convention: host TX to the pin labelled
   TX, host RX to the pin labelled RX.
2. **Add a pull-up on J6 pin 3**, 604 Ω–2.2 kΩ to **3.3 V**. A flying resistor to the adapter's
   3V3 output is enough for the bench; the board-side equivalent is a second R59 fitted from
   `UART1_RXD_3V3` to 3V3.
   **Do not pull up to J6 pin 1** — that is 5 V, above the translator's Vref_B and the adapter's
   input rating.
3. Leave `usb_uart12` **HIGH** (stock). It is the on-module USB-bridge enable, not a routing
   select — see the refutation below.
4. Nothing to change in the device tree; `uart12` is already enabled and correctly muxed.

Then, over SSH (UART1 is the console, so do not test from the port you are disturbing):

```bash
sudo ./scripts/uart1-tx-probe.sh report          # counters + pinmux + console owner
sudo ./scripts/uart1-tx-probe.sh tx              # light paced printf on ttyS0
sudo ./scripts/uart1-tx-probe.sh rx 20           # listen; drive the header from the host
```

The fastest read on progress is the byte counters, no scope required:

```bash
cat /proc/tty/driver/serial
# 0: uart:16550A mmio:0x0401A000 ... tx:20303 rx:0     <- rx:0 = nothing has ever reached
#                                                          the SoC's UART1 RX pad
```

`rx` climbing off zero is proof the host→board direction is fixed; bytes arriving at the host
prove board→host.

Or drive both directions at once from the host, which also names the failure mode:

```bash
./scripts/uart1-j6-linktest.py                    # ttyS0 / uart12 on J6 pins 2/3
./scripts/uart1-j6-linktest.py --dev /dev/ttyS2   # uart13 on J6 pins 5/4
```

It sweeps 115200 and 9600, watches the adapter for board→host, and reads the kernel's own
receive counter for host→board. Needs `dialout` on the host
(`sudo usermod -aG dialout $USER && newgrp dialout`).

##### Alternative with no resistor: use `uart13` on J6 pins 5/4

`ark-jaj.dtbo` also enables **`uart13`** (SIO1 pins 6–7 → SODIMM 207/209 → **J6 pin 5 and
pin 4**) as **`/dev/ttyS2`**. Those pins can never carry flow control, so nothing is lost, and
this port is cleaner than `uart12` for an application: no console, no getty, and no on-module
FT230X sharing the net.

The same even=RX/odd=TX rule applies, so one of the two is the SoC's TX. **If it lands on J6
pin 5, no added pull-up is needed at all** — R60 is already on the 3V3 side of that net. If it
lands on pin 4, that net needs the same pull-up treatment as pin 3. Determine it empirically:

```bash
stty -F /dev/ttyS2 115200 cs8 -cstopb -parenb -crtscts raw
printf 'TTYS2_ON_J6\r\n' > /dev/ttyS2      # host RX on J6 pin 5, then retry on pin 4
```

##### What is already ruled out

**`usb_uart12` does not route UART1 to the carrier — REFUTED on hardware.**
`modalix-som.dts` hogs a GPIO in SIO block 1 — the same block that hosts `uart12` — and names
it after the UART, which made it look like a module-side routing mux:

```dts
&port1 {                          /* port1 = gpio10 @ 0x04011000 = SIO1's GPIO bank */
	snps,nr-gpios = <4>;
	usb-hog {
		gpio-hog;
		gpios = <2 GPIO_ACTIVE_HIGH>;   /* SIO1_IO[2] */
		output-high;
		line-name = "usb_uart12";
	};
};
```

It is not. Measured on JAJ + Modalix with 0x55 running continuously:

| `usb_uart12` | SoM USB serial | JAJ UART1 connector |
|---|---|---|
| **HIGH** (stock) | full 0x55 spam ✅ | 3.3 V idle, no edges |
| **LOW** | **FTDI drops off USB** | 3.3 V idle, no edges |
| HIGH (restored) | 0x55 again ✅ | still silent |

So it is an **enable/reset for the on-module USB-serial bridge**, not a routing select.
**Leave it HIGH.** `uart1-tx-probe.sh mux carrier` is kept only for characterising the line.

**Software is not holding the line.** Pinmux is correct and live — SIO1 pins 4/5 owned by
`401a000.uart`/`uart2_group`, pins 6/7 by `401c000.uart`/`uart3_group`:

```bash
cat /sys/kernel/debug/pinctrl/4010000.pinmux-simaai-sio-pinctrl/pinmux-pins
```

One non-hardware cause worth ruling out first: if the console got moved off `ttyS0` and no
getty or app is writing to it, **TX legitimately idles high**.

##### Gold-finger UART is 1.8 V, not 3.3 V

Table 2-9 lists all six UART pins as `CMOS - 1.8V`. The module level-shifts elsewhere and says
so (I2C0/I2C1: *“Level shifted from 1.8V - 3.3V”*; CAM_I2C: `CMOS - 3.3V`) — the UARTs get no
such note. Expect 0–1.8 V at the SODIMM, and set the scope threshold accordingly before calling
a line dead. On the carrier side of U10, remember from finding 2 that a mark on the SoC's TX
net reaches only ~1.8 V until the pull-up is added — so a 3.3 V-threshold probe reads it as a
permanent low.

##### Sharing UART1 with the on-module FTDI

The SoM's FT230X and the gold finger tap the **same** SoC UART1 — they are not independent
ports. With the USB-C cable plugged in, the FT230X's TX output drives the SoC's RX net
directly (low impedance, on-module) while a J6 host reaches it only through U10's pass FET, so
the module bridge wins any contest. **Unplug USB-C while testing J6 in the host→board
direction**, or accept that J6 RX may be swamped. `uart13` on J6 pins 5/4 has no such problem.

#### Recommended usage

| Goal | Port | Device / host path | Settings |
|------|------|--------------------|----------|
| **Carrier generic serial (app / sensor / debug)** | **UART0** | Board `/dev/ttyS1`; host FTDI on UART0 header | **115200 8N1, no flow control** — works as labelled, no rework |
| **Second carrier serial on the J6 header** | **`uart13`** | Board `/dev/ttyS2`; host FTDI on **J6 pins 5/4** | 115200 8N1, no FC. No console/getty; no FTDI sharing the net |
| **UART1 on the J6 header** | **UART1** | Board `/dev/ttyS0`; host FTDI on **J6 pins 2/3 swapped** + 3V3 pull-up on pin 3 | See [the fix](#the-fix); also move the console off `ttyS0` first |
| **SoM Linux console / kernel log** | **UART1** | Host: SoM **USB-C** FT230X (`/dev/serial/by-id/usb-FTDI_FT230X_*`) = same as `/dev/ttyS0` | 115200 8N1, no FC |
| **tRoot / secure console** | **UART_B** | Host FTDI on JAJ **“UART2”** header | 115200 8N1; prompt `TROOT:>` |
| Free UART1 for an app only | UART1 | `/dev/ttyS0` after moving console off it | See below; remember USB-C is the same UART |

```bash
# UART0 example (preferred generic header UART)
stty -F /dev/ttyS1 115200 cs8 -cstopb -parenb -crtscts raw
picocom -b 115200 /dev/ttyS1
```

#### Hazard: do not flood a Modalix UART at wire speed

Sustained unpaced 0x55 on **UART0 (`/dev/ttyS1`)** correlated with a **hard board
hang** — Ethernet, SSH and the USB-C console all went away, and the following boots
took ~30 s with an unclean FAT. Light, paced traffic on UART0 is fine.

Prefer short `printf` tests. `uart1-tx-probe.sh spam` is paced (64 B / 100 ms) and
capped at 60 s for this reason; do not replace it with a tight `while` loop.

#### Free UART1 from console (optional)

Stock: `console=ttyS0` + `serial-getty@ttyS0` on UART1. To use UART1 only for an application:

1. Keep UART0 enabled (`uart42` in overlay) for debug on `/dev/ttyS1`.
2. Move kernel console to UART0 and reboot:

   ```bash
   sudo fw_printenv bootargs
   sudo fw_setenv bootargs 'console=ttyS1,115200n8 uio_pdrv_genirq.of_id=generic-uio netcfg=dhcp root=/dev/mmcblk0p4 rw rootwait'
   sudo reboot
   ```

3. Mask getty on UART1; optional getty on UART0:

   ```bash
   sudo systemctl mask serial-getty@ttyS0.service
   sudo systemctl enable --now serial-getty@ttyS1.service
   ```

4. App on UART1: `stty -F /dev/ttyS0 115200 cs8 -cstopb -parenb -crtscts raw`

**Constraints:** USB-C FTDI **is** UART1 (not independent). Do not use HW flow control with
the current pinmux. Kernel `console=ttyS0` mixes with app traffic if left on UART1.

#### Host FTDI tips

```bash
ls -l /dev/serial/by-id/
# SoM USB-C:  usb-FTDI_FT230X_Basic_UART_*-if00-port0  → Linux UART1
# External:   usb-FTDI_FT232R_*                        → whichever header you wired
# 115200 8N1, no hardware flow control
picocom -b 115200 /dev/ttyUSB1   # example
```

You may need `dialout` (`newgrp dialout` or re-login after `usermod -aG dialout $USER`).

## Parallel map to ark_jetson_kernel

| Concern | Jetson JAJ | Modalix JAJ |
|---------|------------|-------------|
| Product id | `JAJ` | `ark-jaj` |
| Kernel | L4T 5.15 | linux-simaai 6.18 |
| Flash transport | USB recovery | eMMC via netboot or WIC media |
| Default login | `jetson` | `sima` / `edgeai` |
| Cameras | jetson-io overlays | `ark-jaj.dtbo` (CSI1+CSI2, FSUSB42 I2C mux) |
| M.2 Key M NVMe | PCIE0 x4 | **Works** (verified on hardware) |
| M.2 Key E WiFi | PCIE1 x1 | **Unavailable** (no PCIE1 on Modalix SoM) |
| Linux serial console | Often carrier **UART2** | **UART1** via SoM **USB-C** FTDI |
| Carrier generic UART | — | **UART0** → `/dev/ttyS1` (verified TX/RX); **UART1 header J6** works with the two data wires swapped + a 3V3 pull-up on pin 3, or use `uart13` → `/dev/ttyS2` on J6 pins 5/4 |
| JAJ silk “UART2” | Linux debug (typical) | **tRoot only** on Modalix |
| CAN | SoM CAN → JAJ TJA1051 | **No CAN on Modalix SoM** (see below) |

### CAN (JAJ transceiver vs Modalix SoM)

**Modalix SoM has no CAN / CAN-FD controller** and does not list CAN among gold-finger
interfaces (005-HW-32: PCIe, GbE, CSI, USB, HDMI, UART, SPI, I2C, GPIO only).

**Just a Jetson** still has a **Jetson CAN** path: **TJA1051** transceiver to the CAN
connector (e.g. J15), with digital side:

| TJA1051 | JAJ net | SODIMM pin (Jetson) | Modalix SoM (005-HW-32) |
|---------|---------|---------------------|-------------------------|
| TxD | `JCAN_TX` / `CAN_TX` | **145** | **N/A** (not connected) |
| RxD | `JCAN_RX` / `CAN_RX` | **143** | **N/A** (not connected) |

With a **Jetson** SoM those balls are real CAN (or muxable) pins, so the on-board PHY works.
With **Modalix**, pins **143/145 are unused** — the transceiver TxD/RxD have **nothing on the
module** to drive them.

**GPIO bit-bang through the stock JAJ TJA1051 is not possible** without rework (no SoC pad on
those nets). Soft bit-bang CAN on arbitrary GPIOs is also a poor fit for Linux at typical bit
rates even if you jumpered the PHY to free GPIOs.

**Practical options on JAJ + Modalix:** USB–CAN adapter; SPI CAN controller (e.g. MCP2515/2518)
on a free SPI + IRQ GPIO; or hardware mod of TJA1051 TxD/RxD to available Modalix GPIOs (still
prefer a real controller over bit-bang).

## Troubleshooting

| Symptom | Check |
|---------|--------|
| No serial data | Power LED / 12 V; `dialout` group; 115200 baud; correct USB port / header |
| U-Boot but no Ethernet | Cable on GbE; `setenv ipaddr` / `serverip`; link lights |
| Netboot TFTP fails | Host firewall UDP/69; `sudo` for sima-cli on Linux |
| Kernel panic early | Wrong DTB (must be `modalix-som` class); try without `dtbos` |
| NVMe not visible | PCIE0 / Key M seating / power; expect `lspci` NVMe + `lsblk` `nvme0n1` (Key M works when seated) |
| Key E WiFi no PCIe device | Expected on Modalix — no PCIE1 data lanes (see above) |
| No Linux shell on JAJ “UART2” | Expected on Modalix — that header is **tRoot**, use USB-C (UART1) or UART0 |
| UART1 J6 header dead both ways (Modalix) | Expected with conventional wiring — the pair is reversed on the gold finger. **Swap the two data wires at J6** (host TX → pin 2, host RX → pin 3). `usb_uart12` is not the fix (refuted). See [Getting UART1 out of the J6 header](#getting-uart1-out-of-the-j6-header) |
| J6 UART1 receives but never transmits | Missing pull-up: J6 pin 3 carries the SoC's TX and its only pull-up is on the 1.8 V side, so a mark reaches ~1.8 V. Add 604 Ω–2.2 kΩ from pin 3 to **3.3 V** (not to pin 1, which is 5 V). Often works at 9600 and fails at 115200 |
| `/dev/ttyS2` present but silent | `uart13` on J6 pins 5/4. Try host RX on pin 5 first (R60 already pulls that net to 3V3); if the SoC's TX is on pin 4, that net needs a pull-up |
| Board hangs after UART traffic (no eth/SSH/USB-C) | Wire-speed UART flood — see the hazard note. Use light `printf` or paced `spam`; power-cycle to recover |
| Can't reach the board over Ethernet | Host may be dual-homed on `192.168.7.0/24` (wired + wifi); wifi often can't reach it. Force the wired NIC: `ping -I enp5s0 192.168.7.50` |
| UART0 works without FC, fails with `crtscts` | Expected — RTS/CTS not pinmuxed; use **`-crtscts`** |
| JAJ CAN connector silent on Modalix | Expected — SoM pins 143/145 **N/A**; TJA1051 not driven; use USB/SPI CAN |
