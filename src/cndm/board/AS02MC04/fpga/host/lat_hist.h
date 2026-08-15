#ifndef LAT_HIST_H
#define LAT_HIST_H

#include "itch_book.h"
#include <stdint.h>
#include <stdio.h>
#include <time.h>

#define L2_HDR    14
#define HIST_BINS 4096
#define HIST_UNIT 50

struct stats {
    struct itch_book *bk;
    uint64_t msgs;
    uint64_t recorded;
    uint64_t hist[HIST_BINS];
    uint64_t over;
    uint64_t min_ns, max_ns, sum_ns;
    uint64_t t_rx_ns;
};

static inline uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + ts.tv_nsec;
}

static inline void record_lat(struct stats *s, uint64_t lat_ns) {
    s->sum_ns += lat_ns;
    if (s->recorded == 0 || lat_ns < s->min_ns) s->min_ns = lat_ns;
    if (lat_ns > s->max_ns) s->max_ns = lat_ns;
    unsigned bin = lat_ns / HIST_UNIT;
    if (bin < HIST_BINS) s->hist[bin]++; else s->over++;
    s->recorded++;
}

static void stats_on_body(const uint8_t *body, unsigned len, void *ctx) {
    struct stats *s = ctx;
    struct itch_msg m;
    if (!itch_parse(body, len, &m)) return;
    itch_book_apply(s->bk, &m);
    uint64_t done = now_ns();
    if (s->t_rx_ns && done > s->t_rx_ns) record_lat(s, done - s->t_rx_ns);
    s->msgs++;
}

static inline uint64_t pctl(struct stats *s, double p) {
    uint64_t target = (uint64_t)(p * (double)s->recorded);
    uint64_t acc = 0;
    for (unsigned b = 0; b < HIST_BINS; b++) {
        acc += s->hist[b];
        if (acc >= target) return (uint64_t)b * HIST_UNIT + HIST_UNIT / 2;
    }
    return s->max_ns;
}

static inline void stats_report(struct stats *s, const char *path,
                                const char *ifname, const char *boundary) {
    double mean = s->recorded ? (double)s->sum_ns / s->recorded : 0;
    printf("\n=== %s baseline (%s) ===\n", path, ifname);
    printf("messages    %llu (timestamped %llu)\n",
           (unsigned long long)s->msgs, (unsigned long long)s->recorded);
    printf("boundary    %s\n", boundary);
    printf("latency ns  min=%llu mean=%.0f max=%llu\n",
           (unsigned long long)s->min_ns, mean, (unsigned long long)s->max_ns);
    printf("            p50=%llu p90=%llu p99=%llu p99.9=%llu (over-range=%llu)\n",
           (unsigned long long)pctl(s, 0.50), (unsigned long long)pctl(s, 0.90),
           (unsigned long long)pctl(s, 0.99), (unsigned long long)pctl(s, 0.999),
           (unsigned long long)s->over);
}

#endif
