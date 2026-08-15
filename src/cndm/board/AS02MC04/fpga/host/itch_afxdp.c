#define _GNU_SOURCE
#include "itch_book.h"
#include "lat_hist.h"

#include <errno.h>
#include <linux/if_link.h>
#include <net/if.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#include <xdp/xsk.h>

#define NUM_FRAMES  4096
#define FRAME_SIZE  XSK_UMEM__DEFAULT_FRAME_SIZE
#define RX_BATCH    64

struct xsk {
    struct xsk_umem *umem;
    struct xsk_socket *xsk;
    struct xsk_ring_prod fq;
    struct xsk_ring_cons cq;
    struct xsk_ring_cons rx;
    struct xsk_ring_prod tx;
    void *buf;
};

static volatile int stop = 0;
static void on_sig(int s) { (void)s; stop = 1; }

static struct xsk *xsk_open(const char *ifname, int queue) {
    struct xsk *x = calloc(1, sizeof(*x));
    uint64_t bufsz = (uint64_t)NUM_FRAMES * FRAME_SIZE;

    if (posix_memalign(&x->buf, getpagesize(), bufsz)) {
        perror("posix_memalign"); free(x); return NULL;
    }

    struct xsk_umem_config ucfg = {
        .fill_size = XSK_RING_PROD__DEFAULT_NUM_DESCS,
        .comp_size = XSK_RING_CONS__DEFAULT_NUM_DESCS,
        .frame_size = FRAME_SIZE,
        .frame_headroom = XSK_UMEM__DEFAULT_FRAME_HEADROOM,
        .flags = 0,
    };
    if (xsk_umem__create(&x->umem, x->buf, bufsz, &x->fq, &x->cq, &ucfg)) {
        perror("xsk_umem__create"); free(x->buf); free(x); return NULL;
    }

    struct xsk_socket_config scfg = {
        .rx_size = XSK_RING_CONS__DEFAULT_NUM_DESCS,
        .tx_size = XSK_RING_PROD__DEFAULT_NUM_DESCS,
        .libbpf_flags = 0,
        .xdp_flags = XDP_FLAGS_DRV_MODE,
        .bind_flags = XDP_USE_NEED_WAKEUP,
    };
    int rc = xsk_socket__create(&x->xsk, ifname, queue, x->umem,
                                &x->rx, &x->tx, &scfg);
    if (rc) {
        fprintf(stderr, "xsk_socket__create(drv): %s -- retrying skb mode\n",
                strerror(-rc));
        scfg.xdp_flags = XDP_FLAGS_SKB_MODE;
        rc = xsk_socket__create(&x->xsk, ifname, queue, x->umem,
                                &x->rx, &x->tx, &scfg);
        if (rc) {
            fprintf(stderr, "xsk_socket__create(skb): %s\n", strerror(-rc));
            xsk_umem__delete(x->umem); free(x->buf); free(x); return NULL;
        }
    }

    uint32_t idx;
    unsigned n = xsk_ring_prod__reserve(&x->fq,
                     XSK_RING_PROD__DEFAULT_NUM_DESCS, &idx);
    for (unsigned i = 0; i < n; i++)
        *xsk_ring_prod__fill_addr(&x->fq, idx++) = i * FRAME_SIZE;
    xsk_ring_prod__submit(&x->fq, n);

    return x;
}

static void xsk_close(struct xsk *x) {
    if (!x) return;
    if (x->xsk) xsk_socket__delete(x->xsk);
    if (x->umem) xsk_umem__delete(x->umem);
    free(x->buf);
    free(x);
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <ifname> [n_msgs] [queue]\n", argv[0]);
        return 1;
    }
    const char *ifname = argv[1];
    uint64_t want = argc > 2 ? strtoull(argv[2], NULL, 0) : 100000;
    int queue = argc > 3 ? atoi(argv[3]) : 0;

    signal(SIGINT, on_sig);

    struct xsk *x = xsk_open(ifname, queue);
    if (!x) return 1;

    struct stats s;
    memset(&s, 0, sizeof(s));
    s.bk = itch_book_new();

    struct pollfd pfd = { .fd = xsk_socket__fd(x->xsk), .events = POLLIN };

    fprintf(stderr, "AF_XDP on %s queue %d, target=%llu msgs\n",
            ifname, queue, (unsigned long long)want);

    while (!stop && s.msgs < want) {
        uint32_t idx_rx = 0;
        unsigned rcvd = xsk_ring_cons__peek(&x->rx, RX_BATCH, &idx_rx);
        if (!rcvd) {
            if (xsk_ring_prod__needs_wakeup(&x->fq))
                poll(&pfd, 1, 100);
            continue;
        }

        uint32_t idx_fq = 0;
        unsigned reserved = xsk_ring_prod__reserve(&x->fq, rcvd, &idx_fq);
        while (reserved < rcvd)
            reserved = xsk_ring_prod__reserve(&x->fq, rcvd, &idx_fq);

        for (unsigned i = 0; i < rcvd; i++) {
            const struct xdp_desc *d = xsk_ring_cons__rx_desc(&x->rx, idx_rx++);
            uint64_t addr = d->addr;
            uint32_t len = d->len;
            uint8_t *pkt = xsk_umem__get_data(x->buf, addr);

            s.t_rx_ns = now_ns();
            if (len > L2_HDR)
                itch_iter_stream(pkt + L2_HDR, len - L2_HDR, stats_on_body, &s);

            *xsk_ring_prod__fill_addr(&x->fq, idx_fq++) =
                xsk_umem__extract_addr(addr);
        }

        xsk_ring_prod__submit(&x->fq, rcvd);
        xsk_ring_cons__release(&x->rx, rcvd);
    }

    stats_report(&s, "AF_XDP", ifname,
                 "AF_XDP RX-ring consume (userspace) -> book updated");

    itch_book_free(s.bk);
    xsk_close(x);
    return 0;
}
