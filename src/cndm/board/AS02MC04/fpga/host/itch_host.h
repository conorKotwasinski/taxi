#ifndef ITCH_HOST_H
#define ITCH_HOST_H

#include <stdint.h>

#define ITCH_VPD_REG_BASE      0x4000

#define ITCH_REG_BID_PX        0x60
#define ITCH_REG_BID_QTY       0x64
#define ITCH_REG_ASK_PX        0x68
#define ITCH_REG_ASK_QTY       0x6C
#define ITCH_REG_BOOK_STATUS   0x70
#define ITCH_REG_LAT_MINMAX    0x74   
#define ITCH_REG_LAT_LAST      0x78   

#define ITCH_REG_THRESHOLD     0x80
#define ITCH_REG_RING_BASE_LO  0x84
#define ITCH_REG_RING_BASE_HI  0x88
#define ITCH_REG_RING_CTRL     0x8C

#define ITCH_RING_CTRL_ENABLE  0x1u

#define ITCH_BOOK_STATUS_LADDER_OVF  0x1u
#define ITCH_BOOK_STATUS_FIFO_OVF    0x2u
#define ITCH_RING_STATUS_OVF         0x1u

#define ITCH_PRICE_SCALE       10000

#define ITCH_RXCLK_NS          3.103

#pragma pack(push, 1)
struct itch_delta {
    uint64_t ts_ns;
    uint32_t bid_px;
    uint32_t ask_px;
    uint32_t bid_qty;
    uint32_t ask_qty;
    uint16_t sym;
    uint16_t flags;
    uint32_t seq;
};
#pragma pack(pop)

#define ITCH_REC_BYTES  32
_Static_assert(sizeof(struct itch_delta) == ITCH_REC_BYTES,
               "itch_delta must be exactly 32 bytes");

#define ITCH_RING_ENTRIES  4096

#endif
