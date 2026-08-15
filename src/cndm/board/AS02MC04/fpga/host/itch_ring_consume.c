#define _GNU_SOURCE
#include "itch_ring_consumer.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

static const char *sym_name(uint16_t s) {
    static const char *names[] = { "AAPL", "MSFT", "NVDA", "AMZN" };
    return s < 4 ? names[s] : "????";
}

static void usage(const char *p) {
    fprintf(stderr,
        "usage: %s <ring-file> [entries]\n"
        "  <ring-file>  mmap'd DMA ring buffer (the host region the FPGA writes)\n"
        "  [entries]    ring entry count (default %d)\n",
        p, ITCH_RING_ENTRIES);
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    if (argc < 2) { usage(argv[0]); return 1; }
    const char *path = argv[1];
    uint32_t entries = argc > 2 ? (uint32_t)strtoul(argv[2], NULL, 0)
                                : ITCH_RING_ENTRIES;

    size_t bytes = (size_t)entries * ITCH_REC_BYTES;
    int fd = open(path, O_RDONLY);
    if (fd < 0) { perror("open ring"); return 1; }

    const uint8_t *base = mmap(NULL, bytes, PROT_READ, MAP_SHARED, fd, 0);
    if (base == MAP_FAILED) { perror("mmap"); close(fd); return 1; }

    struct itch_ring_consumer c;
    itch_ring_init(&c, base, entries);

    struct itch_delta_rec r;
    uint64_t idle = 0;

    for (;;) {
        int st = itch_ring_poll(&c, &r);
        if (st == ITCH_RING_FRESH) {
            idle = 0;
            printf("seq %-8u %-4s bid %.4f x %-8u ask %.4f x %-8u\n",
                   r.seq, sym_name(r.sym),
                   (double)r.bid_px / ITCH_PRICE_SCALE, r.bid_qty,
                   (double)r.ask_px / ITCH_PRICE_SCALE, r.ask_qty);
        } else if (st == ITCH_RING_LAPPED) {
            fprintf(stderr, "[lapped] ring wrapped, %llu records missed, resync at seq %u\n",
                    (unsigned long long)c.lapped, c.expected_seq);
        } else {
            struct timespec ts = { 0, 100000 };
            nanosleep(&ts, NULL);
            if (++idle % 100000 == 0)
                fprintf(stderr, "[idle] consumed=%llu lapped=%llu\n",
                        (unsigned long long)c.consumed, (unsigned long long)c.lapped);
        }
    }

    munmap((void *)base, bytes);
    close(fd);
    return 0;
}
