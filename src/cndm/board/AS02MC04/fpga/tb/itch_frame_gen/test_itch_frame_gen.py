import logging
import os
import sys

import pytest

import cocotb_test.simulator

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'fpga_core'))
import itch

SYMBOLS = ['AAPL', 'MSFT', 'NVDA', 'AMZN']
SYM_ID = {s: i for i, s in enumerate(SYMBOLS)}
HDR_SKIP_BYTES = 14
TS_W = 48

RTL_FRAME_GEN = os.path.join(os.path.dirname(__file__), '..', '..', 'rtl',
                             'itch_frame_gen.sv')

def rom_frame():
    import re
    s = open(RTL_FRAME_GEN).read()
    m = re.search(r"localparam \[FRAME_BYTES\*8-1:0\] FRAME = \{(.*?)\};", s, re.S)
    words = [int(x, 16) for x in re.findall(r"64'h([0-9a-fA-F]+)", m.group(1))]
    words.reverse()
    return b''.join(bytes([(w >> (8 * b)) & 0xFF for b in range(8)]) for w in words)

def gen_stream():
    f = rom_frame()[HDR_SKIP_BYTES:]
    off, out = 0, bytearray()
    while off + 2 <= len(f):
        ln = int.from_bytes(f[off:off + 2], 'big')
        if ln == 0 or off + 2 + ln > len(f):
            break
        out += f[off:off + 2 + ln]
        off += 2 + ln
    return bytes(out)

class TB:
    def __init__(self, dut):
        self.dut = dut
        self.log = logging.getLogger("cocotb.tb")
        self.log.setLevel(logging.INFO)
        cocotb.start_soon(Clock(dut.clk, 3.2, units="ns").start())
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

    async def capture_frame(self, timeout=40000):
        data = bytearray()
        lanes = len(self.dut.axis_loop.tdata.value) // 8
        for _ in range(timeout):
            await RisingEdge(self.dut.clk)
            if self.dut.axis_loop.tvalid.value and self.dut.axis_loop.tready.value:
                word = int(self.dut.axis_loop.tdata.value)
                keep = int(self.dut.axis_loop.tkeep.value)
                for b in range(lanes):
                    if (keep >> b) & 1:
                        data.append((word >> (8 * b)) & 0xFF)
                if self.dut.axis_loop.tlast.value:
                    return bytes(data)
        raise AssertionError("no frame generated before timeout")

    async def read_tob(self, sym_id):
        self.dut.dbg_sym.value = sym_id
        for _ in range(4):
            await RisingEdge(self.dut.clk)
        return (int(self.dut.dbg_bid_px.value),
                int(self.dut.dbg_bid_qty.value),
                int(self.dut.dbg_ask_px.value),
                int(self.dut.dbg_ask_qty.value))

@cocotb.test()
async def run_test_frame_bytes(dut):
    tb = TB(dut)
    await tb.reset()

    frame = await tb.capture_frame()
    expected = rom_frame()

    tb.log.info("captured %d bytes: %s", len(frame), frame.hex())
    assert len(frame) == len(expected), \
        f"frame is {len(frame)} bytes, expected {len(expected)}"
    assert frame[0:6] == bytes.fromhex('ffffffffffff'), "dst is not broadcast"
    assert frame[6:12] != bytes(6), "source MAC is all zeros"
    assert frame == expected, (
        f"frame mismatch\n got {frame.hex()}\nwant {expected.hex()}")

    frame2 = await tb.capture_frame()
    assert frame2 == frame, "second generated frame differs from the first"

@cocotb.test()
async def run_test_loopback_book(dut):
    tb = TB(dut)
    await tb.reset()

    await tb.capture_frame()
    for _ in range(1500):
        await RisingEdge(dut.clk)

    assert int(dut.fifo_overflow.value) == 0, "snoop FIFO overflowed"

    book = itch.build_book(gen_stream(), symbols=SYMBOLS)
    exp = book.top_of_book('AAPL')
    tob = await tb.read_tob(SYM_ID['AAPL'])
    tb.log.info("AAPL after 1 replay: DUT=%r golden=%r", tob, exp)
    assert tob == exp, f"AAPL: DUT {tob} != golden {exp}"

@cocotb.test()
async def run_test_replays_match_golden(dut):
    tb = TB(dut)
    await tb.reset()

    stream = gen_stream()
    for n in range(1, 4):
        await tb.capture_frame()
        for _ in range(1500):
            await RisingEdge(dut.clk)
        tob = await tb.read_tob(SYM_ID['AAPL'])
        exp = itch.build_book(stream * n, symbols=SYMBOLS).top_of_book('AAPL')
        tb.log.info("AAPL after %d replays: DUT=%r golden=%r", n, tob, exp)
        assert tob == exp, f"after {n} replays: DUT {tob} != golden {exp}"

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

@pytest.mark.parametrize("data_w", [32, 64])
def test_itch_frame_gen(request, data_w):
    module = os.path.splitext(os.path.basename(__file__))[0]
    toplevel = module

    verilog_sources = [
        os.path.join(tests_dir, f"{toplevel}.sv"),
        os.path.join(rtl_dir, "itch_frame_gen.sv"),
        os.path.join(rtl_dir, "itch_tap.sv"),
        os.path.join(rtl_dir, "itch_decode.sv"),
        os.path.join(taxi_src_dir, "axis", "rtl", "taxi_axis_if.sv"),
        os.path.join(taxi_src_dir, "axis", "rtl", "taxi_axis_adapter.sv"),
        os.path.join(taxi_src_dir, "axis", "rtl", "taxi_axis_async_fifo.f"),
    ]

    verilog_sources = process_f_files(verilog_sources)

    parameters = {
        'DATA_W': data_w, 'INTERVAL': 6000,
        'SYM_COUNT': 4, 'LEVELS': 16, 'ORDER_COUNT': 1024,
        'PRICE_W': 32, 'QTY_W': 32, 'ORDER_REF_W': 64, 'TS_W': TS_W,
        'HDR_SKIP_BYTES': HDR_SKIP_BYTES,
    }
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
