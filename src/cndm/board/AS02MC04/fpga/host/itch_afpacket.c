#define _GNU_SOURCE
#include "itch_book.h"
#include "lat_hist.h"

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <arpa/inet.h>
#include <linux/if_ether.h>
#include <linux/if_packet.h>
#include <linux/net_tstamp.h>
#include <linux/sockios.h>
#include <net/if.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/uio.h>

#define MAX_FRAME 2048

static int enable_hw_rx_ts(int fd, const char *ifname) {
    struct ifreq ifr;
    struct hwtstamp_config cfg;
    memset(&ifr, 0, sizeof(ifr));
    memset(&cfg, 0, sizeof(cfg));
    strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);
    cfg.tx_type = HWTSTAMP_TX_OFF;
    cfg.rx_filter = HWTSTAMP_FILTER_ALL;
    ifr.ifr_data = (void *)&cfg;
    if (ioctl(fd, SIOCSHWTSTAMP, &ifr) < 0) {
        fprintf(stderr, "SIOCSHWTSTAMP (%s): %s\n", ifname, strerror(errno));
        return -1;
    }
    return 0;
}

static void usage(const char *p) {
    fprintf(stderr,
        "usage: %s <ifname> [n_msgs] [--hw]\n"
        "  default: SOFTWARE RX timestamp (CLOCK_REALTIME, same domain as\n"
        "           book-update) -- clean same-clock measurement.\n"
        "  --hw:    RAW HARDWARE RX timestamp (NIC PHC domain). ONLY valid if\n"
        "           phc2sys is disciplining the PHC to CLOCK_REALTIME, else the\n"
        "           start/end clocks differ and latencies are meaningless.\n",
        p);
}

int main(int argc, char **argv) {
    if (argc < 2) { usage(argv[0]); return 1; }
    const char *ifname = argv[1];
    uint64_t want = 100000;
    int use_hw = 0;
    for (int i = 2; i < argc; i++) {
        if (strcmp(argv[i], "--hw") == 0) use_hw = 1;
        else want = strtoull(argv[i], NULL, 0);
    }

    int fd = socket(AF_PACKET, SOCK_RAW, htons(ETH_P_ALL));
    if (fd < 0) { perror("socket(AF_PACKET)"); return 1; }

    unsigned ifidx = if_nametoindex(ifname);
    if (!ifidx) { perror("if_nametoindex"); return 1; }
    struct sockaddr_ll sll;
    memset(&sll, 0, sizeof(sll));
    sll.sll_family = AF_PACKET;
    sll.sll_protocol = htons(ETH_P_ALL);
    sll.sll_ifindex = ifidx;
    if (bind(fd, (struct sockaddr *)&sll, sizeof(sll)) < 0) {
        perror("bind"); return 1;
    }

    int hw_ok = 0;
    if (use_hw) {
        hw_ok = enable_hw_rx_ts(fd, ifname) == 0;
        if (!hw_ok) {
            fprintf(stderr, "hw timestamps unavailable; falling back to software\n");
            use_hw = 0;
        }
    }
    int so_flags = SOF_TIMESTAMPING_RX_SOFTWARE | SOF_TIMESTAMPING_SOFTWARE;
    if (hw_ok)
        so_flags |= SOF_TIMESTAMPING_RX_HARDWARE | SOF_TIMESTAMPING_RAW_HARDWARE;
    if (setsockopt(fd, SOL_SOCKET, SO_TIMESTAMPING, &so_flags, sizeof(so_flags)) < 0) {
        perror("SO_TIMESTAMPING"); return 1;
    }
    if (use_hw)
        fprintf(stderr, "WARNING: --hw uses raw PHC clock; valid ONLY under phc2sys\n");

    struct stats s;
    memset(&s, 0, sizeof(s));
    s.bk = itch_book_new();

    uint8_t frame[MAX_FRAME];
    char ctrl[256];
    struct iovec iov = { frame, sizeof(frame) };
    struct msghdr mh;

    fprintf(stderr, "listening on %s, rx_ts=%s, target=%llu msgs\n",
            ifname, use_hw ? "raw-hardware(PHC)" : "software(REALTIME)",
            (unsigned long long)want);

    while (s.msgs < want) {
        memset(&mh, 0, sizeof(mh));
        mh.msg_iov = &iov;
        mh.msg_iovlen = 1;
        mh.msg_control = ctrl;
        mh.msg_controllen = sizeof(ctrl);
        ssize_t n = recvmsg(fd, &mh, 0);
        if (n < 0) { if (errno == EINTR) continue; perror("recvmsg"); break; }
        if (n <= L2_HDR) continue;

        s.t_rx_ns = 0;
        for (struct cmsghdr *cm = CMSG_FIRSTHDR(&mh); cm; cm = CMSG_NXTHDR(&mh, cm)) {
            if (cm->cmsg_level == SOL_SOCKET && cm->cmsg_type == SO_TIMESTAMPING) {
                struct timespec *tv = (struct timespec *)CMSG_DATA(cm);
                struct timespec *pick = use_hw ? &tv[2] : &tv[0];
                if (pick->tv_sec == 0 && pick->tv_nsec == 0) pick = &tv[0];
                s.t_rx_ns = (uint64_t)pick->tv_sec * 1000000000ull + pick->tv_nsec;
            }
        }

        itch_iter_stream(frame + L2_HDR, (unsigned)(n - L2_HDR), stats_on_body, &s);
    }

    char boundary[128];
    snprintf(boundary, sizeof(boundary),
             "NIC RX %s timestamp -> book updated (userspace)",
             use_hw ? "raw-hardware(PHC)" : "software(REALTIME softirq)");
    stats_report(&s, "AF_PACKET", ifname, boundary);

    itch_book_free(s.bk);
    close(fd);
    return 0;
}
