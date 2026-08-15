#ifndef ITCH_BOOK_H
#define ITCH_BOOK_H

#include <stdint.h>

#define ITCH_PRICE_SCALE 10000

struct itch_msg {
    char     type;
    uint64_t ts;
    uint64_t order_ref;
    uint64_t new_order_ref;
    char     side;
    uint32_t shares;
    char     stock[8];
    uint32_t price;
    int      valid;
};

int itch_parse(const uint8_t *body, unsigned len, struct itch_msg *m);

struct itch_book;

struct itch_book *itch_book_new(void);
void itch_book_free(struct itch_book *bk);
void itch_book_apply(struct itch_book *bk, const struct itch_msg *m);
void itch_book_top(struct itch_book *bk, const char stock[8],
                   uint32_t *bid_px, uint32_t *bid_qty,
                   uint32_t *ask_px, uint32_t *ask_qty);

typedef void (*itch_body_cb)(const uint8_t *body, unsigned len, void *ctx);
void itch_iter_stream(const uint8_t *data, unsigned n, itch_body_cb cb, void *ctx);

#endif
