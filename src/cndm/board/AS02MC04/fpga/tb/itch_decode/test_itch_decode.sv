// SPDX-License-Identifier: MIT
/*
 * testbench for itch_decode
 */

`resetall
`timescale 1ns / 1ps
`default_nettype none

module test_itch_decode #
(
    /* verilator lint_off WIDTHTRUNC */
    parameter DATA_W         = 8,
    parameter SYM_COUNT      = 64,
    parameter LEVELS         = 8,
    parameter ORDER_COUNT    = 4096,
    parameter PRICE_W        = 32,
    parameter QTY_W          = 32,
    parameter ORDER_REF_W    = 64,
    parameter TS_W           = 48,
    parameter HDR_SKIP_BYTES = 14
    /* verilator lint_on WIDTHTRUNC */
)
();

localparam SYM_AW = $clog2(SYM_COUNT);

logic clk;
logic rst;

// Frame input carries: tuser[0] = bad, tuser[1 +: TS_W] = ingress timestamp
taxi_axis_if #(.DATA_W(DATA_W), .USER_EN(1), .USER_W(1+TS_W)) s_axis_rx();
// Delta output (unused in Phase 1)
taxi_axis_if #(.DATA_W(64), .USER_EN(1), .USER_W(1)) m_axis_delta();

logic [QTY_W-1:0]  cfg_imbalance_thresh;

logic              trig_valid;
logic [SYM_AW-1:0] trig_sym;

logic [SYM_AW-1:0] dbg_sym;
logic [PRICE_W-1:0] dbg_bid_px;
logic [QTY_W-1:0]   dbg_bid_qty;
logic [PRICE_W-1:0] dbg_ask_px;
logic [QTY_W-1:0]   dbg_ask_qty;

itch_decode #(
    .SYM_COUNT(SYM_COUNT),
    .LEVELS(LEVELS),
    .ORDER_COUNT(ORDER_COUNT),
    .PRICE_W(PRICE_W),
    .QTY_W(QTY_W),
    .ORDER_REF_W(ORDER_REF_W),
    .TS_W(TS_W),
    .HDR_SKIP_BYTES(HDR_SKIP_BYTES)
)
uut (
    .clk(clk),
    .rst(rst),

    .s_axis_rx(s_axis_rx),
    .m_axis_delta(m_axis_delta),

    .trig_valid(trig_valid),
    .trig_sym(trig_sym),
    .cfg_imbalance_thresh(cfg_imbalance_thresh),

    .dbg_sym(dbg_sym),
    .dbg_bid_px(dbg_bid_px),
    .dbg_bid_qty(dbg_bid_qty),
    .dbg_ask_px(dbg_ask_px),
    .dbg_ask_qty(dbg_ask_qty)
);

// let the delta sink always accept
assign m_axis_delta.tready = 1'b1;

endmodule

`resetall
