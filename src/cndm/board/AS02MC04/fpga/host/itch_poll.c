#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>

#include "itch_host.h"

#define VPD_CAP      0xB0
#define VPD_ADDR_OFF (VPD_CAP + 2)
#define VPD_DATA_OFF (VPD_CAP + 4)

static int vpd_open(const char *bdf)
{
    char path[256];
    snprintf(path, sizeof(path), "/sys/bus/pci/devices/%s/config", bdf);
    int fd = open(path, O_RDWR);
    if (fd < 0)
        fprintf(stderr, "open %s: %s\n", path, strerror(errno));
    return fd;
}

static int reg_read(int fd, uint32_t off, uint32_t *val)
{
    uint16_t addr = (uint16_t)((ITCH_VPD_REG_BASE + off) & 0x7FFF);
    uint16_t cur;

    if (pwrite(fd, &addr, sizeof(addr), VPD_ADDR_OFF) != (ssize_t)sizeof(addr)) {
        fprintf(stderr, "vpd addr write failed: %s\n", strerror(errno));
        return -1;
    }
    for (int i = 0; i < 400; i++) {
        if (pread(fd, &cur, sizeof(cur), VPD_ADDR_OFF) != (ssize_t)sizeof(cur))
            return -1;
        if (cur & 0x8000)
            return pread(fd, val, sizeof(*val), VPD_DATA_OFF)
                   == (ssize_t)sizeof(*val) ? 0 : -1;
        usleep(500);
    }
    fprintf(stderr, "vpd read 0x%02x timed out\n", off);
    return -1;
}

static int reg_write(int fd, uint32_t off, uint32_t val)
{
    uint16_t addr = (uint16_t)(((ITCH_VPD_REG_BASE + off) & 0x7FFF) | 0x8000);

    if (pwrite(fd, &val, sizeof(val), VPD_DATA_OFF) != (ssize_t)sizeof(val))
        return -1;
    return pwrite(fd, &addr, sizeof(addr), VPD_ADDR_OFF)
           == (ssize_t)sizeof(addr) ? 0 : -1;
}

static void print_book(int fd)
{
    uint32_t bpx = 0, bq = 0, apx = 0, aq = 0, st = 0;
    uint32_t lat_mm = 0, lat_last = 0, tlat_mm = 0;
    int rc = 0;
    rc |= reg_read(fd, ITCH_REG_BID_PX,  &bpx);
    rc |= reg_read(fd, ITCH_REG_BID_QTY, &bq);
    rc |= reg_read(fd, ITCH_REG_ASK_PX,  &apx);
    rc |= reg_read(fd, ITCH_REG_ASK_QTY, &aq);
    rc |= reg_read(fd, ITCH_REG_BOOK_STATUS, &st);
    rc |= reg_read(fd, ITCH_REG_LAT_MINMAX, &lat_mm);
    rc |= reg_read(fd, ITCH_REG_LAT_LAST, &lat_last);
    rc |= reg_read(fd, ITCH_REG_TLAT_MINMAX, &tlat_mm);
    if (rc) {
        fprintf(stderr, "VPD register reads failed\n");
        exit(2);
    }

    unsigned lmin = lat_mm & 0xffff, lmax = (lat_mm >> 16) & 0xffff;
    unsigned gen  = (st >> ITCH_ST_GEN_FRM_SHIFT)  & ITCH_ST_CNT_MASK;
    unsigned emit = (st >> ITCH_ST_EMIT_FRM_SHIFT) & ITCH_ST_CNT_MASK;
    unsigned tmin = tlat_mm & 0xffff, tmax = (tlat_mm >> 16) & 0xffff;
    printf("bid %.4f x %-8u   ask %.4f x %-8u   "
           "book(ns) last=%.0f %u-%u  tick2trig(ns) %u-%u  gen=%u emit=%u  %s%s\n",
           (double)bpx / ITCH_PRICE_SCALE, bq,
           (double)apx / ITCH_PRICE_SCALE, aq,
           (lat_last & 0xffff) * ITCH_RXCLK_NS,
           (unsigned)(lmin * ITCH_RXCLK_NS), (unsigned)(lmax * ITCH_RXCLK_NS),
           (unsigned)(tmin * ITCH_RXCLK_NS), (unsigned)(tmax * ITCH_RXCLK_NS),
           gen, emit,
           (st & ITCH_BOOK_STATUS_LADDER_OVF) ? "[ladder-ovf] " : "",
           (st & ITCH_BOOK_STATUS_FIFO_OVF)   ? "[fifo-ovf] "   : "");
}

static void ring_consume(volatile struct itch_delta *ring, uint32_t entries,
                         uint64_t max_records)
{
    uint32_t rd = 0;
    uint32_t expect_seq = 0;
    uint64_t got = 0;

    while (got < max_records) {
        volatile struct itch_delta *r = &ring[rd];
        uint32_t seq = r->seq;

        if (seq != expect_seq) {
            if (seq > expect_seq) {

                fprintf(stderr, "ring: dropped %u records (seq jump %u->%u)\n",
                        seq - expect_seq, expect_seq, seq);
                expect_seq = seq;
            } else {

                continue;
            }
        }

        struct itch_delta rec;
        memcpy(&rec, (const void *)r, sizeof(rec));

        printf("[%u] sym=%u bid %.4f x %u  ask %.4f x %u  ts=%llu%s%s\n",
               rec.seq, rec.sym,
               (double)rec.bid_px / ITCH_PRICE_SCALE, rec.bid_qty,
               (double)rec.ask_px / ITCH_PRICE_SCALE, rec.ask_qty,
               (unsigned long long)rec.ts_ns,
               (rec.flags & 1) ? " [no-bid]" : "",
               (rec.flags & 2) ? " [no-ask]" : "");

        got++;
        expect_seq++;
        rd = (rd + 1u) % entries;
    }
}

static void usage(const char *p)
{
    fprintf(stderr,
        "usage: %s <pci-bdf> [--threshold N] [--ring] [--count N]\n", p);
}

int main(int argc, char **argv)
{
    if (argc < 2) { usage(argv[0]); return 1; }
    const char *bdf = argv[1];

    long threshold = -1;
    int ring_mode = 0;
    uint64_t count = 16;

    for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "--threshold") && i + 1 < argc)
            threshold = strtol(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "--ring"))
            ring_mode = 1;
        else if (!strcmp(argv[i], "--count") && i + 1 < argc)
            count = strtoull(argv[++i], NULL, 0);
        else { usage(argv[0]); return 1; }
    }

    int fd = vpd_open(bdf);
    if (fd < 0)
        return 1;

    if (threshold >= 0) {
        if (reg_write(fd, ITCH_REG_THRESHOLD, (uint32_t)threshold) == 0)
            printf("set imbalance threshold = %ld\n", threshold);
        else
            fprintf(stderr, "threshold write failed\n");
    }

    if (!ring_mode) {

        for (uint64_t i = 0; i < count; i++) {
            print_book(fd);
            usleep(100000);
        }
        close(fd);
        return 0;
    }

    fprintf(stderr,
        "ring mode requires the DMA delta ring (step 2b-2) and a driver-\n"
        "allocated coherent buffer; see the sequence in the source. The\n"
        "ring_consume() reader is ready for that buffer.\n");
    (void)ring_consume;
    close(fd);
    return 0;
}
