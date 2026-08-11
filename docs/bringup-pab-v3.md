# ARK Jetson PAB V3 + Modalix SoM bring-up

Hardware: [ARK Jetson PAB Carrier V3](https://docs.arkelectron.com/products/flight-controller/jetson-pabs/ark-jetson-pab-carrier-v3)
with a SiMa Modalix SoM in the 260-pin SODIMM, 5 V PAB power (or equivalent),
Ethernet (via onboard **KSZ8795** switch), optional M.2 NVMe, dual CSI cameras.

Default login (SiMa eLxr images): **`sima` / `edgeai`**.

## 1. Console when Ethernet is dead

The V3 carrier routes SoM GbE through a **KSZ8795CLX**. Until the device tree
releases **SWITCH_RSTn** (SODIMM 211 = GPIO09), `end0` stays down and SSH will
not work.

Use the **SoM USB-C** FTDI console (FT230X), **115200 8N1**:

```bash
# host
ls /dev/serial/by-id/
# usb-FTDI_FT230X_Basic_UART_… -> ttyUSB1
picocom -b 115200 /dev/ttyUSB1
```

Deploy the overlay over serial (no eth required):

```bash
./scripts/deploy-pab-v3-dtbo.sh --serial /dev/ttyUSB1 --reboot
```

## 2. Deploy board support (live eMMC, when eth works)

```bash
# From meta-ark-simaai on the host (board at 192.168.7.50)
BOARD=sima@192.168.7.50 PASSWORD=edgeai ./scripts/deploy-pab-v3-dtbo.sh --reboot
```

After reboot:

```bash
cat /proc/device-tree/model
# ARK Jetson PAB V3 with SiMa Modalix SoM

tr '\0' ' ' < /proc/device-tree/compatible; echo
# ark,jetson-pab-v3 simaai,modalix-som simaai,modalix

ip -br a
# end0 … UP … (DHCP or static)

# KSZ8795 out of reset + FMU USB sense
sudo grep -E 'switch_rst|sw_pmen|vbus_sense|fmu_rst' /sys/kernel/debug/gpio
# switch_rst_n out hi
# sw_pmen out hi
# vbus_sense_bootloader out hi
# fmu_rst_req out lo

# Unique ID EEPROM + FUSB
ls /sys/bus/i2c/devices/ | grep -E '0025|0050'
```

U-Boot env set by the deploy script:

| Variable   | Value                 |
|------------|------------------------|
| `fdt_name` | `modalix-som_16g.dtb`  |
| `dtbos`    | `ark-pab-v3.dtbo`      |

## 3. Full image flash (optional)

```bash
./setup.sh
./build.sh ark-pab-v3
./flash.sh ark-pab-v3 --netboot
```

See [bringup-jaj.md](bringup-jaj.md) for netboot / WIC details.

## Architecture notes

### Ethernet switch (KSZ8795)

| Net | SODIMM | Modalix | DT hog |
|-----|--------|---------|--------|
| `SWITCH_RSTn` | 211 | GPIO09 / SIO7[1] | **output-high** (active-low reset) |
| `SW_PMEn` | 216 | GPIO11 / SIO7[3] | **output-high** (PME_N deasserted) |

SoM RGMII (`xgmac0`) feeds switch port 1. External RJ45, payload FFC, and FMU
Ethernet hang off other switch ports. Unmanaged switch operation is enough for
companion GbE; SPI1 management is optional (spidev on `nvs_spi1`).

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
| `end0` DOWN, no SSH | `switch_rst_n` must be **out hi** — redeploy `ark-pab-v3.dtbo` (not JAJ/PAB) |
| Still “Just a Jetson” model | `dtbos` still `ark-jaj.dtbo` — redeploy V3 script + reboot |
| No FMU `/dev/ttyACM0` | `vbus_sense_bootloader` high? Micro USB recovery unplugged? |
| No Telem2 / UART1 MAVLink | **Expected** on this Modalix SoM rev — use USB (`ttyACM0`) or Ethernet |
| FC not on LAN | FC still static `192.168.0.4`? Set `BOOTPROTO=dhcp` + `netman update` on the FC |
| Cameras missing | Dual CSI0/CSI2 + FSUSB42; confirm FFC seating |
