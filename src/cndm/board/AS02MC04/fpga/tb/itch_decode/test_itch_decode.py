import logging
import os
import struct
import sys

import cocotb_test.simulator

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from cocotbext.axi import AxiStreamBus, AxiStreamSource, AxiStreamFrame

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'fpga_core'))
import itch

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

        dut.cfg_imbalance_thresh.setimmediatevalue(0)
        dut.dbg_sym.setimmediatevalue(0)

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
        for _ in range(8):
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

def test_itch_decode(request):
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
    parameters['DATA_W'] = 8
    parameters['SYM_COUNT'] = len(SYMBOLS) if len(SYMBOLS) > 1 else 2
    parameters['LEVELS'] = 8
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
