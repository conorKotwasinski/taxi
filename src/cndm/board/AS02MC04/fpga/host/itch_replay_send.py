#!/usr/bin/env python3
import argparse
import os
import socket
import struct
import sys
import time

ETH_HDR = 14


def frames(path, mtu, limit, per_frame=0):
    data = open(path, 'rb').read()
    off = 0
    n = len(data)
    cur = bytearray()
    held = 0
    cap = mtu - ETH_HDR
    sent = 0
    while off + 2 <= n:
        (mlen,) = struct.unpack_from('>H', data, off)
        if mlen == 0 or off + 2 + mlen > n:
            break
        rec = data[off:off + 2 + mlen]
        if len(cur) + len(rec) > cap:
            yield bytes(cur)
            cur = bytearray()
            held = 0
        cur += rec
        held += 1
        off += 2 + mlen
        sent += 1
        if per_frame and held >= per_frame:
            yield bytes(cur)
            cur = bytearray()
            held = 0
        if limit and sent >= limit:
            break
    if cur:
        yield bytes(cur)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('ifname')
    ap.add_argument('binfile')
    ap.add_argument('-n', '--limit', type=int, default=0)
    ap.add_argument('--mtu', type=int, default=1500)
    ap.add_argument('--gap-us', type=float, default=200.0)
    ap.add_argument('--msgs-per-frame', type=int, default=0)
    ap.add_argument('--dst', default='ff:ff:ff:ff:ff:ff')
    ap.add_argument('--ethertype', type=lambda x: int(x, 0), default=0x88b5)
    a = ap.parse_args()

    dst = bytes(int(b, 16) for b in a.dst.split(':'))
    s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW)
    s.bind((a.ifname, 0))
    src = s.getsockname()[4][:6]
    hdr = dst + src + struct.pack('>H', a.ethertype)

    gap = a.gap_us / 1e6
    nf = 0
    nb = 0
    t0 = time.perf_counter()
    for payload in frames(a.binfile, a.mtu, a.limit, a.msgs_per_frame):
        pkt = hdr + payload
        if len(pkt) < 60:
            pkt += b'\x00' * (60 - len(pkt))
        s.send(pkt)
        nf += 1
        nb += len(pkt)
        if gap > 0:
            t = time.perf_counter() + gap
            while time.perf_counter() < t:
                pass
    dt = time.perf_counter() - t0
    print(f'sent {nf} frames, {nb} bytes in {dt:.3f}s '
          f'({nb * 8 / dt / 1e6:.1f} Mbit/s)')
    return 0


if __name__ == '__main__':
    if os.geteuid() != 0:
        sys.stderr.write('must run as root (AF_PACKET raw socket)\n')
        sys.exit(1)
    sys.exit(main())
