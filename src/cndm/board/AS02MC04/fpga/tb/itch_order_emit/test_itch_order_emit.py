import logging
import os

import pytest

import cocotb_test.simulator

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

FRAME_BYTES = 64
BCAST = bytes.fromhex('ffffffffffff')

BEATS = [0x0002ffffffffffff, 0x4f00000803000000, 0x0000000052445200,
         0x0000006400015000, 0, 0, 0, 0]


def expected_frame():
    out = bytearray()
    for w in BEATS:
        for b in range(8):
            out.append((w >> (8 * b)) & 0xFF)
    return bytes(out)


class TB:
    def __init__(self, dut):
        self.dut = dut
        self.log = logging.getLogger("cocotb.tb")
        self.log.setLevel(logging.INFO)
        cocotb.start_soon(Clock(dut.clk, 3.2, units="ns").start())
        dut.trig.setimmediatevalue(0)

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

    async def pulse_trig(self):
        self.dut.trig.value = 1
        await RisingEdge(self.dut.clk)
        self.dut.trig.value = 0

    async def capture(self, timeout=200):
        data = bytearray()
        lanes = len(self.dut.axis_tx.tdata.value) // 8
        started = False
        for _ in range(timeout):
            await RisingEdge(self.dut.clk)
            if self.dut.axis_tx.tvalid.value and self.dut.axis_tx.tready.value:
                started = True
                word = int(self.dut.axis_tx.tdata.value)
                keep = int(self.dut.axis_tx.tkeep.value)
                for b in range(lanes):
                    if (keep >> b) & 1:
                        data.append((word >> (8 * b)) & 0xFF)
                if self.dut.axis_tx.tlast.value:
                    return bytes(data)
            elif started:
                raise AssertionError("tvalid dropped mid-frame")
        return None


@cocotb.test()
async def run_test_frame_bytes(dut):
    tb = TB(dut)
    await tb.reset()
    await tb.pulse_trig()
    frame = await tb.capture()

    assert frame is not None, "no frame emitted after trigger"
    tb.log.info("captured %d bytes: %s", len(frame), frame.hex())
    assert len(frame) == FRAME_BYTES, f"frame is {len(frame)} bytes, expected {FRAME_BYTES}"
    assert frame[0:6] == BCAST, f"dst MAC {frame[0:6].hex()} is not broadcast"
    assert frame[12:14] == bytes.fromhex('0800'), \
        f"ethertype {frame[12:14].hex()} != 0800"
    assert frame[6:12] != bytes(6), "source MAC is all zeros (invalid per 802.3)"


@cocotb.test()
async def run_test_width_independent(dut):
    tb = TB(dut)
    await tb.reset()
    await tb.pulse_trig()
    frame = await tb.capture()
    expected = expected_frame()
    assert frame == expected, \
        f"frame mismatch\n got {frame.hex()}\nwant {expected.hex()}"


@cocotb.test()
async def run_test_no_frame_without_trigger(dut):
    tb = TB(dut)
    await tb.reset()
    for _ in range(200):
        await RisingEdge(dut.clk)
        assert not dut.axis_tx.tvalid.value, "emitted a frame with no trigger"


@cocotb.test()
async def run_test_one_frame_per_trigger(dut):
    tb = TB(dut)
    await tb.reset()
    for i in range(3):
        await tb.pulse_trig()
        frame = await tb.capture()
        assert frame is not None and len(frame) == FRAME_BYTES, f"frame {i} bad"
        for _ in range(20):
            await RisingEdge(dut.clk)
            assert not dut.axis_tx.tvalid.value, f"extra frame after trigger {i}"


@cocotb.test()
async def run_test_trigger_while_busy_is_dropped(dut):
    tb = TB(dut)
    await tb.reset()
    cap = cocotb.start_soon(tb.capture())
    await tb.pulse_trig()
    await tb.pulse_trig()
    frame = await cap
    assert frame is not None and len(frame) == FRAME_BYTES
    for _ in range(40):
        await RisingEdge(dut.clk)
        assert not dut.axis_tx.tvalid.value, "mid-frame trigger queued a second frame"


tests_dir = os.path.abspath(os.path.dirname(__file__))
rtl_dir = os.path.abspath(os.path.join(tests_dir, '..', '..', 'rtl'))
lib_dir = os.path.abspath(os.path.join(tests_dir, '..', '..', 'lib'))
taxi_src_dir = os.path.abspath(os.path.join(lib_dir, 'taxi', 'src'))


@pytest.mark.parametrize("data_w", [32, 64])
def test_itch_order_emit(request, data_w):
    module = os.path.splitext(os.path.basename(__file__))[0]
    toplevel = module

    verilog_sources = [
        os.path.join(tests_dir, f"{toplevel}.sv"),
        os.path.join(rtl_dir, "itch_order_emit.sv"),
        os.path.join(taxi_src_dir, "axis", "rtl", "taxi_axis_if.sv"),
    ]

    parameters = {'DATA_W': data_w}
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
