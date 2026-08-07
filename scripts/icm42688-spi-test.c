// SPDX-License-Identifier: MIT
/*
 * Probe Invensense ICM-42688-P on SPI (JAJ onboard IMU).
 *
 * WHO_AM_I register 0x75 == 0x47
 * SPI: mode 0 or 3, MSB first, CS active low
 * Read: address | 0x80, then one dummy clocked byte for data
 *
 * Usage: icm42688-spi-test [/dev/spidevB.C] [hz]
 */
#include <errno.h>
#include <fcntl.h>
#include <linux/spi/spidev.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define REG_WHO_AM_I	0x75
#define REG_PWR_MGMT0	0x4E
#define REG_ACCEL_DATA	0x1F	/* ACCEL_DATA_X1 … 6 bytes + gyro 6 */
#define WHOAMI_42688P	0x47

static int spi_xfer(int fd, uint8_t *tx, uint8_t *rx, size_t len)
{
	struct spi_ioc_transfer tr;

	memset(&tr, 0, sizeof(tr));
	tr.tx_buf = (unsigned long)tx;
	tr.rx_buf = (unsigned long)rx;
	tr.len = len;
	tr.bits_per_word = 8;
	return ioctl(fd, SPI_IOC_MESSAGE(1), &tr) < 0 ? -errno : 0;
}

static int reg_read(int fd, uint8_t reg, uint8_t *val)
{
	uint8_t tx[2] = { (uint8_t)(reg | 0x80), 0x00 };
	uint8_t rx[2] = { 0, 0 };
	int rc = spi_xfer(fd, tx, rx, 2);

	if (rc)
		return rc;
	*val = rx[1];
	return 0;
}

static int reg_write(int fd, uint8_t reg, uint8_t val)
{
	uint8_t tx[2] = { (uint8_t)(reg & 0x7F), val };
	uint8_t rx[2] = { 0, 0 };

	return spi_xfer(fd, tx, rx, 2);
}

static int reg_read_n(int fd, uint8_t reg, uint8_t *buf, size_t n)
{
	uint8_t tx[1 + 16];
	uint8_t rx[1 + 16];

	if (n > 16)
		return -EINVAL;
	memset(tx, 0, sizeof(tx));
	memset(rx, 0, sizeof(rx));
	tx[0] = reg | 0x80;
	if (spi_xfer(fd, tx, rx, 1 + n))
		return -errno;
	memcpy(buf, rx + 1, n);
	return 0;
}

static int16_t be16(const uint8_t *p)
{
	return (int16_t)((p[0] << 8) | p[1]);
}

int main(int argc, char **argv)
{
	const char *dev = (argc > 1) ? argv[1] : "/dev/spidev1.0";
	uint32_t speed = (argc > 2) ? (uint32_t)strtoul(argv[2], NULL, 0) : 1000000;
	uint8_t modes[] = { SPI_MODE_0, SPI_MODE_3 };
	int fd, rc;
	uint8_t who = 0;

	fd = open(dev, O_RDWR);
	if (fd < 0) {
		perror(dev);
		return 1;
	}

	for (unsigned mi = 0; mi < 2; mi++) {
		uint8_t mode = modes[mi];
		uint8_t bits = 8;

		if (ioctl(fd, SPI_IOC_WR_MODE, &mode) < 0 ||
		    ioctl(fd, SPI_IOC_WR_BITS_PER_WORD, &bits) < 0 ||
		    ioctl(fd, SPI_IOC_WR_MAX_SPEED_HZ, &speed) < 0) {
			perror("spi setup");
			close(fd);
			return 1;
		}

		/* Dummy read to flush; then WHO_AM_I */
		reg_read(fd, REG_WHO_AM_I, &who);
		usleep(1000);
		rc = reg_read(fd, REG_WHO_AM_I, &who);
		printf("mode%u @ %u Hz: WHO_AM_I=0x%02x (expect 0x%02x)%s\n",
		       mode, speed, who, WHOAMI_42688P,
		       rc ? " [xfer err]" : "");
		if (!rc && who == WHOAMI_42688P)
			break;
	}

	if (who != WHOAMI_42688P) {
		printf("FAIL: no ICM-42688-P on %s\n", dev);
		close(fd);
		return 2;
	}

	printf("OK: ICM-42688-P detected on %s\n", dev);

	/*
	 * PWR_MGMT0: enable accel LN + gyro LN
	 * bits [1:0] ACCEL_MODE=11, [3:2] GYRO_MODE=11 → 0x0F
	 */
	if (reg_write(fd, REG_PWR_MGMT0, 0x0F)) {
		perror("PWR_MGMT0");
		close(fd);
		return 1;
	}
	usleep(50000); /* startup */

	for (int i = 0; i < 5; i++) {
		uint8_t raw[12];

		if (reg_read_n(fd, REG_ACCEL_DATA, raw, 12)) {
			perror("sample");
			break;
		}
		printf("sample %d: ax=%6d ay=%6d az=%6d  gx=%6d gy=%6d gz=%6d\n",
		       i,
		       be16(raw + 0), be16(raw + 2), be16(raw + 4),
		       be16(raw + 6), be16(raw + 8), be16(raw + 10));
		usleep(20000);
	}

	close(fd);
	return 0;
}
