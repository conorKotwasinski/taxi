#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>

#include "itch_host.h"

static int vpd_open(const char *bdf)
{
    char path[256];
    snprintf(path, sizeof(path), "/sys/bus/pci/devices/%s/vpd", bdf);
    int fd = open(path, O_RDWR);
    if (fd < 0)
        fprintf(stderr, "open %s: %s\n", path, strerror(errno));
    return fd;
}

static int reg_read(int fd, uint32_t off, uint32_t *val)
{
    uint32_t v;
    ssize_t n = pread(fd, &v, sizeof(v), off);
    if (n != (ssize_t)sizeof(v))
        return -1;
    *val = v;
    return 0;
}

static int reg_write(int fd, uint32_t off, uint32_t val)
{
    ssize_t n = pwrite(fd, &val, sizeof(val), off);
    return (n == (ssize_t)sizeof(val)) ? 0 : -1;
}

static void print_book(int fd)
{
    uint32_t bpx = 0, bq = 0, apx = 0, aq = 0, st = 0;
    reg_read(fd, ITCH_REG_BID_PX,  &bpx);
    reg_read(fd, ITCH_REG_BID_QTY, &bq);
    reg_read(fd, ITCH_REG_ASK_PX,  &apx);
    reg_read(fd, ITCH_REG_ASK_QTY, &aq);
    reg_read(fd, ITCH_REG_BOOK_STATUS, &st);

    printf("bid %.4f x %-8u   ask %.4f x %-8u   %s%s\n",
           (double)bpx / ITCH_PRICE_SCALE, bq,
           (double)apx / ITCH_PRICE_SCALE, aq,
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
