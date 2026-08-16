import struct
import sys

REC_BYTES = 32
FLAG_VALID = 0x04


def rec(ts, bid_px, ask_px, bid_qty, ask_qty, sym, flags, seq):
    b = bytearray(REC_BYTES)
    struct.pack_into('<Q', b, 0, ts)
    struct.pack_into('<II', b, 8, bid_px, ask_px)
    struct.pack_into('<II', b, 16, bid_qty, ask_qty)
    b[24] = sym & 0xff
    b[25] = (sym >> 8) & 0xff
    b[27] = flags & 0xff
    struct.pack_into('<I', b, 28, seq)
    return bytes(b)


def main():
    entries = 8
    records = [
        rec(0x10, 1500000, 0,       100, 0,   0, FLAG_VALID | 0x02, 0),
        rec(0x11, 1500000, 0,       300, 0,   0, FLAG_VALID | 0x02, 1),
        rec(0x12, 1500000, 1500100, 300, 150, 0, FLAG_VALID,        2),
        rec(0x13, 1500000, 1500100, 460, 150, 0, FLAG_VALID,        3),
        rec(0x14, 0,       4200100, 0,   250, 1, FLAG_VALID | 0x01, 4),
        rec(0x15, 1500000, 1500100, 420, 150, 0, FLAG_VALID,        5),
    ]
    img = bytearray(entries * REC_BYTES)
    for i, r in enumerate(records):
        img[i*REC_BYTES:(i+1)*REC_BYTES] = r

    out = sys.argv[1] if len(sys.argv) > 1 else 'ring_fixture.bin'
    with open(out, 'wb') as f:
        f.write(img)

    sym = ['AAPL', 'MSFT', 'NVDA', 'AMZN']
    for r in records:
        _ts, = struct.unpack_from('<Q', r, 0)
        bpx, apx = struct.unpack_from('<II', r, 8)
        bq, aq = struct.unpack_from('<II', r, 16)
        s = r[24] | (r[25] << 8)
        seq, = struct.unpack_from('<I', r, 28)
        sys.stderr.write(
            "seq %-8u %-4s bid %.4f x %-8u ask %.4f x %-8u\n"
            % (seq, sym[s] if s < 4 else '????',
               bpx / 10000.0, bq, apx / 10000.0, aq))


if __name__ == '__main__':
    main()
