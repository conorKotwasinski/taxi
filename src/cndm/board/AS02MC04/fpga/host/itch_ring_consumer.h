#ifndef ITCH_RING_CONSUMER_H
#define ITCH_RING_CONSUMER_H

#include "itch_ring.h"
#include <stdint.h>

enum itch_ring_status {
    ITCH_RING_EMPTY   = 0,
    ITCH_RING_FRESH   = 1,
    ITCH_RING_LAPPED  = 2,
};

struct itch_ring_consumer {
    const uint8_t *base;
    uint32_t entries;
    uint32_t cons_slot;
    uint32_t expected_seq;
    int started;
    uint64_t consumed;
    uint64_t lapped;
};

static inline void itch_ring_init(struct itch_ring_consumer *c,
                                  const uint8_t *base, uint32_t entries) {
    c->base = base;
    c->entries = entries;
    c->cons_slot = 0;
    c->expected_seq = 0;
    c->started = 0;
    c->consumed = 0;
    c->lapped = 0;
}

static inline int itch_ring_poll(struct itch_ring_consumer *c,
                                 struct itch_delta_rec *out) {
    const uint8_t *p = c->base + (uint64_t)c->cons_slot * ITCH_REC_BYTES;
    struct itch_delta_rec r;
    itch_rec_parse(p, &r);

    if (!(r.flags & ITCH_REC_FLAG_VALID))
        return ITCH_RING_EMPTY;

    if (!c->started) {
        c->expected_seq = r.seq;
        c->started = 1;
    }

    if (r.seq == c->expected_seq) {
        *out = r;
        c->cons_slot = (c->cons_slot + 1 == c->entries) ? 0 : c->cons_slot + 1;
        c->expected_seq++;
        c->consumed++;
        return ITCH_RING_FRESH;
    }

    if ((int32_t)(r.seq - c->expected_seq) > 0) {
        c->lapped += (r.seq - c->expected_seq);
        c->expected_seq = r.seq;
        return ITCH_RING_LAPPED;
    }

    return ITCH_RING_EMPTY;
}

#endif
