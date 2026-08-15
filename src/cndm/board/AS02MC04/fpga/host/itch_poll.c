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

static int ring_status(int fd, uint64_t *base_out, uint32_t *ctrl_out)
{
    uint32_t lo = 0, hi = 0, ctrl = 0;
    int rc = 0;

    rc |= reg_read(fd, ITCH_REG_RING_BASE_LO, &lo);
    rc |= reg_read(fd, ITCH_REG_RING_BASE_HI, &hi);
    rc |= reg_read(fd, ITCH_REG_RING_CTRL, &ctrl);
    if (rc)
        return -1;

    if (base_out)
        *base_out = ((uint64_t)hi << 32) | lo;
    if (ctrl_out)
        *ctrl_out = ctrl;
    return 0;
}

static int ring_configure(int fd, uint64_t base, int enable)
{
    uint64_t rb_base = 0;
    uint32_t rb_ctrl = 0;

    if (reg_write(fd, ITCH_REG_RING_CTRL, 0)) {
        fprintf(stderr, "ring: disable before reconfigure failed\n");
        return -1;
    }
    if (reg_write(fd, ITCH_REG_RING_BASE_LO, (uint32_t)(base & 0xffffffffu)) ||
        reg_write(fd, ITCH_REG_RING_BASE_HI, (uint32_t)(base >> 32))) {
        fprintf(stderr, "ring: base write failed\n");
        return -1;
    }
    if (reg_write(fd, ITCH_REG_RING_CTRL,
                  enable ? ITCH_RING_CTRL_ENABLE : 0u)) {
        fprintf(stderr, "ring: ctrl write failed\n");
        return -1;
    }

    if (ring_status(fd, &rb_base, &rb_ctrl)) {
        fprintf(stderr, "ring: readback failed\n");
        return -1;
    }
    if (rb_base != base) {
        fprintf(stderr, "ring: base readback 0x%016llx != 0x%016llx\n",
                (unsigned long long)rb_base, (unsigned long long)base);
        return -1;
    }
    if ((rb_ctrl & ITCH_RING_CTRL_ENABLE) != (enable ? ITCH_RING_CTRL_ENABLE : 0u)) {
        fprintf(stderr, "ring: ctrl readback 0x%08x, enable=%d not applied\n",
                rb_ctrl, enable);
        return -1;
    }

    printf("ring base 0x%016llx  %s\n", (unsigned long long)base,
           enable ? "enabled" : "disabled");
    return 0;
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
        "usage: %s <pci-bdf> [--threshold N] [--ring] [--count N]\n"
        "       %s <pci-bdf> --ring-base ADDR [--ring-disable]\n"
        "       %s <pci-bdf> --ring-status\n"
        "\n"
        "ADDR is the device-visible DMA address of the ring buffer, as\n"
        "returned by dma_alloc_coherent in the driver. With an IOMMU active\n"
        "this is an IOVA, not a physical address.\n", p, p, p);
}

int main(int argc, char **argv)
{
    if (argc < 2) { usage(argv[0]); return 1; }
    const char *bdf = argv[1];

    long threshold = -1;
    int ring_mode = 0;
    uint64_t count = 16;
    int have_ring_base = 0, ring_disable = 0, show_ring_status = 0;
    uint64_t ring_base = 0;

    for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "--threshold") && i + 1 < argc)
            threshold = strtol(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "--ring"))
            ring_mode = 1;
        else if (!strcmp(argv[i], "--count") && i + 1 < argc)
            count = strtoull(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "--ring-base") && i + 1 < argc) {
            errno = 0;
            char *end = NULL;
            ring_base = strtoull(argv[++i], &end, 0);
            if (errno || !end || *end) {
                fprintf(stderr, "bad --ring-base value '%s'\n", argv[i]);
                return 1;
            }
            have_ring_base = 1;
        }
        else if (!strcmp(argv[i], "--ring-disable"))
            ring_disable = 1;
        else if (!strcmp(argv[i], "--ring-status"))
            show_ring_status = 1;
        else { usage(argv[0]); return 1; }
    }

    if (have_ring_base && (ring_base & (ITCH_REC_BYTES - 1))) {
        fprintf(stderr, "--ring-base 0x%llx is not %u-byte aligned\n",
                (unsigned long long)ring_base, ITCH_REC_BYTES);
        return 1;
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

    if (have_ring_base) {
        if (ring_configure(fd, ring_base, !ring_disable)) {
            close(fd);
            return 2;
        }
    } else if (ring_disable) {
        uint64_t cur = 0;
        if (ring_status(fd, &cur, NULL) || ring_configure(fd, cur, 0)) {
            close(fd);
            return 2;
        }
    }

    if (show_ring_status) {
        uint64_t base = 0;
        uint32_t ctrl = 0;
        if (ring_status(fd, &base, &ctrl)) {
            close(fd);
            return 2;
        }
        printf("ring base 0x%016llx  ctrl 0x%08x  %s\n",
               (unsigned long long)base, ctrl,
               (ctrl & ITCH_RING_CTRL_ENABLE) ? "enabled" : "disabled");
        if (!ring_mode) {
            close(fd);
            return 0;
        }
    }

    if (have_ring_base && !ring_mode) {
        close(fd);
        return 0;
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
