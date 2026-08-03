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
- **DT**: base `modalix-som_16g.dtb` + `ark-jaj.dtbo` overlay. Optional add-on:
  `ark-jaj-uart1-carrier.dtbo` (routes UART1 to the gold finger — see the UART section).
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
exposes three UARTs on the gold finger (005-HW-32 Table 2-9).

#### Ports

| SoM name | SODIMM | SoC pinmux | DT / Linux | JAJ connector | Verified (JAJ + Modalix) |
|----------|--------|------------|------------|---------------|---------------------------|
| **UART0** | 99 TX / 101 RX (RTS# 103, CTS# 105) | SIO4 pins 4–5, `uart2_group`, **`uart42`** @ `0x0404a000` | **`/dev/ttyS1`** | UART0 header (3.3 V, TX/RX/RTS/CTS) | **TX+RX work** @ 115200, no FC. **HW flow control does not work** (RTS/CTS not pinmuxed). |
| **UART1** | 203 TX / 205 RX (RTS# 207, CTS# 209) | SIO1 pins 4–5, `uart2_group`, **`uart12`** @ `0x0401a000` | **`/dev/ttyS0`** (stock console) | **SoM USB-C FTDI** + JAJ **J6** (3.3 V) | **USB-C: TX works** (console / spam). **J6 TX stuck idle high** with Modalix (SoC TX does not appear on carrier 3.3 V); **see [UART1 TX not reaching the carrier](#uart1-tx-not-reaching-the-carrier)**. Same JAJ carrier is fine with Jetson on *its* debug UART (often UART2). |
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
UART groups in the current kernel DT. Enabling `crtscts` does **not** give working hardware
flow control (CTS stays false on the peer). Use **TX/RX only**.

`ark-jaj.dtbo` enables **`uart12`** (UART1) and **`uart42`** (UART0).

#### UART1 TX not reaching the carrier

Symptom: `/dev/ttyS0` opens, the pinmux looks right, the console works over the SoM
USB serial — but **SODIMM 203 / J6 TX never toggles on a scope**. Three separate
things in SiMa's own sources explain this. Work them in order; the first two cost
nothing to test.

##### 1. The `usb_uart12` line keeps UART1 on the module's USB bridge *(leading suspect)*

SiMa's stock `modalix-som.dts` hogs a GPIO in **SIO block 1** — the same block that
hosts `uart12` — and names it after the UART:

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

`ark-jaj.dtbo` never touches `port1`, so the line stays **high** on JAJ. The bring-up
guide (005-HW-31 §1.6.2 #6) says UART1 defaults to an on-module UART-to-USB bridge and
that only *"some carrier boards have the UART1 available on the 40-pin header"* — i.e.
routing UART1 off-module is a per-carrier decision, and `usb_uart12` looks like the
knob. (SiMa does not document the net; the sibling hog `usb_uart60` on `port6[0]` is
driven **low**.)

Test it live — no rebuild, ~30 s. Do this **over SSH**, not over the console you are
about to move:

```bash
# terminal 1 — give the scope an edge to find (0x55 8N1 = clean 57.6 kHz square wave)
sudo ./uart1-tx-probe.sh spam 120

# terminal 2 — flip the mux while watching SODIMM 203 and 205
sudo ./uart1-tx-probe.sh mux            # shows current state
sudo ./uart1-tx-probe.sh mux carrier    # drive SIO1_IO[2] low
sudo ./uart1-tx-probe.sh mux usb        # put it back
```

It is a `gpio-hog`, so `gpioset` returns `Device or resource busy`; the script pokes the
DesignWare GPIO data register at `0x04011000` (bit 2) instead.

If that lights up the carrier, make it persistent with the optional overlay:

```text
setenv dtbos "ark-jaj.dtbo ark-jaj-uart1-carrier.dtbo"
```

(`recipes-kernel/ark-carrier-dtbo/files/ark-jaj-uart1-carrier.dtso` — adds `output-low`
to the hog. gpiolib checks `input` → `output-low` → `output-high`, so the override wins
without deleting a property, which runtime overlays cannot do.)

##### 2. UART1 TX/RX look crossed on the gold finger — scope pin **205** too

The pinctrl driver settles which pin of a UART pair is the output. In
`drivers/pinctrl/pinctrl-simaai-sio.c`:

```c
static const u32 uart2_pins[] = { 4, 5 };
#define pcsimaai_uartoe 0x2                      /* output-enable mask, per pair */
.oe_val = pcsimaai_uartoe << (num_pins * n)      /* uart2_group, n=2 → 0x2 << 4 = bit 5 */
```

Only the **upper** pin of each pair is output-enabled, so in every UART group
**lower = RX, upper = TX**. That matches the bring-up guide's SIO table everywhere it
appears (`SIO0[0]`=RX/`[1]`=TX, `SIO2[4]`=RX/`[5]`=TX, `SIO2[6]`=RX/`[7]`=TX,
`SIO5[2]`=RX/`[3]`=TX, `SIO5[4]`=RX/`[5]`=TX).

Now compare the SoM data sheet (005-HW-32 Table 2-9):

| SODIMM | Signal name | DS says | Driver says that pin is | Consistent? |
|--------|-------------|---------|--------------------------|-------------|
| 99 | UART0_TXD | SIO4**[5]** | TX | ✅ |
| 101 | UART0_RXD | SIO4**[4]** | RX | ✅ |
| 203 | UART1_TXD | SIO1**[4]** | **RX** | ❌ inverted |
| 205 | UART1_RXD | SIO1**[5]** | **TX** | ❌ inverted |

UART0 is self-consistent — and UART0 is the one that works on JAJ. UART1 is inverted.
Either the SoM crosses UART1 on the gold finger, or Table 2-9's SIO column is a typo;
**scoping SODIMM 205 (J6 "RX") settles it in one probe.** If 205 is the one toggling,
swap TX/RX at the header.

##### 3. Gold-finger UART is **1.8 V**, not 3.3 V

Table 2-9 lists all six UART pins as `CMOS - 1.8V`. The module explicitly level-shifts
elsewhere and says so (I2C0/I2C1: *"Level shifted from 1.8V - 3.3V"*; CAM_I2C:
`CMOS - 3.3V`) — the UARTs get no such note. Expect a 0–1.8 V swing at the SODIMM, so
set the scope threshold accordingly before concluding a line is dead.

This also matters for finding 2: if JAJ puts a fixed-direction 1.8↔3.3 V translator on
that net (direction chosen from the Jetson pinout), a crossed Modalix UART1 would have
the translator driving *into* the SoC's TX pad while the header side sits idle — which
is both a dead TX **and** a contention risk. Check the JAJ schematic for a translator on
the 203/205 nets before driving them.

##### Quick triage

```bash
sudo ./scripts/uart1-tx-probe.sh report
```

Dumps `uart12` DT status, the `ttyS*` mapping, who owns the console, the SIO1 pinmux
pins (expect pins 4/5 → `401a000.uart` / `uart2_group`), the `usb_uart12` state, and
recent kernel UART errors.

One non-hardware cause worth ruling out first: if the console got moved off `ttyS0` and
no getty or app is writing to it, **TX legitimately idles high**. `spam` above removes
that doubt.

#### Recommended usage

| Goal | Port | Device / host path | Settings |
|------|------|--------------------|----------|
| **Carrier generic serial (app / sensor / debug)** | **UART0** | Board `/dev/ttyS1`; host FTDI on UART0 header | **115200 8N1, no flow control** |
| **SoM Linux console / kernel log** | **UART1** | Host: SoM **USB-C** FT230X (`/dev/serial/by-id/usb-FTDI_FT230X_*`) = same as `/dev/ttyS0` | 115200 8N1, no FC |
| **tRoot / secure console** | **UART_B** | Host FTDI on JAJ **“UART2”** header | 115200 8N1; prompt `TROOT:>` |
| Free UART1 for an app only | UART1 | `/dev/ttyS0` after moving console off it | See below; remember USB-C is the same UART |

```bash
# UART0 example (preferred generic header UART)
stty -F /dev/ttyS1 115200 cs8 -cstopb -parenb -crtscts raw
picocom -b 115200 /dev/ttyS1
```

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
| Carrier generic UART | — | **UART0** → `/dev/ttyS1` (verified TX/RX) |
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
| UART1 J6 TX stuck high (Modalix) | `./scripts/uart1-tx-probe.sh report`. In order: (1) `usb_uart12` hog holds UART1 on the module's USB bridge, (2) TX/RX crossed — scope SODIMM **205**, (3) it's **1.8 V**, not 3.3 V. See [UART1 TX not reaching the carrier](#uart1-tx-not-reaching-the-carrier) |
| UART0 works without FC, fails with `crtscts` | Expected — RTS/CTS not pinmuxed; use **`-crtscts`** |
| JAJ CAN connector silent on Modalix | Expected — SoM pins 143/145 **N/A**; TJA1051 not driven; use USB/SPI CAN |
