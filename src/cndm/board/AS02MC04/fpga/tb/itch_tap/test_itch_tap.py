import logging
import os
import sys

import cocotb_test.simulator

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from cocotbext.axi import AxiStreamBus, AxiStreamSource, AxiStreamSink, AxiStreamFrame

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
        self.passsink = AxiStreamSink(
            AxiStreamBus.from_entity(dut.m_axis_pass), dut.clk, dut.rst)

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
        for _ in range(16):
            await RisingEdge(self.dut.clk)
        return frame_bytes

    async def read_tob(self, sym_id):
        self.dut.dbg_sym.value = sym_id
        for _ in range(4):
            await RisingEdge(self.dut.clk)
        return (int(self.dut.dbg_bid_px.value),
                int(self.dut.dbg_bid_qty.value),
                int(self.dut.dbg_ask_px.value),
                int(self.dut.dbg_ask_qty.value))

def _stream():
    mk = itch._mk
    framed = itch._framed
    return framed(
        mk('A', ref=1, side='B', shares=100, stock='AAPL', price=1500000),
        mk('A', ref=2, side='B', shares=200, stock='AAPL', price=1499900),
        mk('A', ref=3, side='S', shares=150, stock='AAPL', price=1500100),
        mk('A', ref=7, side='B', shares=400, stock='AAPL', price=1500000),
        mk('A', ref=5, side='B', shares=500, stock='MSFT', price=4200000),
        mk('A', ref=6, side='S', shares=250, stock='MSFT', price=4200100),
        mk('E', ref=1, shares=40),
    )

@cocotb.test()
async def run_test_tap(dut):
    tb = TB(dut)
    await tb.reset()

    stream = _stream()
    book = itch.build_book(stream, symbols=SYMBOLS)

    sent = await tb.send_stream(stream, ts=0x0123456789AB)

    pkt = await tb.passsink.recv()
    got = bytes(pkt.tdata)
    tb.log.info("pass-through: %d bytes (sent %d)", len(got), len(sent))
    assert got == sent, "m_axis_pass is not a faithful copy of the input"

    for sym in ('AAPL', 'MSFT'):
        tob = await tb.read_tob(SYM_ID[sym])
        exp = book.top_of_book(sym)
        tb.log.info("%s: DUT=%r golden=%r", sym, tob, exp)
        assert tob == exp, f"{sym}: DUT {tob} != golden {exp}"

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

def test_itch_tap(request):
    dut = "itch_tap"
    module = os.path.splitext(os.path.basename(__file__))[0]
    toplevel = module

    verilog_sources = [
        os.path.join(tests_dir, f"{toplevel}.sv"),
        os.path.join(rtl_dir, "itch_tap.sv"),
        os.path.join(rtl_dir, "itch_decode.sv"),
        os.path.join(taxi_src_dir, "axis", "rtl", "taxi_axis_if.sv"),
        os.path.join(taxi_src_dir, "axis", "rtl", "taxi_axis_broadcast.sv"),
        os.path.join(taxi_src_dir, "axis", "rtl", "taxi_axis_adapter.sv"),
    ]

    verilog_sources = process_f_files(verilog_sources)

    parameters = {}
    parameters['SYM_COUNT'] = 4
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
