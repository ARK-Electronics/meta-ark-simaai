# meta-ark-simaai

Yocto layer adding [ARK Electronics](https://arkelectron.com) Jetson carrier board
support for the [SiMa.ai Modalix](https://sima.ai) SoM.

Depends on [`meta-simaai`](https://github.com/SiMa-ai/meta-simaai).

Workflow mirrors [`ark_jetson_kernel`](https://github.com/ARK-Electronics/ark_jetson_kernel):
`setup.sh` → `build.sh` → `flash.sh`.

## Supported machines

| MACHINE       | Carrier                         | Status      |
|---------------|---------------------------------|-------------|
| `ark-jaj`     | ARK Just a Jetson               | DT overlay live (eLxr) |
| `ark-pab`     | ARK Jetson PAB Carrier          | Framework   |
| `ark-pab-v3`  | ARK Jetson PAB V3 Carrier       | Framework   |
| `ark-can-pab` | ARK Jetson CAN PAB Carrier      | Framework   |

All machines inherit Modalix SoM defaults from `meta-simaai` and layer
carrier-specific device-tree overlays via `ark-carrier-dtbo`.

## Dependencies

- Yocto / Poky **scarthgap** (same series as `meta-simaai`)
- [`meta-simaai`](https://github.com/SiMa-ai/meta-simaai)
- Other layers required by SiMa's build (cloned by `setup.sh`)

## Quick start (Just a Jetson)

Hardware: Modalix SoM on JAJ, 12 V power, USB-C debug (FTDI) to the host,
optional Ethernet + M.2 SSD.

```bash
# 1. Host serial access
sudo usermod -aG dialout $USER && newgrp dialout
picocom -b 115200 /dev/ttyUSB0   # power-cycle board; watch U-Boot/Linux

# 2. One-time Yocto workspace (~80+ GB free disk)
SETUP_INSTALL_DEPS=1 ./setup.sh

# 3. Build
./build.sh ark-jaj

# 4. Flash
./flash.sh ark-jaj --netboot              # eMMC via sima-cli TFTP (recommended recovery)
# or, host-attached disk only:
./flash.sh ark-jaj --device /dev/sdX      # WIC write (NOT your host root disk)
```

Full bring-up notes: **[docs/bringup-jaj.md](docs/bringup-jaj.md)**.

### Manual layer add (if not using setup.sh)

```
BBLAYERS += "${TOPDIR}/../meta-ark-simaai"
MACHINE = "ark-jaj"
bitbake simaai-image-minimal
```

See `conf/templates/ark/` for sample conf snippets.

## Layout

```
setup.sh / build.sh / flash.sh   # ark_jetson_kernel-style entrypoints
docs/bringup-jaj.md
conf/
  layer.conf
  machine/
    include/ark-modalix-common.inc   # Shared Modalix + ARK settings
    ark-jaj.conf
    ark-pab.conf
    ark-pab-v3.conf
    ark-can-pab.conf
  templates/ark/
recipes-kernel/
  ark-carrier-dtbo/                  # Out-of-tree carrier DT overlays
  linux/                             # COMPATIBLE_MACHINE for ARK boards
recipes-bsp/
  u-boot/                            # COMPATIBLE_MACHINE + Modalix bootscript map
  simaai-*/                          # COMPATIBLE_MACHINE extensions
recipes-core/
  images/                            # Image COMPATIBLE_MACHINE extensions
```

## Bring-up notes

- Pin-compatible Modalix SoM drops into ARK Jetson carriers electrically.
- Stock `modalix-som.dtb` is the default kernel DT until carrier DTs land.
- JAJ overlay: `recipes-kernel/ark-carrier-dtbo/files/ark-jaj.dtso` (identity + dual CSI IMX219).
- Deploy live: `./scripts/deploy-jaj-dtbo.sh --reboot` (see `docs/bringup-jaj.md`).
- Other carriers still use placeholder overlays under the same recipe.
- U-Boot still uses the upstream Modalix board directory via `ARK_UBOOT_BOARD`.
- Boot device is **on-SoM eMMC** by default; carrier NVMe is secondary storage
  (unlike Jetson `flash.sh` defaulting to NVMe root).

## License

MIT — see [LICENSE](LICENSE).
