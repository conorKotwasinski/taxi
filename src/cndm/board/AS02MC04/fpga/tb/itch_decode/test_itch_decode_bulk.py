import gzip
import logging
import os
import sys

import cocotb_test.simulator

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from cocotbext.axi import AxiStreamBus, AxiStreamSource, AxiStreamFrame

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'fpga_core'))
import itch
import itch_gen

SYMBOLS = ['AAPL', 'MSFT', 'NVDA', 'AMZN']
SYM_ID = {s: i for i, s in enumerate(SYMBOLS)}
HDR_SKIP_BYTES = 14
TS_W = 48

def _load_stream():
    path = os.environ.get('ITCH_FILE')
    cap = int(os.environ.get('ITCH_MSGS', '1500'))
    if path:
        path = os.path.expanduser(path)
        raw = (gzip.open(path, 'rb') if path.endswith('.gz')
               else open(path, 'rb')).read()

        bodies = []
        for i, body in enumerate(itch.iter_binaryfile(raw)):
            if i >= cap:
                break
            bodies.append(body)
        return itch._framed(*bodies)

    stream, _ = itch_gen.gen_random_stream(SYMBOLS, n_msgs=cap, seed=1,
                                           single_level_safe=False)
    return stream

class TB:
    def __init__(self, dut):
        self.dut = dut
        self.log = logging.getLogger("cocotb.tb")
        self.log.setLevel(logging.INFO)
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
        frame = AxiStreamFrame(bytes(HDR_SKIP_BYTES) + stream_bytes,
                               tuser=(ts << 1))
        await self.source.send(frame)
        await self.source.wait()
        for _ in range(16):
            await RisingEdge(self.dut.clk)

    async def read_tob(self, sym_id):
        self.dut.dbg_sym.value = sym_id
        for _ in range(4):
            await RisingEdge(self.dut.clk)
        return (int(self.dut.dbg_bid_px.value),
                int(self.dut.dbg_bid_qty.value),
                int(self.dut.dbg_ask_px.value),
                int(self.dut.dbg_ask_qty.value))

@cocotb.test()
async def run_test_bulk(dut):
    tb = TB(dut)
    await tb.reset()

    stream = _load_stream()
    n = sum(1 for _ in itch.iter_binaryfile(stream))
    tb.log.info("bulk stream: %d messages, %d bytes", n, len(stream))

    book = itch.build_book(stream, symbols=SYMBOLS)

    await tb.send_stream(stream, ts=0x0123456789AB)

    fails = 0
    for sym in SYMBOLS:
        got = await tb.read_tob(SYM_ID[sym])
        exp = book.top_of_book(sym)
        ok = (got == exp)
        tb.log.info("%s: DUT=%r golden=%r %s", sym, got, exp,
                    "OK" if ok else "MISMATCH")
        fails += (not ok)
    assert fails == 0, f"{fails} symbol(s) mismatched golden model"

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

def test_itch_decode_bulk(request):
    dut = "itch_decode"
    module = os.path.splitext(os.path.basename(__file__))[0]
    toplevel = "test_itch_decode"

    verilog_sources = [
        os.path.join(tests_dir, "test_itch_decode.sv"),
        os.path.join(rtl_dir, f"{dut}.sv"),
        os.path.join(taxi_src_dir, "axis", "rtl", "taxi_axis_if.sv"),
    ]
    verilog_sources = process_f_files(verilog_sources)

    parameters = {
        'DATA_W': 8, 'SYM_COUNT': 4, 'LEVELS': 8, 'ORDER_COUNT': 4096,
        'PRICE_W': 32, 'QTY_W': 32, 'ORDER_REF_W': 64, 'TS_W': TS_W,
        'HDR_SKIP_BYTES': HDR_SKIP_BYTES,
    }
    extra_env = {f'PARAM_{k}': str(v) for k, v in parameters.items()}
    extra_env['ITCH_FILE'] = os.environ.get('ITCH_FILE', '')
    extra_env['ITCH_MSGS'] = os.environ.get('ITCH_MSGS', '1500')

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
