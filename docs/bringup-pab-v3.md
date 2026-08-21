# ARK Jetson PAB V3 + Modalix SoM bring-up

Hardware: [ARK Jetson PAB Carrier V3](https://docs.arkelectron.com/products/flight-controller/jetson-pabs/ark-jetson-pab-carrier-v3)
with a SiMa Modalix SoM in the 260-pin SODIMM, 5 V PAB power (or equivalent),
Ethernet (via onboard **KSZ8795** switch), optional M.2 NVMe, dual CSI cameras.

Default login (SiMa eLxr images): **`sima` / `edgeai`**.

## 1. Console when Ethernet is dead

The V3 carrier routes SoM GbE through a **KSZ8795CLX**. Until the device tree
releases **SWITCH_RSTn** (SODIMM 211 = GPIO09), `end0` stays down and SSH will
not work.

Use the **SoM USB-C** FTDI console (FT230X), **115200 8N1**, **DTR/RTS off**
(DTR resets this SoM). Ignore the FT232 (`ttyUSB0`) if both adapters are
plugged in. Login: **`sima` / `edgeai`**.

```bash
# host
ls /dev/serial/by-id/
# usb-FTDI_FT230X_Basic_UART_… -> ttyUSB1
picocom -b 115200 --lower-dtr --lower-rts \
  /dev/serial/by-id/usb-FTDI_FT230X_Basic_UART_*-if00-port0
```

Close picocom/PuTTY before the serial deploy scripts (they need the port).
First-boot after a stock flash (KSZ poke + overlay):

```bash
./scripts/pab-v3-firstboot.sh
```

Or overlay only, over serial (no eth required):

```bash
./scripts/deploy-pab-v3-dtbo.sh --serial /dev/serial/by-id/usb-FTDI_FT230X_Basic_UART_*-if00-port0 --reboot
```

## 2. Deploy board support (live eMMC, when eth works)

```bash
# From meta-ark-simaai on the host (board DHCP or static on the office LAN)
BOARD=sima@192.168.7.143 PASSWORD=edgeai ./scripts/deploy-pab-v3-dtbo.sh --reboot
```

After reboot:

```bash
cat /proc/device-tree/model
# ARK Jetson PAB V3 with SiMa Modalix SoM

tr '\0' ' ' < /proc/device-tree/compatible; echo
# ark,jetson-pab-v3 simaai,modalix-som simaai,modalix

ip -br a
# end0 … UP … 100Mb/s (DHCP or static)

# Unique ID EEPROM + FUSB
ls /sys/bus/i2c/devices/ | grep -E '0025|0050'
```

KSZ `SWITCH_RSTn` / `SW_PMEn` and `FMU_RST_REQ` are **Linux gpio-hogs on
port7** (`ark-pab-v3.dtbo`). `gpio70` is already enabled in
`modalix-som_16g.dtb`. Do **not** hog CAM PWDN or `VBUS_SENSE` in the same
overlay — that combination browns out 5 V PAB at `Starting kernel`.

U-Boot `gpios-ark-pab-v3.cmd` / `preboot=run ark_gpios` is still required for
**U-Boot TFTP** (before Linux).

U-Boot env set by the deploy script:

| Variable   | Value                 |
|------------|------------------------|
| `fdt_name` | `modalix-som_16g.dtb`  |
| `dtbos`    | `ark-pab-v3.dtbo`      |

## 3. Fresh eLxr image via sima-cli netboot (USB-C + Ethernet)

Station: SoM USB-C console (FT230X, 115200, **DTR/RTS off**) and Ethernet to the
host USB adapter (`192.168.1.10/24` on **that NIC only** — never on office
`enp5s0`).

**PAB V3** (KSZ8795): copper is **100 Mb/s**; the MAC datapath must stay **1G
GMII** (in-band SGMII). Stock U-Boot programs SS=100M_MII at 100M copper and
sends no frames. After `pab-v3-firstboot.sh` (KSZ GPIOs) and ark-pab-v3 U-Boot
(`0001-xgmac-sgmii-keep-mac-at-1g.patch` + `0002-xgmac-sgmii-xpcs-c37-speed.patch`,
`preboot=run ark_gpios`), USB-C + Ethernet TFTP matches JAJ.

Verified: factory SoM `U-Boot 2025.01-g6c2f563380f1` — `ping 192.168.1.10` alive,
`tftp netboot.scr.uimg` 1145 bytes, sima-cli `f` wrote 5 GiB eMMC
(`elxr-palette-modalix-2.1.2`).

```bash
# Host (IFACE = USB Ethernet dongle, not enp5s0). Close other serial tools.
sudo IFACE=enx9c69d38062de ./scripts/netboot-elxr-pab-v3.sh

# Serial U-Boot (sima$):
run ark_gpios
setenv boot_targets net
setenv ipaddr 192.168.1.20
setenv serverip 192.168.1.10
boot

# host netboot>  (only c / f / q — never U-Boot commands)
# wait until ramdisk SSH is up (U-Boot ICMP is not enough), then:
c
f 192.168.1.20
```

Wait for `Flash completed`, then **power-cycle**. Stock eLxr U-Boot overwrites
the SGMII patches; run `./scripts/pab-v3-firstboot.sh` again (close serial
first). Then DHCP on `end0`:

```bash
sudo nmcli connection modify end0-dhcp connection.autoconnect yes ipv4.method auto
sudo nmcli connection modify end0-static connection.autoconnect no
sudo nmcli connection up end0-dhcp
```

To persist `netcfg=dhcp` in FAT U-Boot env, `fw_printenv` needs
`/boot/uboot.env` via a `fw_env.config` (see `deploy-pab-v3-dtbo.sh`); the
eLxr default config does not point there.

## Architecture notes

### Ethernet switch (KSZ8795)

| Net | SODIMM | Modalix | DT hog |
|-----|--------|---------|--------|
| `SWITCH_RSTn` | 211 | GPIO09 / SIO7[1] | **output-high** (active-low reset) |
| `SW_PMEn` | 216 | GPIO11 / SIO7[3] | **output-high** (PME_N deasserted) |

SoM MAC (`xgmac0`) feeds switch port 1. The KSZ8795CLX copper ports are
**10/100**; the overlay sets PHY `max-speed = <100>` so the Marvell 88E1510 ANs
with the switch. The MAC stays **1G GMII** (`snps,ps-speed = 1000`, in-band
SGMII) — that is not a 1G copper link. External RJ45, payload FFC, and FMU
Ethernet hang off other switch ports. Unmanaged switch operation is enough for
companion Ethernet; SPI1 management is optional (spidev on `nvs_spi1`).

U-Boot (PHY already 100 M FDX on this SoM; keep 1000BASE-T advertising off):

```
mii write 0 4 0x0181
mii write 0 9 0x0000
mii write 0 0 0x3300
mii info
# PHY 0x00: ... 100baseT, FDX
```

### Cameras (2× dual-lane CSI)

Unlike PAB (quad + TCA9546), V3 is **dual IMX219** with **FSUSB42** mux (JAJ-like):

| Connector | Mux | CSI (Modalix) |
|-----------|-----|---------------|
| CAM0 (J28) | sel=0 | **CSI0** `40c0000` |
| CAM1 (J25) | sel=1 | **CSI2** `40c6000` |

- `CAM_MUX_SEL` = SODIMM 130 = GPIO06 = port6 line 6  
- CAM0/CAM1 PWDN = port5 GPIO6/7 held high  
- Without modules, `imx219` I2C NACK is expected  

### Flight controller links (ARKV6S / ARKV6X)

Verified on **Modalix SoM + PAB V3** with ARKV6S:

| Path | Jetson/PAB role | Modalix status |
|------|-----------------|----------------|
| **USB** | `/dev/ttyACM0` (FMU USB) | **Works** — hog `vbus_sense_bootloader` high |
| **Ethernet** | Onboard KSZ8795 to FC eth0 | **Works** — same L2 as SoM `end0`; use DHCP on the FC (`netman` / `net.cfg` `BOOTPROTO=dhcp`) so it shares the LAN with the SoM |
| **UART1 → Telem2** | Companion serial (e.g. Jetson `/dev/ttyTHS1`) | **Does not work on this Modalix SoM revision** |

**UART1 / Telem2:** On this Modalix SoM revision, **UART1 is not usable for the carrier Telem2 path**, so the flight controller’s **Telem2** link to the companion will not come up. Prefer **USB** (MAVLink CDC ACM) and/or **Ethernet** (MAVLink/XRCE-DDS once configured). Do not plan XRCE-DDS or MAVLink over Telem2 for Modalix + PAB V3.

| Net | SODIMM | Modalix | Purpose |
|-----|--------|---------|---------|
| `VBUS_SENSE_BOOTLOADER` | 206 | GPIO07 / SIO6[7] | FMU USB sense (**high**) |
| `FMU_RST_REQ` | 228 | GPIO13 / SIO7[5] | FC reset request (**low** in run) |

Jetson-oriented docs still describe three paths (USB / serial / Ethernet):  
[autopilot connections](https://docs.arkelectron.com/products/flight-controller/jetson-pabs/ark-jetson-pab-carrier-v3/autopilot-connections.md).  
On Modalix, treat **serial/Telem2 as N/A** for this SoM revision.

### Shared Modalix limits

| Interface | Status on PAB V3 + Modalix |
|-----------|----------------------------|
| M.2 Key M NVMe | PCIE0 — works when seated |
| M.2 Key E WiFi | **Unavailable** (no PCIE1) |
| SoM CAN | **N/A** |
| Mini DisplayPort | Jetson DP vs Modalix HDMI mismatch |
| UART1 → FC Telem2 | **Unavailable** on this Modalix SoM revision (use USB and/or Ethernet) |

## Troubleshooting

| Symptom | Check |
|---------|--------|
| `end0` DOWN, no SSH | Overlay not applied (`dtbos=ark-pab-v3.dtbo`) or hog missing — `switch_rst_n` must be out hi in `/sys/kernel/debug/gpio` |
| Still “Just a Jetson” model | `dtbos` still `ark-jaj.dtbo` — redeploy V3 script + reboot |
| No FMU `/dev/ttyACM0` | `vbus_sense_bootloader` high? Micro USB recovery unplugged? |
| No Telem2 / UART1 MAVLink | **Expected** on this Modalix SoM rev — use USB (`ttyACM0`) or Ethernet |
| FC not on LAN | FC still static `192.168.0.4`? Set `BOOTPROTO=dhcp` + `netman update` on the FC |
| Cameras missing | Dual CSI0/CSI2 + FSUSB42; PWDN is not hogged (5 V brownout). Still bring-up. |

## Remaining interface bring-up

Ethernet (KSZ hog + 100 M PHY) and eMMC flash are in this tree. Still to
verify on 5 V PAB next to those KSZ hogs: cameras/CSI (JAJ-proven, not in
this overlay), FUSB, NVMe, payload headers, FC USB/Ethernet.
