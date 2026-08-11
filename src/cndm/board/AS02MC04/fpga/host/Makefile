# SPDX-License-Identifier: MIT
CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra

itch_poll: itch_poll.c itch_host.h
	$(CC) $(CFLAGS) -o $@ itch_poll.c

clean:
	rm -f itch_poll

.PHONY: clean
