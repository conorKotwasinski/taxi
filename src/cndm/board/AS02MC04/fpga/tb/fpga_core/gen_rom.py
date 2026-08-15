import argparse
import sys

sys.path.insert(0, 'tb/fpga_core')
import itch


ETH_DST = bytes.fromhex('ffffffffffff')
ETH_SRC = bytes.fromhex('020000000002')
ETH_TYPE = bytes.fromhex('0800')


def build_frame(bodies, frame_bytes):
    stream = itch._framed(*bodies)
    payload = ETH_DST + ETH_SRC + ETH_TYPE + stream
    if len(payload) > frame_bytes:
        raise SystemExit(f"payload {len(payload)} > FRAME_BYTES {frame_bytes}")
    payload += bytes(frame_bytes - len(payload))
    return payload


def emit_sv(frame):
    n = len(frame)
    assert n % 8 == 0, "FRAME_BYTES must be a multiple of 8"
    words = []
    for j in range(n // 8):
        w = 0
        for k in range(8):
            w |= frame[j * 8 + k] << (k * 8)
        words.append(w)
    lines = [f"        64'h{w:016x}" for w in reversed(words)]
    body = ",\n".join(lines)
    fb = f"    localparam FRAME_BYTES = {n};"
    fr = (f"    localparam [FRAME_BYTES*8-1:0] FRAME = {{\n{body}\n    }};")
    return n, fb, fr


def decode_existing(words_hex, hdr=14):
    frame = bytearray()
    for w in reversed(words_hex):
        for k in range(8):
            frame.append((w >> (k * 8)) & 0xff)
    return bytes(frame[hdr:])


def default_mix():
    A = 'AAPL'
    return [
        itch._mk('A', ref=1, side='B', shares=20000, stock=A, price=1500000),
        itch._mk('A', ref=2, side='S', shares=200,   stock=A, price=1500100),
        itch._mk('E', ref=1, shares=5000),
        itch._mk('X', ref=1, shares=5000),
        itch._mk('D', ref=1),
        itch._mk('D', ref=2),
    ]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--frame-bytes', type=int, default=256)
    ap.add_argument('--validate-existing', action='store_true')
    ap.add_argument('--write', metavar='FILE',
                    help='rewrite the FRAME_BYTES/FRAME block in itch_frame_gen.sv')
    args = ap.parse_args()

    if args.validate_existing:
        existing = [
            0x60e3160020202020, 0x4c5041412c010000, 0x4203000000000000,
            0x0000000000000000, 0x000000412400c4e3, 0x1600202020204c50,
            0x4141c80000005302, 0x0000000000000000, 0x0000000000000000,
            0x0041240060e31600, 0x202020204c504141, 0x6400000042010000,
            0x0000000000000000, 0x0000000000000041, 0x2400000802000000,
            0x0002ffffffffffff,
        ]
        stream = decode_existing(existing)
        book = itch.build_book(stream, symbols=['AAPL'])
        print("existing ROM decodes to:")
        print("  AAPL", book.top_of_book('AAPL'))
        return

    bodies = default_mix()
    frame = build_frame(bodies, args.frame_bytes)

    peak_imb = 0
    step = itch.ItchBook(symbols=['AAPL'])
    for body in itch.iter_binaryfile(frame[14:]):
        step.apply(itch.parse_message(body))
        bpx, bq, apx, aq = step.top_of_book('AAPL')
        peak_imb = max(peak_imb, abs(bq - aq))

    book = itch.build_book(frame[14:], symbols=['AAPL'])
    print("// generated frame decodes to (one replay):", file=sys.stderr)
    print("//   AAPL end-of-frame", book.top_of_book('AAPL'),
          "(should be empty => bounded over replays)", file=sys.stderr)
    print(f"//   peak intra-frame imbalance {peak_imb} "
          f"(fires trigger if > threshold, default 10000)", file=sys.stderr)

    if args.write:
        import re
        txt = open(args.write).read()
        n, fb, fr = emit_sv(frame)
        txt2 = re.sub(r"    localparam FRAME_BYTES = \d+;", fb, txt, count=1)
        txt2 = re.sub(
            r"    localparam \[FRAME_BYTES\*8-1:0\] FRAME = \{.*?\};",
            fr, txt2, count=1, flags=re.S)
        if txt2 == txt:
            raise SystemExit("FRAME block not found/unchanged in " + args.write)
        open(args.write, 'w').write(txt2)
        print("// wrote " + args.write, file=sys.stderr)
    else:
        n, fb, fr = emit_sv(frame)
        print(fb + "\n\n" + fr)


if __name__ == '__main__':
    main()
