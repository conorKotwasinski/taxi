# SPDX-License-Identifier: MIT
CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra

all: itch_poll itch_book_test itch_ring_test itch_ring_consume

itch_poll: itch_poll.c itch_host.h
	$(CC) $(CFLAGS) -o $@ itch_poll.c

itch_book_test: itch_book_test.c itch_book.c itch_book.h
	$(CC) $(CFLAGS) -o $@ itch_book_test.c itch_book.c

itch_ring_test: itch_ring_test.c itch_ring_consumer.h itch_ring.h
	$(CC) $(CFLAGS) -o $@ itch_ring_test.c

itch_ring_consume: itch_ring_consume.c itch_ring_consumer.h itch_ring.h
	$(CC) $(CFLAGS) -o $@ itch_ring_consume.c

# Linux only (AF_PACKET, net_tstamp) -- build on the FPGA host
itch_afpacket: itch_afpacket.c itch_book.c itch_book.h lat_hist.h
	$(CC) $(CFLAGS) -o $@ itch_afpacket.c itch_book.c

# Linux only, needs libbpf/libxdp (apt install libbpf-dev libxdp-dev)
itch_afxdp: itch_afxdp.c itch_book.c itch_book.h lat_hist.h
	$(CC) $(CFLAGS) -o $@ itch_afxdp.c itch_book.c -lxdp -lbpf

check: itch_book_test itch_ring_test itch_ring_consume itch_poll
	./itch_book_test
	./itch_ring_test

clean:
	rm -f itch_poll itch_book_test itch_afpacket itch_afxdp itch_ring_test itch_ring_consume

.PHONY: all check clean
