// SPDX-License-Identifier: BSD-3-Clause
/*
 * Minimal SafeSPI v2 48-bit probe for Murata SCH16T-K10 on /dev/spidev*.
 * Frame/CRC logic adapted from Murata SCH16T Arduino library (BSD-3-Clause).
 *
 * Usage:
 *   sch16t-spi-test [/dev/spidevB.C] [hz]
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

/* Pre-built 48-bit MOSI frames (TA=0, CRC already in low byte) — Murata lib */
#define REQ_READ_COMP_ID   0x0F0800000092ULL
#define REQ_READ_SN_ID1    0x0F4800000065ULL
#define REQ_READ_SN_ID2    0x0F8800000053ULL
#define REQ_READ_SN_ID3    0x0FC8000000A4ULL
#define REQ_READ_TEMP      0x0408000000B1ULL
#define REQ_READ_STAT_SUM  0x05080000001CULL
#define REQ_SOFTRESET      0x0DA800000AC3ULL

static uint8_t crc8_frame(uint64_t frame)
{
	uint64_t data = frame & 0xFFFFFFFFFF00ULL;
	uint8_t crc = 0xFF;

	for (int i = 47; i >= 0; i--) {
		uint8_t data_bit = (data >> i) & 0x01;
		if (crc & 0x80)
			crc = (uint8_t)((crc << 1) ^ 0x2F) ^ data_bit;
		else
			crc = (uint8_t)((crc << 1) | data_bit);
	}
	return crc;
}

static int crc8_ok(uint64_t frame)
{
	return ((uint8_t)(frame & 0xff)) == crc8_frame(frame);
}

static uint16_t data_u16(uint64_t frame)
{
	return (uint16_t)((frame >> 8) & 0xffff);
}

static int spi_xfer48(int fd, uint64_t mosi, uint64_t *miso_out)
{
	uint8_t buf[6];
	struct spi_ioc_transfer tr;

	for (int i = 0; i < 6; i++)
		buf[i] = (uint8_t)((mosi >> ((5 - i) * 8)) & 0xff);

	memset(&tr, 0, sizeof(tr));
	tr.tx_buf = (unsigned long)buf;
	tr.rx_buf = (unsigned long)buf;
	tr.len = 6;
	tr.delay_usecs = 0;
	tr.speed_hz = 0; /* use device default */
	tr.bits_per_word = 8;
	tr.cs_change = 0;

	if (ioctl(fd, SPI_IOC_MESSAGE(1), &tr) < 0)
		return -errno;

	uint64_t miso = 0;
	for (int i = 0; i < 6; i++)
		miso |= (uint64_t)buf[i] << ((5 - i) * 8);
	*miso_out = miso;
	return 0;
}

static void print_frame(const char *tag, uint64_t mosi, uint64_t miso)
{
	printf("  %-14s MOSI=0x%012llx  MISO=0x%012llx  crc=%s  data16=0x%04x\n",
	       tag, (unsigned long long)mosi, (unsigned long long)miso,
	       crc8_ok(miso) ? "OK" : "BAD", data_u16(miso));
}

int main(int argc, char **argv)
{
	const char *dev = (argc > 1) ? argv[1] : "/dev/spidev0.0";
	uint32_t speed = (argc > 2) ? (uint32_t)strtoul(argv[2], NULL, 0) : 1000000;
	uint8_t mode = SPI_MODE_0;
	uint8_t bits = 8;
	int fd, rc;
	uint64_t miso, miso2;

	fd = open(dev, O_RDWR);
	if (fd < 0) {
		perror(dev);
		return 1;
	}

	if (ioctl(fd, SPI_IOC_WR_MODE, &mode) < 0 ||
	    ioctl(fd, SPI_IOC_WR_BITS_PER_WORD, &bits) < 0 ||
	    ioctl(fd, SPI_IOC_WR_MAX_SPEED_HZ, &speed) < 0) {
		perror("spi setup");
		close(fd);
		return 1;
	}

	printf("SCH16T SafeSPI48 probe on %s @ %u Hz, mode0\n", dev, speed);

	/* Soft reset then settle (Murata recommends ms-scale after reset) */
	rc = spi_xfer48(fd, REQ_SOFTRESET, &miso);
	if (rc) {
		fprintf(stderr, "xfer failed: %s\n", strerror(-rc));
		close(fd);
		return 1;
	}
	print_frame("SOFTRESET", REQ_SOFTRESET, miso);
	usleep(100000);

	/* Pipeline: response to request N arrives in transfer N+1 */
	spi_xfer48(fd, REQ_READ_COMP_ID, &miso);
	print_frame("COMP_ID req", REQ_READ_COMP_ID, miso);
	usleep(500);
	spi_xfer48(fd, REQ_READ_COMP_ID, &miso2);
	print_frame("COMP_ID rsp", REQ_READ_COMP_ID, miso2);

	spi_xfer48(fd, REQ_READ_SN_ID1, &miso);
	usleep(500);
	spi_xfer48(fd, REQ_READ_SN_ID2, &miso);
	print_frame("SN_ID1 rsp", REQ_READ_SN_ID2, miso);
	uint16_t sn1 = data_u16(miso);
	usleep(500);
	spi_xfer48(fd, REQ_READ_SN_ID3, &miso);
	print_frame("SN_ID2 rsp", REQ_READ_SN_ID3, miso);
	uint16_t sn2 = data_u16(miso);
	usleep(500);
	spi_xfer48(fd, REQ_READ_SN_ID3, &miso);
	print_frame("SN_ID3 rsp", REQ_READ_SN_ID3, miso);
	uint16_t sn3 = data_u16(miso);

	spi_xfer48(fd, REQ_READ_STAT_SUM, &miso);
	usleep(500);
	spi_xfer48(fd, REQ_READ_TEMP, &miso);
	print_frame("STAT_SUM rsp", REQ_READ_TEMP, miso);
	usleep(500);
	spi_xfer48(fd, REQ_READ_TEMP, &miso);
	print_frame("TEMP rsp", REQ_READ_TEMP, miso);

	printf("\nSerial (Murata packing): %05d%01X%04X\n",
	       sn2, sn1 & 0xF, sn3);
	printf("COMP_ID data16: 0x%04x  (crc %s)\n",
	       data_u16(miso2), crc8_ok(miso2) ? "OK" : "BAD");

	/* Heuristic pass: any response CRC OK and not all-0 / all-1 */
	int good = 0;
	uint64_t samples[] = { miso2, /* reuse last few via re-read below */ };
	(void)samples;
	if (crc8_ok(miso2) && miso2 != 0 && miso2 != 0xFFFFFFFFFFFFULL)
		good = 1;
	if (crc8_ok(miso) && miso != 0 && miso != 0xFFFFFFFFFFFFULL)
		good = 1;

	if (good)
		printf("\nRESULT: SPI traffic looks live (valid CRC on at least one frame).\n");
	else
		printf("\nRESULT: No valid SCH16T frame CRC — check wiring CS0/SCK/MOSI/MISO, power, and CS.\n");

	close(fd);
	return good ? 0 : 2;
}
