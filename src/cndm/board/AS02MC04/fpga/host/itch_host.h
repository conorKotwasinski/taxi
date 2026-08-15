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
#define ITCH_REG_TLAT_MINMAX   0x7C

#define ITCH_REG_THRESHOLD     0x80
#define ITCH_REG_RING_BASE_LO  0x84
#define ITCH_REG_RING_BASE_HI  0x88
#define ITCH_REG_RING_CTRL     0x8C

#define ITCH_RING_CTRL_ENABLE  0x1u

#define ITCH_BOOK_STATUS_LADDER_OVF  0x1u
#define ITCH_BOOK_STATUS_FIFO_OVF    0x2u
#define ITCH_ST_GEN_FRM_SHIFT        2
#define ITCH_ST_EMIT_FRM_SHIFT       12
#define ITCH_ST_CNT_MASK             0x3FFu
#define ITCH_RING_STATUS_OVF         0x1u

#define ITCH_PRICE_SCALE       10000

#define ITCH_RXCLK_NS          3.103

#define ITCH_REC_BYTES  32

#define ITCH_RING_ENTRIES  4096

#endif
