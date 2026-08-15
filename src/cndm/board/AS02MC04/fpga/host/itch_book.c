#include "itch_book.h"
#include <stdlib.h>
#include <string.h>

static uint16_t be16(const uint8_t *b) { return (uint16_t)((b[0] << 8) | b[1]); }
static uint32_t be32(const uint8_t *b) {
    return ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) |
           ((uint32_t)b[2] << 8) | b[3];
}
static uint64_t be64(const uint8_t *b) {
    uint64_t v = 0;
    for (int i = 0; i < 8; i++) v = (v << 8) | b[i];
    return v;
}
static uint64_t be48(const uint8_t *b) {
    uint64_t v = 0;
    for (int i = 0; i < 6; i++) v = (v << 8) | b[i];
    return v;
}

int itch_parse(const uint8_t *body, unsigned len, struct itch_msg *m)
{
    memset(m, 0, sizeof(*m));
    if (len < 1) return 0;
    m->type = (char)body[0];
    if (len >= 11) m->ts = be48(body + 5);

    switch (m->type) {
    case 'A':
    case 'F':
        if (len < 36) return 0;
        m->order_ref = be64(body + 11);
        m->side = (char)body[19];
        m->shares = be32(body + 20);
        memcpy(m->stock, body + 24, 8);
        m->price = be32(body + 32);
        m->valid = 1;
        return 1;
    case 'E':
    case 'C':
        if (len < 31) return 0;
        m->order_ref = be64(body + 11);
        m->shares = be32(body + 19);
        m->valid = 1;
        return 1;
    case 'X':
        if (len < 23) return 0;
        m->order_ref = be64(body + 11);
        m->shares = be32(body + 19);
        m->valid = 1;
        return 1;
    case 'D':
        if (len < 19) return 0;
        m->order_ref = be64(body + 11);
        m->valid = 1;
        return 1;
    case 'U':
        if (len < 35) return 0;
        m->order_ref = be64(body + 11);
        m->new_order_ref = be64(body + 19);
        m->shares = be32(body + 27);
        m->price = be32(body + 31);
        m->valid = 1;
        return 1;
    default:
        return 0;
    }
}

struct order {
    uint64_t ref;
    char     stock[8];
    char     side;
    uint32_t price;
    uint32_t qty;
    int      used;
};

struct level {
    char     stock[8];
    char     side;
    uint32_t price;
    int64_t  qty;
    int      used;
};

#define ORDER_CAP 262144
#define LEVEL_CAP 65536

struct itch_book {
    struct order *orders;
    struct level *levels;
};

static uint64_t hash_ref(uint64_t r) {
    r ^= r >> 33; r *= 0xff51afd7ed558ccdULL;
    r ^= r >> 33; r *= 0xc4ceb9fe1a85ec53ULL;
    r ^= r >> 33;
    return r;
}

static struct order *order_find(struct itch_book *bk, uint64_t ref, int alloc) {
    uint64_t h = hash_ref(ref) & (ORDER_CAP - 1);
    for (unsigned i = 0; i < ORDER_CAP; i++) {
        struct order *o = &bk->orders[(h + i) & (ORDER_CAP - 1)];
        if (o->used && o->ref == ref) return o;
        if (!o->used) {
            if (!alloc) return NULL;
            o->used = 1; o->ref = ref;
            return o;
        }
    }
    return NULL;
}

static void order_del(struct order *o) { o->used = 0; }

static uint64_t hash_level(const char stock[8], char side, uint32_t price) {
    uint64_t h = 1469598103934665603ULL;
    for (int i = 0; i < 8; i++) { h ^= (uint8_t)stock[i]; h *= 1099511628211ULL; }
    h ^= (uint8_t)side; h *= 1099511628211ULL;
    h ^= price; h *= 1099511628211ULL;
    return h;
}

static struct level *level_find(struct itch_book *bk, const char stock[8],
                                char side, uint32_t price, int alloc) {
    uint64_t h = hash_level(stock, side, price) & (LEVEL_CAP - 1);
    for (unsigned i = 0; i < LEVEL_CAP; i++) {
        struct level *l = &bk->levels[(h + i) & (LEVEL_CAP - 1)];
        if (l->used && l->side == side && l->price == price &&
            memcmp(l->stock, stock, 8) == 0) return l;
        if (!l->used) {
            if (!alloc) return NULL;
            l->used = 1; l->side = side; l->price = price;
            memcpy(l->stock, stock, 8); l->qty = 0;
            return l;
        }
    }
    return NULL;
}

static void add_qty(struct itch_book *bk, const char stock[8], char side,
                    uint32_t price, int64_t dq) {
    struct level *l = level_find(bk, stock, side, price, 1);
    if (!l) return;
    l->qty += dq;
    if (l->qty <= 0) l->used = 0;
}

struct itch_book *itch_book_new(void) {
    struct itch_book *bk = calloc(1, sizeof(*bk));
    bk->orders = calloc(ORDER_CAP, sizeof(struct order));
    bk->levels = calloc(LEVEL_CAP, sizeof(struct level));
    return bk;
}

void itch_book_free(struct itch_book *bk) {
    if (!bk) return;
    free(bk->orders); free(bk->levels); free(bk);
}

void itch_book_apply(struct itch_book *bk, const struct itch_msg *m) {
    if (!m->valid) return;
    switch (m->type) {
    case 'A':
    case 'F': {
        struct order *o = order_find(bk, m->order_ref, 1);
        if (!o) return;
        memcpy(o->stock, m->stock, 8);
        o->side = m->side; o->price = m->price; o->qty = m->shares;
        add_qty(bk, m->stock, m->side, m->price, m->shares);
        break;
    }
    case 'E':
    case 'C':
    case 'X': {
        struct order *o = order_find(bk, m->order_ref, 0);
        if (!o) return;
        uint32_t take = m->shares < o->qty ? m->shares : o->qty;
        o->qty -= take;
        add_qty(bk, o->stock, o->side, o->price, -(int64_t)take);
        if (o->qty == 0) order_del(o);
        break;
    }
    case 'D': {
        struct order *o = order_find(bk, m->order_ref, 0);
        if (!o) return;
        add_qty(bk, o->stock, o->side, o->price, -(int64_t)o->qty);
        order_del(o);
        break;
    }
    case 'U': {
        struct order *o = order_find(bk, m->order_ref, 0);
        if (!o) return;
        char stock[8]; char side; 
        memcpy(stock, o->stock, 8); side = o->side;
        add_qty(bk, o->stock, o->side, o->price, -(int64_t)o->qty);
        order_del(o);
        struct order *n = order_find(bk, m->new_order_ref, 1);
        if (!n) return;
        memcpy(n->stock, stock, 8);
        n->side = side; n->price = m->price; n->qty = m->shares;
        add_qty(bk, stock, side, m->price, m->shares);
        break;
    }
    default:
        break;
    }
}

void itch_book_top(struct itch_book *bk, const char stock[8],
                   uint32_t *bid_px, uint32_t *bid_qty,
                   uint32_t *ask_px, uint32_t *ask_qty) {
    uint32_t bpx = 0, apx = 0; int64_t bq = 0, aq = 0;
    for (unsigned i = 0; i < LEVEL_CAP; i++) {
        struct level *l = &bk->levels[i];
        if (!l->used || memcmp(l->stock, stock, 8) != 0) continue;
        if (l->side == 'B') {
            if (bpx == 0 || l->price > bpx) { bpx = l->price; bq = l->qty; }
        } else {
            if (apx == 0 || l->price < apx) { apx = l->price; aq = l->qty; }
        }
    }
    *bid_px = bpx; *bid_qty = (uint32_t)bq;
    *ask_px = apx; *ask_qty = (uint32_t)aq;
}

void itch_iter_stream(const uint8_t *data, unsigned n, itch_body_cb cb, void *ctx) {
    unsigned o = 0;
    while (o + 2 <= n) {
        uint16_t mlen = be16(data + o);
        o += 2;
        if (o + mlen > n) break;
        cb(data + o, mlen, ctx);
        o += mlen;
    }
}
