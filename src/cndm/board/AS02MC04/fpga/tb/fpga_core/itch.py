import struct
from collections import defaultdict

MSG_LEN = {
    b'S': 12,
    b'R': 39,
    b'H': 25,
    b'Y': 20,
    b'L': 26,
    b'V': 35,
    b'W': 12,
    b'K': 28,
    b'J': 35,
    b'h': 21,
    b'A': 36,
    b'F': 40,
    b'E': 31,
    b'C': 36,
    b'X': 23,
    b'D': 19,
    b'U': 35,
    b'P': 44,
    b'Q': 40,
    b'B': 19,
    b'I': 50,
}

PRICE_SCALE = 10000

def _u16(b, o):
    return struct.unpack_from('>H', b, o)[0]

def _u32(b, o):
    return struct.unpack_from('>I', b, o)[0]

def _u64(b, o):
    return struct.unpack_from('>Q', b, o)[0]

def _u48(b, o):

    return int.from_bytes(b[o:o + 6], 'big')

def _stock(b, o):

    return b[o:o + 8].rstrip(b' ')

class Msg:
    __slots__ = ('type', 'ts', 'order_ref', 'new_order_ref',
                 'side', 'shares', 'stock', 'price', 'match')

    def __init__(self, mtype):
        self.type = mtype
        self.ts = None
        self.order_ref = None
        self.new_order_ref = None
        self.side = None
        self.shares = None
        self.stock = None
        self.price = None
        self.match = None

    def __repr__(self):
        return (f"Msg({self.type!r} ref={self.order_ref} side={self.side} "
                f"sh={self.shares} stk={self.stock} px={self.price})")

def parse_message(body):
    mtype = body[0:1]
    m = Msg(mtype)
    m.ts = _u48(body, 5)

    if mtype == b'A':
        m.order_ref = _u64(body, 11)
        m.side = chr(body[19])
        m.shares = _u32(body, 20)
        m.stock = _stock(body, 24)
        m.price = _u32(body, 32)
        return m

    if mtype == b'F':
        m.order_ref = _u64(body, 11)
        m.side = chr(body[19])
        m.shares = _u32(body, 20)
        m.stock = _stock(body, 24)
        m.price = _u32(body, 32)

        return m

    if mtype == b'E':
        m.order_ref = _u64(body, 11)
        m.shares = _u32(body, 19)
        m.match = _u64(body, 23)
        return m

    if mtype == b'C':
        m.order_ref = _u64(body, 11)
        m.shares = _u32(body, 19)
        m.match = _u64(body, 23)

        return m

    if mtype == b'X':
        m.order_ref = _u64(body, 11)
        m.shares = _u32(body, 19)
        return m

    if mtype == b'D':
        m.order_ref = _u64(body, 11)
        return m

    if mtype == b'U':
        m.order_ref = _u64(body, 11)
        m.new_order_ref = _u64(body, 19)
        m.shares = _u32(body, 27)
        m.price = _u32(body, 31)
        return m

    return None

class Order:
    __slots__ = ('stock', 'side', 'price', 'qty')

    def __init__(self, stock, side, price, qty):
        self.stock = stock
        self.side = side
        self.price = price
        self.qty = qty

class ItchBook:

    def __init__(self, symbols=None):
        self.symbols = set(s if isinstance(s, bytes) else s.encode()
                           for s in symbols) if symbols else None
        self.orders = {}
        self.bids = defaultdict(lambda: defaultdict(int))
        self.asks = defaultdict(lambda: defaultdict(int))

    def _tracked(self, stock):
        return self.symbols is None or stock in self.symbols

    def _levels(self, stock, side):
        return self.bids[stock] if side == 'B' else self.asks[stock]

    def _add_qty(self, stock, side, price, dq):
        lv = self._levels(stock, side)
        lv[price] += dq
        if lv[price] <= 0:
            del lv[price]

    def apply(self, m):
        if m is None:
            return

        if m.type in (b'A', b'F'):
            if not self._tracked(m.stock):
                return
            self.orders[m.order_ref] = Order(m.stock, m.side, m.price, m.shares)
            self._add_qty(m.stock, m.side, m.price, m.shares)

        elif m.type in (b'E', b'C', b'X'):

            o = self.orders.get(m.order_ref)
            if o is None:
                return
            take = min(o.qty, m.shares)
            o.qty -= take
            self._add_qty(o.stock, o.side, o.price, -take)
            if o.qty == 0:
                del self.orders[m.order_ref]

        elif m.type == b'D':
            o = self.orders.pop(m.order_ref, None)
            if o is None:
                return
            self._add_qty(o.stock, o.side, o.price, -o.qty)

        elif m.type == b'U':

            o = self.orders.pop(m.order_ref, None)
            if o is None:
                return
            self._add_qty(o.stock, o.side, o.price, -o.qty)
            self.orders[m.new_order_ref] = Order(o.stock, o.side, m.price, m.shares)
            self._add_qty(o.stock, o.side, m.price, m.shares)

    def top_of_book(self, stock):
        stock = stock if isinstance(stock, bytes) else stock.encode()
        b = self.bids.get(stock, {})
        a = self.asks.get(stock, {})
        bid_px = max(b) if b else 0
        ask_px = min(a) if a else 0
        return (bid_px, b.get(bid_px, 0), ask_px, a.get(ask_px, 0))

def iter_binaryfile(data):
    o = 0
    n = len(data)
    while o + 2 <= n:
        mlen = _u16(data, o)
        o += 2
        if o + mlen > n:
            break
        yield data[o:o + mlen]
        o += mlen

def build_book(data, symbols=None):
    book = ItchBook(symbols=symbols)
    for body in iter_binaryfile(data):
        book.apply(parse_message(body))
    return book

def _mk(mtype, **kw):
    mtype = mtype if isinstance(mtype, bytes) else mtype.encode()
    body = bytearray(MSG_LEN[mtype])
    body[0:1] = mtype

    if mtype in (b'A', b'F'):
        struct.pack_into('>Q', body, 11, kw['ref'])
        body[19] = ord(kw['side'])
        struct.pack_into('>I', body, 20, kw['shares'])
        stk = kw['stock'].encode() if isinstance(kw['stock'], str) else kw['stock']
        body[24:32] = stk.ljust(8, b' ')
        struct.pack_into('>I', body, 32, kw['price'])
    elif mtype in (b'E', b'C', b'X'):
        struct.pack_into('>Q', body, 11, kw['ref'])
        struct.pack_into('>I', body, 19, kw['shares'])
        if mtype in (b'E', b'C'):
            struct.pack_into('>Q', body, 23, kw.get('match', 0))
    elif mtype == b'D':
        struct.pack_into('>Q', body, 11, kw['ref'])
    elif mtype == b'U':
        struct.pack_into('>Q', body, 11, kw['ref'])
        struct.pack_into('>Q', body, 19, kw['new_ref'])
        struct.pack_into('>I', body, 27, kw['shares'])
        struct.pack_into('>I', body, 31, kw['price'])
    return bytes(body)

def _framed(*bodies):
    out = bytearray()
    for b in bodies:
        out += struct.pack('>H', len(b)) + b
    return bytes(out)

if __name__ == '__main__':
    AAPL = 'AAPL'
    stream = _framed(
        _mk('A', ref=1, side='B', shares=100, stock=AAPL, price=1500000),
        _mk('A', ref=2, side='B', shares=200, stock=AAPL, price=1499900),
        _mk('A', ref=3, side='S', shares=150, stock=AAPL, price=1500100),
        _mk('E', ref=1, shares=40),
        _mk('A', ref=4, side='B', shares=300, stock=AAPL, price=1500000),
        _mk('D', ref=3),
        _mk('X', ref=2, shares=50),
        _mk('U', ref=1, new_ref=5, shares=500, price=1500050),
    )

    book = build_book(stream, symbols=[AAPL])
    bid_px, bid_qty, ask_px, ask_qty = book.top_of_book(AAPL)

    print("Top of book AAPL:")
    print(f"  bid {bid_px/PRICE_SCALE:.4f} x {bid_qty}")
    print(f"  ask {ask_px/PRICE_SCALE:.4f} x {ask_qty}")

    assert (bid_px, bid_qty) == (1500050, 500), (bid_px, bid_qty)
    assert (ask_px, ask_qty) == (0, 0), (ask_px, ask_qty)
    print("self-test OK")
