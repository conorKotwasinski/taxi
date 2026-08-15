#ifndef ITCH_RING_H
#define ITCH_RING_H

#include <stdint.h>

#define ITCH_REC_BYTES     32
#define ITCH_RING_ENTRIES  4096
#define ITCH_PRICE_SCALE   10000

#define ITCH_REC_FLAG_BID_EMPTY  0x01
#define ITCH_REC_FLAG_ASK_EMPTY  0x02
#define ITCH_REC_FLAG_VALID      0x04

struct itch_delta_rec {
    uint64_t ts;
    uint32_t bid_px;
    uint32_t ask_px;
    uint32_t bid_qty;
    uint32_t ask_qty;
    uint16_t sym;
    uint16_t flags;
    uint32_t seq;
};

static inline void itch_rec_parse(const uint8_t *p, struct itch_delta_rec *r) {
    r->ts      = (uint64_t)p[0] | (uint64_t)p[1] << 8 | (uint64_t)p[2] << 16 |
                 (uint64_t)p[3] << 24 | (uint64_t)p[4] << 32 | (uint64_t)p[5] << 40 |
                 (uint64_t)p[6] << 48 | (uint64_t)p[7] << 56;
    r->bid_px  = (uint32_t)p[8]  | (uint32_t)p[9] << 8  | (uint32_t)p[10] << 16 | (uint32_t)p[11] << 24;
    r->ask_px  = (uint32_t)p[12] | (uint32_t)p[13] << 8 | (uint32_t)p[14] << 16 | (uint32_t)p[15] << 24;
    r->bid_qty = (uint32_t)p[16] | (uint32_t)p[17] << 8 | (uint32_t)p[18] << 16 | (uint32_t)p[19] << 24;
    r->ask_qty = (uint32_t)p[20] | (uint32_t)p[21] << 8 | (uint32_t)p[22] << 16 | (uint32_t)p[23] << 24;
    r->sym     = (uint16_t)p[24] | (uint16_t)p[25] << 8;
    r->flags   = (uint16_t)p[27];
    r->seq     = (uint32_t)p[28] | (uint32_t)p[29] << 8 | (uint32_t)p[30] << 16 | (uint32_t)p[31] << 24;
}

#endif
