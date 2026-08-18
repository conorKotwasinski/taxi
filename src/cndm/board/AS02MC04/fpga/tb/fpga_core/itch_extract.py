#!/usr/bin/env python3
import argparse
import gzip
import struct
import sys

BOOK_TYPES = {b'A', b'F', b'E', b'C', b'X', b'D', b'U'}

MSG_LEN = {
    b'S': 12, b'R': 39, b'H': 25, b'Y': 20, b'L': 26, b'V': 35, b'W': 12,
    b'K': 28, b'J': 35, b'h': 21, b'A': 36, b'F': 40, b'E': 31, b'C': 36,
    b'X': 23, b'D': 19, b'U': 35, b'P': 44, b'Q': 40, b'B': 19, b'I': 50,
    b'N': 20,
}


def _open(path):
    return gzip.open(path, 'rb') if path.endswith('.gz') else open(path, 'rb')


def extract(src, symbols, limit, skip=0):
    want = set(s.encode().ljust(8, b' ') for s in symbols)
    live = set()
    out = bytearray()
    kept = 0
    scanned = 0
    skipped = 0
    counts = {}

    with _open(src) as f:
        while True:
            hdr = f.read(2)
            if len(hdr) < 2:
                break
            (mlen,) = struct.unpack('>H', hdr)
            if mlen == 0:
                continue
            body = f.read(mlen)
            if len(body) < mlen:
                break
            scanned += 1

            mtype = body[0:1]
            if mtype not in BOOK_TYPES:
                continue

            if mtype in (b'A', b'F'):
                if body[24:32] not in want:
                    continue
                (ref,) = struct.unpack_from('>Q', body, 11)
                live.add(ref)
            elif mtype == b'U':
                (ref,) = struct.unpack_from('>Q', body, 11)
                if ref not in live:
                    continue
                (new_ref,) = struct.unpack_from('>Q', body, 19)
                live.add(new_ref)
            else:
                (ref,) = struct.unpack_from('>Q', body, 11)
                if ref not in live:
                    continue

            if skipped < skip:
                skipped += 1
                continue

            out += hdr + body
            counts[mtype.decode()] = counts.get(mtype.decode(), 0) + 1
            kept += 1
            if limit and kept >= limit:
                break

    return bytes(out), kept, scanned, counts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('src')
    ap.add_argument('-o', '--out', required=True)
    ap.add_argument('-s', '--symbols', default='AAPL,MSFT,NVDA,AMZN')
    ap.add_argument('-n', '--limit', type=int, default=20000)
    ap.add_argument('--skip', type=int, default=0)
    a = ap.parse_args()

    syms = [s.strip() for s in a.symbols.split(',') if s.strip()]
    data, kept, scanned, counts = extract(a.src, syms, a.limit, a.skip)
    with open(a.out, 'wb') as f:
        f.write(data)

    mix = ' '.join(f'{k}={v}' for k, v in sorted(counts.items()))
    print(f'scanned {scanned} messages, kept {kept} ({len(data)} bytes) -> {a.out}')
    print(f'symbols: {",".join(syms)}')
    print(f'mix: {mix}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
