import struct
import sys


def _iter_pcap_records(data):
    if len(data) < 24:
        return
    magic = data[:4]
    if magic in (b'\xd4\xc3\xb2\xa1', b'\xa1\xb2\xc3\xd4'):
        le = magic == b'\xd4\xc3\xb2\xa1'
        end = '<' if le else '>'
        off = 24
        while off + 16 <= len(data):
            _ts, _tsu, caplen, _orig = struct.unpack_from(end + 'IIII', data, off)
            off += 16
            if off + caplen > len(data):
                break
            yield data[off:off + caplen]
            off += caplen
    elif magic == b'\x0a\x0d\x0d\x0a':
        off = 0
        while off + 8 <= len(data):
            btype, blen = struct.unpack_from('<II', data, off)
            if blen < 12 or off + blen > len(data):
                break
            if btype == 0x00000006:
                caplen = struct.unpack_from('<I', data, off + 20)[0]
                pkt = data[off + 28:off + 28 + caplen]
                yield pkt
            off += blen
    else:
        raise SystemExit("unrecognized capture format (not pcap or pcapng)")


def _moldudp64_payload(frame):
    if len(frame) < 14:
        return None
    ethertype = struct.unpack_from('>H', frame, 12)[0]
    o = 14
    if ethertype == 0x8100:
        ethertype = struct.unpack_from('>H', frame, 16)[0]
        o = 18
    if ethertype != 0x0800:
        return None
    if len(frame) < o + 20:
        return None
    ihl = (frame[o] & 0x0f) * 4
    proto = frame[o + 9]
    if proto != 17:
        return None
    o += ihl
    if len(frame) < o + 8:
        return None
    o += 8
    if len(frame) < o + 20:
        return None
    o += 20
    return frame[o:]


def extract_messages(data):
    out = bytearray()
    n = 0
    for frame in _iter_pcap_records(data):
        payload = _moldudp64_payload(frame)
        if payload is None:
            continue
        p = 0
        while p + 2 <= len(payload):
            mlen = struct.unpack_from('>H', payload, p)[0]
            p += 2
            if mlen == 0 or p + mlen > len(payload):
                break
            out += struct.pack('>H', mlen) + payload[p:p + mlen]
            p += mlen
            n += 1
    return bytes(out), n


if __name__ == '__main__':
    if len(sys.argv) < 3:
        sys.stderr.write("usage: pcap_to_itch.py <in.pcap> <out.bin>\n")
        sys.exit(1)
    data = open(sys.argv[1], 'rb').read()
    stream, n = extract_messages(data)
    open(sys.argv[2], 'wb').write(stream)
    sys.stderr.write("extracted %d messages, %d payload bytes\n" % (n, len(stream)))
