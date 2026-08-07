# ARK Jetson PAB + Modalix SoM bring-up

Hardware: [ARK Jetson PAB Carrier](https://arkelectron.com/product/ark-jetson-pab-carrier/)
with a SiMa Modalix SoM in the 260-pin SODIMM, 5 V PAB power (or equivalent),
Ethernet, optional M.2 NVMe, optional IMX219 on the four CSI FFCs.

Default login (SiMa eLxr images): **`sima` / `edgeai`**.

## 1. Deploy board support (live eMMC)

The SoM usually already runs a Modalix eLxr image. Carrier support is a **DT
overlay** (`ark-pab.dtbo`), not a full L4T-style reflash:

```bash
# From meta-ark-simaai on the host (board at 192.168.7.50)
BOARD=sima@192.168.7.50 PASSWORD=edgeai ./scripts/deploy-pab-dtbo.sh --reboot
```

After reboot:

```bash
cat /proc/device-tree/model
# ARK Jetson PAB with SiMa Modalix SoM

tr '\0' ' ' < /proc/device-tree/compatible; echo
# ark,jetson-pab simaai,modalix-som simaai,modalix

# Camera I2C mux
i2cdetect -y 4    # expect 0x70 = TCA9546 when CAM_I2C is up
ls /sys/bus/i2c/devices/ | grep -E '0070|0010'

# SPI0 header
ls -l /dev/spidev0.0

# NVMe (Key M)
lsblk; lspci | grep -i non-volatile
```

U-Boot env set by the deploy script:

| Variable   | Value                 |
|------------|------------------------|
| `fdt_name` | `modalix-som_16g.dtb`  |
| `dtbos`    | `ark-pab.dtbo`         |

## 2. Full image flash (optional)

Same path as JAJ — Modalix boots from **on-SoM eMMC**:

```bash
./setup.sh                 # once
./build.sh ark-pab
./flash.sh ark-pab --netboot
```

See [bringup-jaj.md](bringup-jaj.md) for netboot / WIC details.

## Architecture notes

### Cameras (4× IMX219)

| Connector | Mux ch | CSI (Modalix) | Notes |
|-----------|--------|---------------|--------|
| CAM0 (J28) | 0 | CSI0 `40c0000` | 2-lane |
| CAM1 (J25) | 1 | CSI1 `40c3000` | 2-lane |
| CAM2 (J29) | 2 | CSI2 `40c6000` | 2-lane |
| CAM3 (J27) | 3 | CSI3 `40c9000` | 2-lane |

- I2C mux: **TCA9546APWR @ 0x70** on CAM_I2C (`i2c52`), not the JAJ FSUSB42.
- Jetson product default: IMX219 Quad overlay (`ark_jetson_kernel` products/PAB).
- Without modules, `imx219` I2C NACK (`-121`) is expected.

### Shared with JAJ / Modalix

| Interface | Status on PAB + Modalix |
|-----------|-------------------------|
| M.2 Key M NVMe | PCIE0 — works when seated |
| M.2 Key E WiFi | **Unavailable** (no PCIE1) |
| SPI0 | `nvs_spi0` → `/dev/spidev0.0` |
| I2C0 / I2C1 | Enabled; FUSB @ 0x25; ID EEPROM @ 0x50 |
| UART1 / UART0 | USB-C console + headers (same gold finger as JAJ) |
| SoM CAN | **N/A** (no CAN on Modalix) |
| Mini DisplayPort | **Not native** — PAB is Jetson DP; Modalix is HDMI on those pins |

### PAB-specific connectors

Autopilot PAB bus, telem/GPS/CAN/PWM headers are on the **FMU** side of the
carrier, not the Modalix SoM. Companion-computer work is Ethernet/UART/SPI/I2C/CSI
as above; flight-controller flash is separate (PX4/ArduPilot on ARKV6X / ARKV6S).

### FMU USB (ARKV6S / ARKV6X on `lsusb`)

Jetson ↔ flight controller USB is a board-to-board path (`USB_FMU_*` via a mux
shared with the Micro USB recovery port). For the FMU to enumerate:

1. **`VBUS_SENSE_BOOTLOADER` high** — SODIMM **206** = Modalix **GPIO07** =
   SIO6[7] (`&port6` line 7). Hogged **output-high** in `ark-pab.dtbo` (same role
   as Jetson MB1 pinmux / ARK docs “Autopilot Connections”).
2. **No Micro USB cable** on the recovery port — while that cable is plugged in,
   the mux disconnects the FMU from the SoM; unplug and reboot if needed.
3. Expect **`lsusb`** to show the ARK FC (and usually `/dev/ttyACM0`).

Also hogged high at boot:

| Net | SODIMM | Modalix | Purpose |
|-----|--------|---------|---------|
| `VBUS_SENSE_BOOTLOADER` | 206 | GPIO07 / SIO6[7] | FMU USB sense (drive **high**) |
| `USB2_USBSS0_VBUS_EN` | 218 | GPIO12 / SIO7[4] | USB-A J33 load switch (drive **high**) |
| `FMU_RST_REQ` | 228 | GPIO13 / SIO7[5] | FC reset request (drive **low**; high asserts reset path) |

```bash
# After reboot, hogs should show in debugfs:
sudo cat /sys/kernel/debug/gpio | grep -E 'vbus|usbss0'
lsusb
ls -l /dev/ttyACM*
```

## Troubleshooting

| Symptom | Check |
|---------|--------|
| Still “Just a Jetson” model | `dtbos` still `ark-jaj.dtbo` — redeploy PAB script + reboot |
| No `0x70` on CAM I2C | Power, FFC seating, `i2c52` status, TCA9546 reset |
| No ARKV6S / no `/dev/ttyACM0` | `vbus_sense_bootloader` hog high? Micro USB unplugged? FMU seated and powered? |
| Key E empty | Expected on Modalix |
| Mini-DP no video | Expected — HDMI vs DP mismatch (see prior PAB notes) |
