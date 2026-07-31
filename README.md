# meta-ark-simaai

Yocto layer adding [ARK Electronics](https://arkelectron.com) Jetson carrier board
support for the [SiMa.ai Modalix](https://sima.ai) SoM.

Depends on [`meta-simaai`](https://github.com/SiMa-ai/meta-simaai).

## Supported machines

| MACHINE       | Carrier                         | Status      |
|---------------|---------------------------------|-------------|
| `ark-jaj`     | ARK Just a Jetson               | Framework   |
| `ark-pab`     | ARK Jetson PAB Carrier          | Framework   |
| `ark-pab-v3`  | ARK Jetson PAB V3 Carrier       | Framework   |
| `ark-can-pab` | ARK Jetson CAN PAB Carrier      | Framework   |

All machines inherit Modalix SoM defaults from `meta-simaai` and layer
carrier-specific device-tree overlays via `ark-carrier-dtbo`.

## Dependencies

- Yocto / Poky **scarthgap** (same series as `meta-simaai`)
- [`meta-simaai`](https://github.com/SiMa-ai/meta-simaai)
- Other layers required by SiMa's build (see their `bblayers.conf.sample`)

## Quick start

1. Add this layer next to `meta-simaai` in your build tree.
2. Extend `bblayers.conf`:

```
BBLAYERS += "${TOPDIR}/../meta-ark-simaai"
```

3. Select a machine in `local.conf`:

```
MACHINE = "ark-jaj"
```

4. Build a SiMa image (once bring-up DTs are filled in):

```
bitbake simaai-image-minimal
```

See `conf/templates/ark/` for sample conf snippets.

## Layout

```
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
- Carrier placeholders live in `recipes-kernel/ark-carrier-dtbo/files/*.dtso`.
- Replace / extend those overlays (and optionally add in-tree DTBs) during bring-up.
- U-Boot still uses the upstream Modalix board directory via `ARK_UBOOT_BOARD`.

## License

MIT — see [LICENSE](LICENSE).
