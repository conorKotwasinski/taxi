import logging
import os

import cocotb_test.simulator

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from cocotbext.axi import AxiStreamBus, AxiStreamSource, AxiStreamFrame

REC_BYTES = 32
RING_ENTRIES = 8
BASE = 0x1_0000_0000

class TB:
    def __init__(self, dut):
        self.dut = dut
        self.log = logging.getLogger("cocotb.tb")
        self.log.setLevel(logging.INFO)
        cocotb.start_soon(Clock(dut.clk, 4, units="ns").start())
        self.source = AxiStreamSource(
            AxiStreamBus.from_entity(dut.s_axis_delta), dut.clk, dut.rst)
        dut.cfg_ring_base.setimmediatevalue(BASE)
        dut.cfg_ring_enable.setimmediatevalue(0)

    async def reset(self):
        self.dut.rst.setimmediatevalue(0)
        for _ in range(2):
            await RisingEdge(self.dut.clk)
        self.dut.rst.value = 1
        for _ in range(3):
            await RisingEdge(self.dut.clk)
        self.dut.rst.value = 0
        for _ in range(3):
            await RisingEdge(self.dut.clk)

async def _monitor(dut, seen):
    prev = 0
    while True:
        await RisingEdge(dut.clk)
        c = int(dut.accept_count.value)
        if c != prev:
            addr = int(dut.last_dst_addr.value)
            data = int(dut.captured.value).to_bytes(REC_BYTES, 'little')
            seen.append((addr, data))
            prev = c

@cocotb.test()
async def run_test_dma_client(dut):
    tb = TB(dut)
    await tb.reset()
    dut.cfg_ring_enable.value = 1

    seen = []
    cocotb.start_soon(_monitor(dut, seen))

    N = 12
    sent = []
    for i in range(N):
        rec = bytes(((i * 7 + k) & 0xff) for k in range(REC_BYTES))
        sent.append(rec)
        await tb.source.send(AxiStreamFrame(rec))

        for _ in range(40):
            await RisingEdge(dut.clk)

    for _ in range(40):
        await RisingEdge(dut.clk)

    tb.log.info("descriptors=%d prod_ptr=%d", len(seen), int(dut.prod_ptr.value))
    assert len(seen) == N, f"expected {N} descriptors, got {len(seen)}"
    assert int(dut.prod_ptr.value) == N

    for i, (addr, data) in enumerate(seen):
        exp_addr = BASE + (i % RING_ENTRIES) * REC_BYTES
        assert addr == exp_addr, f"rec {i}: addr {addr:#x} != {exp_addr:#x}"
        assert data == sent[i], f"rec {i}: data mismatch\n got {data.hex()}\n exp {sent[i].hex()}"
    tb.log.info("addressing + wrap + data integrity verified over %d records", N)

tests_dir = os.path.abspath(os.path.dirname(__file__))
rtl_dir = os.path.abspath(os.path.join(tests_dir, '..', '..', 'rtl'))
lib_dir = os.path.abspath(os.path.join(tests_dir, '..', '..', 'lib'))
taxi_src_dir = os.path.abspath(os.path.join(lib_dir, 'taxi', 'src'))

def test_itch_delta_dma(request):
    dut = "itch_delta_dma"
    module = os.path.splitext(os.path.basename(__file__))[0]
    toplevel = module

    verilog_sources = [
        os.path.join(tests_dir, f"{toplevel}.sv"),
        os.path.join(rtl_dir, "itch_delta_dma.sv"),
        os.path.join(taxi_src_dir, "axis", "rtl", "taxi_axis_if.sv"),
        os.path.join(taxi_src_dir, "dma", "rtl", "taxi_dma_desc_if.sv"),
        os.path.join(taxi_src_dir, "dma", "rtl", "taxi_dma_ram_if.sv"),
        os.path.join(taxi_src_dir, "dma", "rtl", "taxi_dma_psdpram.sv"),
        os.path.join(taxi_src_dir, "dma", "rtl", "taxi_dma_client_axis_sink.sv"),
    ]

    parameters = {
        'REC_BYTES': REC_BYTES, 'RING_ENTRIES': RING_ENTRIES,
        'ADDR_W': 64, 'LEN_W': 20, 'TAG_W': 8,
        'RAM_SEGS': 2, 'RAM_SEG_ADDR_W': 12, 'RAM_SEG_DATA_W': 128,
        'RAM_SEG_BE_W': 16, 'RAM_SEL_W': 2,
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
