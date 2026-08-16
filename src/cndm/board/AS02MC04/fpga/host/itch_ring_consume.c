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
        "usage: %s <ring-file> [entries] [--region N] [--count N] [--size-from SYSFS]\n"
        "  <ring-file>  mmap'd DMA ring buffer, e.g. /dev/cndm0 or a dump file\n"
        "  [entries]    ring entry count (default %d)\n"
        "  --region N   cndm mmap region index (default 0; the driver's\n"
        "               record ring is the index the ioctl reports)\n"
        "  --count N    consume N records then exit (for fixtures/tests);\n"
        "               also exits on the first empty slot\n"
        "  --size-from  read entry count from a rec_ring_size sysfs file\n"
        "               (authoritative; overrides [entries])\n",
        p, ITCH_RING_ENTRIES);
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    if (argc < 2) { usage(argv[0]); return 1; }
    const char *path = argv[1];
    uint32_t entries = ITCH_RING_ENTRIES;
    unsigned region = 0;
    uint64_t want = 0;
    const char *size_from = NULL;

    for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "--region") && i + 1 < argc)
            region = (unsigned)strtoul(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "--count") && i + 1 < argc)
            want = strtoull(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "--size-from") && i + 1 < argc)
            size_from = argv[++i];
        else if (argv[i][0] != '-')
            entries = (uint32_t)strtoul(argv[i], NULL, 0);
        else { usage(argv[0]); return 1; }
    }

    if (size_from) {
        FILE *sf = fopen(size_from, "r");
        unsigned long sz = 0;
        if (!sf || fscanf(sf, "%lu", &sz) != 1 || sz == 0 || sz % ITCH_REC_BYTES) {
            fprintf(stderr, "could not read valid ring size from %s\n", size_from);
            if (sf) fclose(sf);
            return 1;
        }
        fclose(sf);
        entries = (uint32_t)(sz / ITCH_REC_BYTES);
    }

    if (!entries) { fprintf(stderr, "entries must be non-zero\n"); return 1; }

    size_t bytes = (size_t)entries * ITCH_REC_BYTES;
    off_t offset = (off_t)((uint64_t)region << 40);
    int fd = open(path, O_RDWR);

    if (fd < 0 && (errno == EACCES || errno == EROFS || errno == EPERM))
        fd = open(path, O_RDONLY);
    if (fd < 0) { perror("open ring"); return 1; }

    fprintf(stderr, "ring %s: %u entries, %zu bytes, region %u, offset 0x%llx\n",
            path, entries, bytes, region, (unsigned long long)offset);

    const uint8_t *base = mmap(NULL, bytes, PROT_READ, MAP_SHARED, fd, offset);
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
            if (want && c.consumed >= want)
                break;
        } else if (st == ITCH_RING_LAPPED) {
            fprintf(stderr, "[lapped] ring wrapped, %llu records missed, resync at seq %u\n",
                    (unsigned long long)c.lapped, c.expected_seq);
        } else {
            if (want) break;
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
