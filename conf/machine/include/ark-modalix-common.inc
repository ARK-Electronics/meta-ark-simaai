#@TYPE: Machine include
#@NAME: ark-modalix-common
#@DESCRIPTION: Shared settings for ARK Jetson carriers with SiMa.ai Modalix SoM

include conf/machine/include/simaai-common.inc

# So recipes/overrides that key off "modalix" also apply
MACHINEOVERRIDES =. "modalix:"

# Soc / board mapping used by U-Boot bootscript path helper
ARK_UBOOT_BOARD ??= "modalix"
ARK_SOC ??= "modalix"

# Hard-assign like meta-simaai modalix.conf — ??= loses to poky's POKY_INIT_MANAGER=sysvinit
INIT_MANAGER = "systemd"

# Kernel / defconfig — Modalix until carrier-specific configs exist
KBUILD_DEFCONFIG ?= "simaai_modalix_defconfig"
UBOOT_MACHINE ?= "sima_modalix_defconfig"
# meta-simaai common.inc still prefers 6.1%; recipes ship 6.18.x
PREFERRED_VERSION_linux-simaai ?= "6.18%"

# Default serial console (override per-board if needed)
BAUD = "${@115200 if d.getVar('BAUDRATE') == None else d.getVar('BAUDRATE')}"
SERIAL_CONSOLES ?= "${BAUD};ttyS0"

# WIC layout from meta-simaai Modalix
WKS_FILE ?= "simaai-modalix-image.wks"

# SiMa commercial EULA
LICENSE_FLAGS_ACCEPTED = "commercial"
SIMAAI_LICENSE_DIR = "${TOPDIR}/../meta-simaai/licenses"
LICENSE_PATH += "${SIMAAI_LICENSE_DIR}"

DISTRO_FEATURES:remove = "bluetooth wifi 3g nfc vulkan wayland"
MACHINE_FEATURES += "alsa usbgadget usbhost"
SDKIMAGE_FEATURES:remove = "dbg-pkgs src-pkgs"

# Base Modalix SoM DT until carrier board DTs are upstreamed / added here.
# Carrier-specific fixups ship as overlays from ark-carrier-dtbo.
KERNEL_DEVICETREE ?= "simaai/modalix-som.dtb"
DEVICETREE_NAME ?= "modalix-som.dtb;boot-0/ modalix-som.dtb;boot-1/"

# Default U-Boot overlay env name (set at runtime via dtbos); board confs override
ARK_DEFAULT_DTBO ??= ""

# WIC puts overlays/* under boot-0/overlays/, but mmcboot.cmd fatloads
# ${boot_path}${dtbos} (boot-0/<name>.dtbo). Copy the default overlay there too.
IMAGE_BOOT_FILES:append = "${@' overlays/%s;boot-0/%s overlays/%s;boot-1/%s' % ((d.getVar('ARK_DEFAULT_DTBO') or '',) * 4) if d.getVar('ARK_DEFAULT_DTBO') else ''}"
