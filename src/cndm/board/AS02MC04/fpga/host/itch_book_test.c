#include "itch_book.h"
#include <stdio.h>
#include <string.h>
#include <arpa/inet.h>

static uint8_t buf[65536];
static unsigned len;

static void put16(uint16_t v) { buf[len++] = v >> 8; buf[len++] = v & 0xff; }
static void put32(unsigned off, uint32_t v) {
    buf[off] = v >> 24; buf[off+1] = v >> 16; buf[off+2] = v >> 8; buf[off+3] = v;
}
static void put64(unsigned off, uint64_t v) {
    for (int i = 0; i < 8; i++) buf[off + i] = (v >> (56 - 8*i)) & 0xff;
}

static unsigned msg_len(char t) {
    switch (t) {
    case 'A': case 'F': return 36;
    case 'E': case 'C': return 31;
    case 'X': return 23;
    case 'D': return 19;
    case 'U': return 35;
    }
    return 0;
}

static void emit(char type, uint64_t ref, char side, uint32_t shares,
                 const char *stock, uint32_t price, uint64_t new_ref) {
    unsigned ml = msg_len(type);
    put16((uint16_t)ml);
    unsigned base = len;
    memset(buf + base, 0, ml);
    buf[base] = (uint8_t)type;
    if (type == 'A' || type == 'F') {
        put64(base + 11, ref);
        buf[base + 19] = (uint8_t)side;
        put32(base + 20, shares);
        memset(buf + base + 24, ' ', 8);
        memcpy(buf + base + 24, stock, strlen(stock));
        put32(base + 32, price);
    } else if (type == 'E' || type == 'C') {
        put64(base + 11, ref);
        put32(base + 19, shares);
    } else if (type == 'X') {
        put64(base + 11, ref);
        put32(base + 19, shares);
    } else if (type == 'D') {
        put64(base + 11, ref);
    } else if (type == 'U') {
        put64(base + 11, ref);
        put64(base + 19, new_ref);
        put32(base + 27, shares);
        put32(base + 31, price);
    }
    len += ml;
}

struct ctx { struct itch_book *bk; };
static void on_body(const uint8_t *body, unsigned l, void *c) {
    struct ctx *x = c;
    struct itch_msg m;
    if (itch_parse(body, l, &m)) itch_book_apply(x->bk, &m);
}

int main(void) {
    emit('A', 1, 'B', 100, "AAPL", 1500000, 0);
    emit('A', 2, 'B', 200, "AAPL", 1499900, 0);
    emit('A', 3, 'S', 150, "AAPL", 1500100, 0);
    emit('E', 1, 0, 40, NULL, 0, 0);
    emit('A', 4, 'B', 300, "AAPL", 1500000, 0);
    emit('D', 3, 0, 0, NULL, 0, 0);
    emit('X', 2, 0, 50, NULL, 0, 0);
    emit('U', 1, 0, 500, NULL, 1500050, 5);

    struct itch_book *bk = itch_book_new();
    struct ctx x = { bk };
    itch_iter_stream(buf, len, on_body, &x);

    char stock[8]; memset(stock, ' ', 8); memcpy(stock, "AAPL", 4);
    uint32_t bpx, bq, apx, aq;
    itch_book_top(bk, stock, &bpx, &bq, &apx, &aq);

    printf("bid %u x %u   ask %u x %u\n", bpx, bq, apx, aq);
    int ok = (bpx == 1500050 && bq == 500 && apx == 0 && aq == 0);
    printf("%s\n", ok ? "self-test OK" : "SELF-TEST FAILED");
    itch_book_free(bk);
    return ok ? 0 : 1;
}
