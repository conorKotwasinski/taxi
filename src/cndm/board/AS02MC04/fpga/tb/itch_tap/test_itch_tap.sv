`resetall
`timescale 1ns / 1ps
`default_nettype none

module test_itch_tap #
(

    parameter SYM_COUNT      = 4,
    parameter LEVELS         = 16,
    parameter ORDER_COUNT    = 4096,
    parameter PRICE_W        = 32,
    parameter QTY_W          = 32,
    parameter ORDER_REF_W    = 64,
    parameter TS_W           = 48,
    parameter HDR_SKIP_BYTES = 14

)
();

localparam SYM_AW = $clog2(SYM_COUNT);
localparam USER_W = 1 + TS_W;

logic clk;
logic rst;

taxi_axis_if #(.DATA_W(64), .USER_EN(1), .USER_W(USER_W)) axis_rx();
assign axis_rx.tready = 1'b1;

logic               ladder_overflow;
logic               fifo_overflow;

logic [SYM_AW-1:0]  dbg_sym;
logic [PRICE_W-1:0] dbg_bid_px;
logic [QTY_W-1:0]   dbg_bid_qty;
logic [PRICE_W-1:0] dbg_ask_px;
logic [QTY_W-1:0]   dbg_ask_qty;

itch_tap #(
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
    .axis_mon(axis_rx),
    .ladder_overflow(ladder_overflow),
    .fifo_overflow(fifo_overflow),
    .cfg_imbalance_thresh('0),
    .trig_valid(),
    .trig_sym(),
    .trig_side(),
    .dbg_sym(dbg_sym),
    .dbg_bid_px(dbg_bid_px),
    .dbg_bid_qty(dbg_bid_qty),
    .dbg_ask_px(dbg_ask_px),
    .dbg_ask_qty(dbg_ask_qty)
);

endmodule

`resetall
