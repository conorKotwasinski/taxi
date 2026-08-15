#include "itch_ring_consumer.h"
#include <stdio.h>
#include <string.h>

#define ENTRIES 8
static uint8_t ring[ENTRIES * ITCH_REC_BYTES];

static void put(uint32_t slot, uint32_t seq, uint32_t bid_px, uint32_t bid_qty,
                uint16_t sym) {
    uint8_t *p = ring + slot * ITCH_REC_BYTES;
    uint8_t flags = ITCH_REC_FLAG_VALID | ITCH_REC_FLAG_ASK_EMPTY;
    if (bid_qty == 0)
        flags |= ITCH_REC_FLAG_BID_EMPTY;
    memset(p, 0, ITCH_REC_BYTES);
    p[8]  = bid_px; p[9] = bid_px >> 8; p[10] = bid_px >> 16; p[11] = bid_px >> 24;
    p[16] = bid_qty; p[17] = bid_qty >> 8; p[18] = bid_qty >> 16; p[19] = bid_qty >> 24;
    p[24] = sym; p[25] = sym >> 8;
    p[27] = flags;
    p[28] = seq; p[29] = seq >> 8; p[30] = seq >> 16; p[31] = seq >> 24;
}

int main(void) {
    struct itch_ring_consumer c;
    struct itch_delta_rec r;
    int fails = 0;

    itch_ring_init(&c, ring, ENTRIES);
    memset(ring, 0, sizeof(ring));

    if (itch_ring_poll(&c, &r) != ITCH_RING_EMPTY) { printf("FAIL empty-start\n"); fails++; }

    for (uint32_t s = 0; s < 5; s++)
        put(s, s, 1500000 + s, 100 + s, 0);

    for (uint32_t s = 0; s < 5; s++) {
        int st = itch_ring_poll(&c, &r);
        if (st != ITCH_RING_FRESH || r.seq != s || r.bid_qty != 100 + s) {
            printf("FAIL fresh seq=%u st=%d qty=%u\n", s, st, r.bid_qty); fails++;
        }
        if (r.flags != (ITCH_REC_FLAG_VALID | ITCH_REC_FLAG_ASK_EMPTY)) {
            printf("FAIL flags seq=%u got=0x%x want=0x%x\n", s, r.flags,
                   ITCH_REC_FLAG_VALID | ITCH_REC_FLAG_ASK_EMPTY); fails++;
        }
    }

    if (itch_ring_poll(&c, &r) != ITCH_RING_EMPTY) { printf("FAIL empty-after\n"); fails++; }
    if (c.consumed != 5) { printf("FAIL consumed=%llu\n", (unsigned long long)c.consumed); fails++; }

    put(5, 20, 1600000, 999, 1);
    int st = itch_ring_poll(&c, &r);
    if (st != ITCH_RING_LAPPED) { printf("FAIL lap not detected st=%d\n", st); fails++; }
    if (c.expected_seq != 20) { printf("FAIL resync exp=%u\n", c.expected_seq); fails++; }

    if (itch_ring_poll(&c, &r) != ITCH_RING_FRESH || r.seq != 20 || r.bid_qty != 999) {
        printf("FAIL resume-after-lap\n"); fails++;
    }

    put(6, 21, 0, 0, 2);
    st = itch_ring_poll(&c, &r);
    if (st != ITCH_RING_FRESH || r.seq != 21 || r.sym != 2 ||
        r.bid_px != 0 || r.ask_px != 0 || r.bid_qty != 0 || r.ask_qty != 0) {
        printf("FAIL book-drain record rejected st=%d seq=%u\n", st, r.seq); fails++;
    }
    if (r.flags != (ITCH_REC_FLAG_VALID | ITCH_REC_FLAG_BID_EMPTY | ITCH_REC_FLAG_ASK_EMPTY)) {
        printf("FAIL book-drain flags got=0x%x\n", r.flags); fails++;
    }

    {
        struct itch_ring_consumer z;
        uint8_t zero_ring[ITCH_REC_BYTES];
        memset(zero_ring, 0, sizeof(zero_ring));
        itch_ring_init(&z, zero_ring, 1);
        if (itch_ring_poll(&z, &r) != ITCH_RING_EMPTY) {
            printf("FAIL zeroed slot consumed as seq-0 record\n"); fails++;
        }
    }

    {
        struct itch_ring_consumer d;
        uint8_t drain_ring[ITCH_REC_BYTES];
        memset(drain_ring, 0, sizeof(drain_ring));
        drain_ring[27] = ITCH_REC_FLAG_VALID | ITCH_REC_FLAG_BID_EMPTY |
                         ITCH_REC_FLAG_ASK_EMPTY;
        itch_ring_init(&d, drain_ring, 1);
        if (itch_ring_poll(&d, &r) != ITCH_RING_FRESH || r.seq != 0) {
            printf("FAIL first record lost: seq=0 with drained book\n"); fails++;
        }
    }

    printf("consumed=%llu lapped=%llu\n",
           (unsigned long long)c.consumed, (unsigned long long)c.lapped);
    printf("%s\n", fails ? "SELF-TEST FAILED" : "self-test OK");
    return fails ? 1 : 0;
}
