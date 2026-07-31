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

## Troubleshooting

| Symptom | Check |
|---------|--------|
| No serial data | Power LED / 12 V; `dialout` group; 115200 baud; correct USB port |
| U-Boot but no Ethernet | Cable on GbE; `setenv ipaddr` / `serverip`; link lights |
| Netboot TFTP fails | Host firewall UDP/69; `sudo` for sima-cli on Linux |
| Kernel panic early | Wrong DTB (must be `modalix-som` class); try without `dtbos` |
| NVMe not visible | PCIE0 / Key M seating / power; expect `lspci` NVMe + `lsblk` `nvme0n1` (Key M works when seated) |
| Key E WiFi no PCIe device | Expected on Modalix — no PCIE1 data lanes (see above) |
