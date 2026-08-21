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

# Unique ID EEPROM (I2C1 0x50) + FUSB (I2C0 0x25)
ls /sys/bus/i2c/devices/ | grep -E '0025|0050'
sudo i2ctransfer -y 1 w1@0x58 0x80 r16   # 128-bit factory ID
```

KSZ `SWITCH_RSTn` / `SW_PMEn` are **Linux gpio-hogs on port7**
(`ark-pab-v3.dtbo`). `FMU_RST_REQ` is named `fmu_rst_req` (SIO7 line 5)
so userspace can pulse it; it is **not** hogged. `gpio70` is already enabled in
`modalix-som_16g.dtb`. `VBUS_SENSE_BOOTLOADER` is a **port6** hog
(SIO6[7] output-high) so the ARKV6X enumerates on USB at boot. Do **not**
hog CAM PWDN or FUSB `INT_N` (SIO6[0]) in the same overlay — those plus
KSZ brown out 5 V PAB at `Starting kernel`.

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

Unlike PAB (quad + TCA9546), V3 is **dual IMX219** with **FSUSB42** mux.
I2C/PWDN match JAJ; **CSI lanes do not**. Jetson PAB V3 dual overlay is
CSI0+CSI2 (`serial_a` + `serial_c`); JAJ is CSI1+CSI2 (`serial_b` + `serial_c`).

| Connector | Mux | CSI (Modalix) | After overlay |
|-----------|-----|---------------|---------------|
| CAM0 (J28) | sel=0 | **CSI0** `40c0000` | `imx219 6-0010` → `/dev/video0` |
| CAM1 (J25) | sel=1 | **CSI2** `40c6000` | `imx219 5-0010` → `/dev/video1` |

- `CAM_MUX_SEL` = SODIMM 130 = GPIO06 = port6 line 6 (`i2c-mux-gpio`)
- CAM0/CAM1 PWDN = port5 GPIO6/7 via **imx219 `reset-gpios`** (released high
  at sensor probe). Do **not** gpio-hog these next to the KSZ hogs — that
  browns out 5 V PAB at `Starting kernel`.
- Verified: both sensors `Detected IMX219`; libcamera Modalix IPA streams
  3280×2464 NV12 at ~15 fps on both (`cam -l`, `cam -c 1 --capture=3`).
  Without modules, I2C NACK (`-121`) is expected.

```bash
cam -l
# 1: (imx219 6-0010)   # CAM0 / CSI0
# 2: (imx219 5-0010)   # CAM1 / CSI2
cam -c 1 --capture=3 --file=/tmp/cam0-#.bin
cam -c 2 --capture=3 --file=/tmp/cam1-#.bin
```

### Flight controller links (ARKV6S / ARKV6X)

Verified on **Modalix SoM + PAB V3** with ARKV6X (`3185:0039`):

| Path | Jetson/PAB role | Modalix status |
|------|-----------------|----------------|
| **USB** | `/dev/ttyACM0` (FMU USB) | **Works** — hog `vbus_sense_bootloader` high |
| **Ethernet** | Onboard KSZ8795 to FC eth0 | **Works** — FC default `192.168.0.4`; ICMP ~0.3 ms and MAVLink v2 UDP **14550** from the SoM. Office DHCP on `end0` is a different subnet (`192.168.7.0/24` here), so add a secondary address on the SoM (`ip addr add 192.168.0.1/24 dev end0`) or set the FC to DHCP (`netman` / `net.cfg` `BOOTPROTO=dhcp`) |
| **UART1 → Telem2** | Companion serial (e.g. Jetson `/dev/ttyTHS1`) | **Does not work on this Modalix SoM revision** |

**UART1 / Telem2:** On this Modalix SoM revision, **UART1 is not usable for the carrier Telem2 path**, so the flight controller’s **Telem2** link to the companion will not come up. Prefer **USB** (MAVLink CDC ACM) and/or **Ethernet** (MAVLink/XRCE-DDS once configured). Do not plan XRCE-DDS or MAVLink over Telem2 for Modalix + PAB V3.

| Net | SODIMM | Modalix | Purpose |
|-----|--------|---------|---------|
| `VBUS_SENSE_BOOTLOADER` | 206 | GPIO07 / SIO6[7] | FMU USB sense (**high**) |
| `FMU_RST_REQ` | 228 | GPIO13 / SIO7[5] | FC reset request — gpio `fmu_rst_req`, pulse **high** then low (carrier pulldown holds idle low) |

Jetson-oriented docs still describe three paths (USB / serial / Ethernet):  
[autopilot connections](https://docs.arkelectron.com/products/flight-controller/jetson-pabs/ark-jetson-pab-carrier-v3/autopilot-connections.md).  
On Modalix, treat **serial/Telem2 as N/A** for this SoM revision.

### Shared Modalix limits

| Interface | Status on PAB V3 + Modalix |
|-----------|----------------------------|
| M.2 Key M NVMe | **Works** — PCIE0 `nvme0n1` (e.g. Samsung 980 512 G) |
| M.2 Key E WiFi | **Unavailable** (no PCIE1) |
| USB-A | **Not on PAB V3** (no J33 / no `USB2_USBSS0_VBUS_EN`) |
| Board ID EEPROM | **Works** — I2C1 AT24CSW010 `0x50` / unique ID `0x58` word `0x80` |
| SoM CAN | **N/A** |
| Micro HDMI (J14) | **Works** — SM768 on PCIE2 (`card0-HDMI-A-1`). Cable at boot lights the panel. After idle with **no keyboard/mouse**, LightDM/X DPMS turns the monitor Off (`dpms=Off`, `fb0/blank=4`); `ark-hdmi-unblank.sh` + X `-s 0 -dpms` keep it awake. Mini-DP on this carrier is still Jetson DP vs Modalix HDMI TMDS — use the Micro HDMI jack. |
| UART1 → FC Telem2 | **Unavailable** on this Modalix SoM revision (use USB and/or Ethernet) |

## Troubleshooting

| Symptom | Check |
|---------|--------|
| `end0` DOWN, no SSH | Overlay not applied (`dtbos=ark-pab-v3.dtbo`) or hog missing — `switch_rst_n` must be out hi in `/sys/kernel/debug/gpio` |
| ARK-OS FMU reset no-op / EBUSY | Overlay must **not** hog `fmu_rst_req` (SIO7 line 5). `reset_fmu_fast.py` pulses that line high for 100 ms. gpiochips need `root:gpio` 0660 (`99-ark-gpio.rules`) |
| Still “Just a Jetson” model | `dtbos` still `ark-jaj.dtbo` — redeploy V3 script + reboot |
| No FMU `/dev/ttyACM0` | `vbus_sense_bootloader` high? Micro USB recovery unplugged? |
| No Telem2 / UART1 MAVLink | **Expected** on this Modalix SoM rev — use USB (`ttyACM0`) or Ethernet |
| FC not on LAN | Default FC is static `192.168.0.4` on the KSZ, not the office DHCP subnet. From the SoM: `ip addr add 192.168.0.1/24 dev end0` then `ping 192.168.0.4` / UDP 14550. Or DHCP the FC. |
| Cameras missing | `dmesg \| grep imx219` — expect Detected; mux `i2cmux`, **CSI0+CSI2** (not JAJ CSI1). NACK without modules. |
| HDMI blank after plug / no KB/mouse | LightDM DPMS 10 min. `cat /sys/class/drm/card0-HDMI-A-1/dpms` Off + `fb0/blank=4` → `sudo /usr/local/sbin/ark-hdmi-unblank.sh`. Persist via deploy (X `-s 0 -dpms`). |

## Remaining interface bring-up

Ethernet (KSZ hog + 100 M PHY), FUSB301 on i2c-0 `0x25`, and eMMC flash
are in this tree.

**USB-C SuperSpeed** is the **carrier** USB-C (TUSB73x0 `usb2` 5000M), same
as JAJ — not the SoM USB-C debug FT230X (USB2 UART). Stock FUSB is SNK
(`MODES=0x04`); `ark-jaj-usb.service` with `ROLE_POLICY=prefer-host` programs
DRP try-SRC and keeps the SS hub out of autosuspend. INT_N hog next to KSZ
resets 5 V PAB; I2C programming is enough.

**FMU USB** is default: overlay hog `vbus_sense_bootloader` (SIO6[7]
output-high) → `lsusb` `3185:0039 ARK ARK FMU v6X.x`, `/dev/ttyACM0`.

**M.2 NVMe** (PCIE0) enumerates with the stock SoM DTB; overlay keeps
`pcie0_rc` okay. Example: `144d:a809` Samsung 980, `nvme0n1` 476.9 G (may
still hold a prior Jetson partition table).

**Cameras:** overlay mux + **CSI0+CSI2** (PAB V3 lanes, not JAJ CSI1+CSI2)
+ `reset-gpios`. Both IMX219 bind; libcamera Modalix ISP captures 3280×2464
NV12 at ~15 fps (`cam -c 1` / `cam -c 2`).

**Board ID EEPROM:** I2C1 AT24CSW010. Overlay binds `eeprom@50` (`1-0050`).
Factory unique ID (this board): `i2ctransfer -y 1 w1@0x58 0x80 r16` →
`11 30 44 00 84 10 08 52 e4 87 a2 80 a2 80 00 51`. User memory is 0xFF
until programmed. No INA238 on V3 (JAJ-only).

**FMU Ethernet:** KSZ L2 to the ARKV6X. Factory FC address is
`192.168.0.4` (`aa:f3:2b:e5:28:e5`). SoM office DHCP does not put the
companion on that subnet — add `192.168.0.1/24` on `end0` (or DHCP the
FC). Verified: ping 0.3 ms, MAVLink v2 HEARTBEAT on UDP 14550 (sysid 1).
USB CDC `/dev/ttyACM0` still works in parallel.

PAB V3 has **no USB-A**.

Still to verify: payload headers (I2C/SPI/UART/Ethernet FFC).
