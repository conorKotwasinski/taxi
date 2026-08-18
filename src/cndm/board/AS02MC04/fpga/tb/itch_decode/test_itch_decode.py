import logging
import os
import struct
import sys

import cocotb_test.simulator
import pytest

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from cocotbext.axi import AxiStreamBus, AxiStreamSource, AxiStreamSink, AxiStreamFrame

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'fpga_core'))
import itch
import itch_gen

SYMBOLS = ['AAPL', 'MSFT', 'NVDA', 'AMZN']
SYM_ID = {s: i for i, s in enumerate(SYMBOLS)}

HDR_SKIP_BYTES = 14
TS_W = 48

class TB:
    def __init__(self, dut):
        self.dut = dut
        self.log = logging.getLogger("cocotb.tb")
        self.log.setLevel(logging.DEBUG)

        cocotb.start_soon(Clock(dut.clk, 3.2, units="ns").start())

        self.source = AxiStreamSource(
            AxiStreamBus.from_entity(dut.s_axis_rx), dut.clk, dut.rst)
        self.delta_sink = AxiStreamSink(
            AxiStreamBus.from_entity(dut.m_axis_delta), dut.clk, dut.rst)

        dut.cfg_imbalance_thresh.setimmediatevalue(0)
        dut.dbg_sym.setimmediatevalue(0)
        self.trig_events = []
        cocotb.start_soon(self._trig_monitor())

    async def _trig_monitor(self):

        while True:
            await RisingEdge(self.dut.clk)
            if int(self.dut.trig_valid.value):
                self.trig_events.append(
                    (int(self.dut.trig_sym.value), int(self.dut.trig_side.value)))

    async def reset(self):
        self.dut.rst.setimmediatevalue(0)
        for _ in range(2):
            await RisingEdge(self.dut.clk)
        self.dut.rst.value = 1
        for _ in range(2):
            await RisingEdge(self.dut.clk)
        self.dut.rst.value = 0
        for _ in range(2):
            await RisingEdge(self.dut.clk)

    async def send_stream(self, stream_bytes, ts=0):
        frame_bytes = bytes(HDR_SKIP_BYTES) + stream_bytes
        tuser = (ts << 1) | 0
        frame = AxiStreamFrame(frame_bytes, tuser=tuser)
        await self.source.send(frame)

        await self.source.wait()
        for _ in range(40):
            await RisingEdge(self.dut.clk)

    async def read_tob(self, sym_id):
        self.dut.dbg_sym.value = sym_id

        for _ in range(4):
            await RisingEdge(self.dut.clk)
        return (int(self.dut.dbg_bid_px.value),
                int(self.dut.dbg_bid_qty.value),
                int(self.dut.dbg_ask_px.value),
                int(self.dut.dbg_ask_qty.value))

def _stream_add_only():
    mk = itch._mk
    framed = itch._framed
    return framed(
        mk('A', ref=1, side='B', shares=100, stock='AAPL', price=1500000),
        mk('A', ref=2, side='B', shares=200, stock='AAPL', price=1499900),
        mk('A', ref=3, side='S', shares=150, stock='AAPL', price=1500100),
        mk('A', ref=4, side='S', shares=300, stock='AAPL', price=1500200),
        mk('A', ref=5, side='B', shares=500, stock='MSFT', price=4200000),
        mk('A', ref=6, side='S', shares=250, stock='MSFT', price=4200100),

        mk('A', ref=7, side='B', shares=400, stock='AAPL', price=1500000),
        mk('E', ref=1, shares=40),
    )

@cocotb.test()
async def run_test_add_only(dut):
    tb = TB(dut)
    await tb.reset()

    stream = _stream_add_only()

    book = itch.build_book(stream, symbols=SYMBOLS)

    await tb.send_stream(stream, ts=0x0123456789AB)

    for _ in range(200):
        await RisingEdge(dut.clk)

    for sym in ('AAPL', 'MSFT'):
        got = await tb.read_tob(SYM_ID[sym])
        exp = book.top_of_book(sym)
        tb.log.info("%s: DUT=%r golden=%r", sym, got, exp)
        assert got == exp, f"{sym}: DUT {got} != golden {exp}"

def _stream_delete_no_empty():
    mk = itch._mk
    framed = itch._framed
    return framed(
        mk('A', ref=1, side='B', shares=100, stock='AAPL', price=1500000),
        mk('A', ref=2, side='B', shares=250, stock='AAPL', price=1500000),
        mk('A', ref=3, side='S', shares=150, stock='AAPL', price=1500100),
        mk('D', ref=1),
    )

def _stream_replace():
    mk = itch._mk
    framed = itch._framed
    return framed(
        mk('A', ref=1, side='B', shares=100, stock='MSFT', price=4200000),
        mk('A', ref=2, side='S', shares=200, stock='MSFT', price=4200100),
        mk('U', ref=1, new_ref=9, shares=300, price=4200050),
    )

async def _run_stream_and_check(dut, stream, syms):
    tb = TB(dut)
    await tb.reset()
    book = itch.build_book(stream, symbols=SYMBOLS)
    await tb.send_stream(stream, ts=0x0123456789AB)
    for _ in range(200):
        await RisingEdge(dut.clk)
    for sym in syms:
        got = await tb.read_tob(SYM_ID[sym])
        exp = book.top_of_book(sym)
        tb.log.info("%s: DUT=%r golden=%r", sym, got, exp)
        assert got == exp, f"{sym}: DUT {got} != golden {exp}"

@cocotb.test()
async def run_test_delete_no_empty(dut):
    await _run_stream_and_check(dut, _stream_delete_no_empty(), ('AAPL',))

@cocotb.test()
async def run_test_replace(dut):
    await _run_stream_and_check(dut, _stream_replace(), ('MSFT',))

def _stream_delete_empties_best():

    mk = itch._mk
    framed = itch._framed
    return framed(
        mk('A', ref=1, side='B', shares=100, stock='AAPL', price=1500000),
        mk('A', ref=2, side='B', shares=200, stock='AAPL', price=1499900),
        mk('A', ref=3, side='S', shares=150, stock='AAPL', price=1500100),
        mk('D', ref=1),
    )

@cocotb.test()
async def run_test_delete_empties_best(dut):

    await _run_stream_and_check(dut, _stream_delete_empties_best(), ('AAPL',))

@cocotb.test()
async def run_test_trigger(dut):

    tb = TB(dut)
    await tb.reset()
    dut.cfg_imbalance_thresh.value = 300

    mk = itch._mk
    framed = itch._framed
    stream = framed(
        mk('A', ref=1, side='B', shares=1000, stock='AAPL', price=1500000),
        mk('A', ref=2, side='S', shares=100,  stock='AAPL', price=1500100),
        mk('A', ref=3, side='B', shares=200,  stock='MSFT', price=4200000),
        mk('A', ref=4, side='S', shares=250,  stock='MSFT', price=4200100),
    )
    await tb.send_stream(stream, ts=1)

    aapl = SYM_ID['AAPL']
    msft = SYM_ID['MSFT']
    fired_aapl_bid = any(s == aapl and side == 0 for s, side in tb.trig_events)
    fired_msft = any(s == msft for s, side in tb.trig_events)
    tb.log.info("trigger events: %r", tb.trig_events)
    assert fired_aapl_bid, "expected AAPL bid-heavy trigger"
    assert not fired_msft, "MSFT is balanced; should not trigger"

    tlast = int(dut.dbg_tlat_last.value)
    tmin = int(dut.dbg_tlat_min.value)
    tmax = int(dut.dbg_tlat_max.value)
    tb.log.info("tick-to-trigger latency (cycles): last=%d min=%d max=%d",
                tlast, tmin, tmax)
    assert tmax > 0, "no tick-to-trigger latency measured"
    assert tmin <= tlast <= tmax, f"tlat not ordered: {tmin} {tlast} {tmax}"
    assert tmax < 4096, "tick-to-trigger latency implausibly large"

@cocotb.test()
async def run_test_delta_emit(dut):

    tb = TB(dut)
    await tb.reset()

    mk = itch._mk
    framed = itch._framed
    stream = framed(
        mk('A', ref=1, side='B', shares=100, stock='AAPL', price=1500000),
        mk('A', ref=2, side='B', shares=200, stock='AAPL', price=1499900),
        mk('A', ref=3, side='S', shares=150, stock='AAPL', price=1500100),
        mk('A', ref=4, side='B', shares=400, stock='AAPL', price=1500000),
        mk('A', ref=5, side='S', shares=250, stock='MSFT', price=4200100),
        mk('E', ref=1, shares=40),
        mk('D', ref=3),
    )
    book = itch.build_book(stream, symbols=SYMBOLS)

    await tb.send_stream(stream, ts=0x0123456789AB)
    for _ in range(50):
        await RisingEdge(dut.clk)

    records = []
    while not tb.delta_sink.empty():
        frame = tb.delta_sink.recv_nowait()
        records.append(bytes(frame.tdata))

    tb.log.info("got %d delta records", len(records))
    assert records, "no delta records emitted"

    last_by_sym = {}
    prev_seq = -1
    for rec in records:
        assert len(rec) == 32, f"record must be 32 bytes, got {len(rec)}"
        ts = int.from_bytes(rec[0:8], 'little')
        bid_px, ask_px = struct.unpack_from('<II', rec, 8)
        bid_q,  ask_q  = struct.unpack_from('<II', rec, 16)
        sym, flags, seq = struct.unpack_from('<HHI', rec, 24)
        assert seq == prev_seq + 1, f"seq not monotonic: {seq} after {prev_seq}"
        prev_seq = seq
        last_by_sym[sym] = (bid_px, bid_q, ask_px, ask_q)

    for name in ('AAPL', 'MSFT'):
        sid = SYM_ID[name]
        exp = book.top_of_book(name)
        got = last_by_sym.get(sid)
        tb.log.info("%s: last-delta=%r golden=%r", name, got, exp)
        assert got == exp, f"{name}: delta {got} != golden {exp}"


@cocotb.test()
async def run_test_latency(dut):
    tb = TB(dut)
    await tb.reset()
    stream = _stream_add_only()
    await tb.send_stream(stream, ts=0x10)
    for _ in range(50):
        await RisingEdge(dut.clk)
    last = int(dut.dbg_lat_last.value)
    lmin = int(dut.dbg_lat_min.value)
    lmax = int(dut.dbg_lat_max.value)
    tb.log.info("wire-to-book latency (cycles): last=%d min=%d max=%d", last, lmin, lmax)
    assert lmax > 0, "no latency measured"
    assert lmin <= last <= lmax, "last outside [min,max]"
    assert lmax < 4096, "latency implausibly large"


@cocotb.test()
async def run_test_straddle(dut):
    tb = TB(dut)
    await tb.reset()
    mk = itch._mk
    framed = itch._framed

    stream = framed(
        mk('A', ref=1, side='B', shares=100, stock='AAPL', price=1500000),
        mk('A', ref=2, side='S', shares=200, stock='AAPL', price=1500100),
        mk('D', ref=1),
        mk('D', ref=2),
    )
    book = itch.build_book(stream, symbols=SYMBOLS)

    await tb.send_stream(stream, ts=0x55)

    got = await tb.read_tob(SYM_ID['AAPL'])
    exp = book.top_of_book('AAPL')
    tb.log.info("straddle: dut=%r golden=%r", got, exp)
    assert got == exp, f"straddle: dut={got} golden={exp}"


@cocotb.test()
async def run_test_order_collision(dut):
    tb = TB(dut)
    await tb.reset()
    mk = itch._mk
    framed = itch._framed

    order_count = int(dut.ORDER_COUNT.value)

    stream = framed(
        mk('A', ref=1, side='B', shares=100, stock='AAPL', price=1500000),
        mk('A', ref=2, side='S', shares=200, stock='AAPL', price=1500100),
        mk('D', ref=1 + order_count),
        mk('E', ref=2 + order_count, shares=50),
        mk('A', ref=3, side='B', shares=400, stock='AAPL', price=1500050),
        mk('D', ref=3 + order_count),
    )
    book = itch.build_book(stream, symbols=SYMBOLS)

    await tb.send_stream(stream, ts=0x66)

    got = await tb.read_tob(SYM_ID['AAPL'])
    exp = book.top_of_book('AAPL')
    tb.log.info("collision: dut=%r golden=%r order_count=%d", got, exp, order_count)
    assert got == exp, f"collision: dut={got} golden={exp}"


@cocotb.test()
async def run_test_replace_overflow_slot(dut):
    tb = TB(dut)
    await tb.reset()
    mk = itch._mk
    framed = itch._framed

    levels = int(dut.LEVELS.value)

    base = 1500000
    fill = [base + i * 100 for i in range(levels - 1)]
    best = base + (levels - 1) * 100
    away = base - 100000

    msgs = [
        mk('A', ref=101, side='B', shares=500, stock='AAPL', price=best),
        mk('A', ref=100, side='B', shares=100, stock='AAPL', price=best),
        mk('D', ref=100),
    ]
    msgs += [mk('A', ref=200 + i, side='B', shares=10, stock='AAPL', price=p)
             for i, p in enumerate(fill)]
    msgs += [
        mk('A', ref=300, side='B', shares=50, stock='AAPL', price=fill[0]),
        mk('U', ref=300, new_ref=100, shares=500, price=away),
        mk('D', ref=100),
        mk('D', ref=999999),
    ]

    stream = framed(*msgs)
    book = itch.build_book(stream, symbols=SYMBOLS)

    await tb.send_stream(stream, ts=0x77)

    got = await tb.read_tob(SYM_ID['AAPL'])
    exp = book.top_of_book('AAPL')
    tb.log.info("replace-overflow slot: levels=%d dut=%r golden=%r", levels, got, exp)
    assert got == exp, f"replace-overflow slot: dut={got} golden={exp}"


@cocotb.test(skip=not os.environ.get('ITCH_REPLAY_BIN'))
async def run_test_pcap_replay(dut):
    tb = TB(dut)
    await tb.reset()

    path = os.environ['ITCH_REPLAY_BIN']
    with open(path, 'rb') as f:
        data = f.read()
    bodies = list(itch.iter_binaryfile(data))

    book = itch.ItchBook(symbols=SYMBOLS)
    ts = 0x1000
    applied = 0
    diverged = 0
    lats = []
    for body in bodies:
        m = itch.parse_message(body)
        if m is None:
            continue
        await tb.send_stream(itch._framed(body), ts=ts & 0xffffffffffff)
        ts += 1
        book.apply(m)
        applied += 1
        lats.append(int(dut.dbg_lat_last.value))
        for name in SYMBOLS:
            got = await tb.read_tob(SYM_ID[name])
            exp = book.top_of_book(name)
            if got != exp:
                diverged += 1
                assert got == exp, (
                    f"msg {applied} ({body[0:1]!r}) {name}: dut={got} golden={exp}")

    ovf = int(dut.ladder_overflow.value) if hasattr(dut, 'ladder_overflow') else 0
    lats = [c for c in lats if c > 0]
    if lats:
        s = sorted(lats)
        pct = lambda p: s[min(len(s) - 1, int(len(s) * p / 100))]
        tb.log.info("replay latency (cycles): n=%d min=%d p50=%d p99=%d max=%d",
                    len(s), s[0], pct(50), pct(99), s[-1])
    tb.log.info("replay: %d messages applied, %d divergences, ladder_overflow=%d",
                applied, diverged, ovf)
    assert applied > 0
    assert applied > 0, "no messages replayed from pcap stream"


@cocotb.test()
async def run_test_equivalence(dut):
    tb = TB(dut)
    await tb.reset()

    bodies = itch_gen.gen_stress_bodies(SYMBOLS, n_msgs=300, seed=5,
                                        levels=int(os.environ.get('PARAM_LEVELS', 16)))
    book = itch.ItchBook(symbols=SYMBOLS)

    ts = 0x100
    checked = 0
    for bi, body in enumerate(bodies):
        await tb.send_stream(itch._framed(body), ts=ts)
        ts += 1
        book.apply(itch.parse_message(body))

        for name in SYMBOLS:
            got = await tb.read_tob(SYM_ID[name])
            exp = book.top_of_book(name)
            assert got == exp, (
                f"msg {bi} ({body[0:1]!r}) {name}: dut={got} golden={exp}")
            checked += 1

    tb.log.info("equivalence: %d messages, %d book comparisons, all match",
                len(bodies), checked)
    assert checked > 0


@cocotb.test()
async def run_test_depth_equivalence(dut):
    tb = TB(dut)
    await tb.reset()

    levels = int(os.environ.get('PARAM_LEVELS', 16))
    bodies = itch_gen.gen_depth_bodies(SYMBOLS, n_msgs=400, seed=9, levels=levels)
    book = itch.ItchBook(symbols=SYMBOLS)

    ts = 0x200
    checked = 0
    ovf_seen = 0
    for bi, body in enumerate(bodies):
        await tb.send_stream(itch._framed(body), ts=ts)
        ts += 1
        ovf_seen |= int(dut.ladder_overflow.value)
        book.apply(itch.parse_message(body))
        for name in SYMBOLS:
            got = await tb.read_tob(SYM_ID[name])
            exp = book.top_of_book(name)
            assert got == exp, (
                f"msg {bi} ({body[0:1]!r}) {name}: dut={got} golden={exp}")
            checked += 1

    assert ovf_seen == 0, "unexpected overflow on a full-but-legal ladder"
    tb.log.info("depth equivalence: levels=%d, %d messages, %d comparisons, all match",
                levels, len(bodies), checked)
    assert checked > 0


@cocotb.test()
async def run_test_overflow(dut):
    tb = TB(dut)
    await tb.reset()

    levels = int(os.environ.get('PARAM_LEVELS', 16))
    bodies = itch_gen.gen_depth_bodies(SYMBOLS, n_msgs=400, seed=13,
                                       levels=levels, overflow=True)
    ovf_seen = 0
    for body in bodies:
        await tb.send_stream(itch._framed(body), ts=0x300)
        ovf_seen |= int(dut.ladder_overflow.value)

    assert ovf_seen == 1, \
        "ladder_overflow never asserted despite >LEVELS distinct prices"
    tb.log.info("overflow asserted at levels=%d as expected", levels)


@cocotb.test()
async def run_test_fastpath_faster(dut):
    tb = TB(dut)
    await tb.reset()
    mk = itch._mk

    # build a book: best bid = 1500300 (ref4), a lower level 1500000 has two orders
    setup = itch._framed(
        mk('A', ref=1, side='B', shares=100, stock='AAPL', price=1500000),
        mk('A', ref=2, side='B', shares=100, stock='AAPL', price=1500000),
        mk('A', ref=3, side='B', shares=100, stock='AAPL', price=1500100),
        mk('A', ref=4, side='B', shares=100, stock='AAPL', price=1500300),
        mk('A', ref=5, side='S', shares=100, stock='AAPL', price=1500500),
    )
    await tb.send_stream(setup, ts=0x10)

    # fast path: Delete ref1 -- level 1500000 still has ref2, not the best,
    # best unchanged -> no rescan
    await tb.send_stream(itch._framed(mk('D', ref=1)), ts=0x11)
    fast_cyc = int(dut.dbg_lat_last.value)

    # slow path: Delete ref4 -- empties the best level -> full rescan.
    # same message type/length as the fast case, so the cycle delta is the
    # search path alone, not ingestion.
    await tb.send_stream(itch._framed(mk('D', ref=4)), ts=0x12)
    slow_cyc = int(dut.dbg_lat_last.value)

    tb.log.info("fast-path(D) cycles=%d, rescan(D) cycles=%d", fast_cyc, slow_cyc)
    assert fast_cyc > 0 and slow_cyc > 0
    assert slow_cyc > fast_cyc, (
        f"fast path not faster than rescan: fast={fast_cyc} rescan={slow_cyc}")

tests_dir = os.path.abspath(os.path.dirname(__file__))
rtl_dir = os.path.abspath(os.path.join(tests_dir, '..', '..', 'rtl'))
lib_dir = os.path.abspath(os.path.join(tests_dir, '..', '..', 'lib'))
taxi_src_dir = os.path.abspath(os.path.join(lib_dir, 'taxi', 'src'))

def process_f_files(files):
    lst = {}
    for f in files:
        if f[-2:].lower() == '.f':
            with open(f, 'r') as fp:
                l = fp.read().split()
            for f in process_f_files([os.path.join(os.path.dirname(f), x) for x in l]):
                lst[os.path.basename(f)] = f
        else:
            lst[os.path.basename(f)] = f
    return list(lst.values())

@pytest.mark.parametrize("data_w", [8, 16, 32])
@pytest.mark.parametrize("levels", [8, 16])
def test_itch_decode(request, levels, data_w):
    dut = "itch_decode"
    module = os.path.splitext(os.path.basename(__file__))[0]
    toplevel = module

    verilog_sources = [
        os.path.join(tests_dir, f"{toplevel}.sv"),
        os.path.join(rtl_dir, f"{dut}.sv"),
        os.path.join(taxi_src_dir, "axis", "rtl", "taxi_axis_if.sv"),
    ]

    verilog_sources = process_f_files(verilog_sources)

    parameters = {}
    parameters['DATA_W'] = data_w
    parameters['SYM_COUNT'] = len(SYMBOLS) if len(SYMBOLS) > 1 else 2
    parameters['LEVELS'] = levels
    parameters['ORDER_COUNT'] = 4096
    parameters['PRICE_W'] = 32
    parameters['QTY_W'] = 32
    parameters['ORDER_REF_W'] = 64
    parameters['TS_W'] = TS_W
    parameters['HDR_SKIP_BYTES'] = HDR_SKIP_BYTES

    extra_env = {f'PARAM_{k}': str(v) for k, v in parameters.items()}

    sim_build = os.path.join(tests_dir, "sim_build",
        request.node.name.replace('[', '-').replace(']', ''))

    cocotb_test.simulator.run(
        simulator="verilator",
        python_search=[tests_dir],
        verilog_sources=verilog_sources,
        toplevel=toplevel,
        module=module,
        parameters=parameters,
        sim_build=sim_build,
        extra_env=extra_env,
    )
