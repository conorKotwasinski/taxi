`resetall
`timescale 1ns / 1ps
`default_nettype none

module itch_tap #
(
    parameter SYM_COUNT      = 64,
    parameter LEVELS         = 16,
    parameter ORDER_COUNT    = 4096,
    parameter PRICE_W        = 32,
    parameter QTY_W          = 32,
    parameter ORDER_REF_W    = 64,
    parameter TS_W           = 48,
    parameter HDR_SKIP_BYTES = 14,
    parameter FIFO_DEPTH     = 8192
)
(
    input  wire logic  clk,
    input  wire logic  rst,

    taxi_axis_if.mon   axis_mon,

    output wire logic                          ladder_overflow,
    output wire logic                          fifo_overflow,

    input  wire logic [QTY_W-1:0]              cfg_imbalance_thresh,
    output wire logic                          trig_valid,
    output wire logic [$clog2(SYM_COUNT)-1:0]  trig_sym,
    output wire logic                          trig_side,

    input  wire logic [$clog2(SYM_COUNT)-1:0]  dbg_sym,
    output wire logic [PRICE_W-1:0]            dbg_bid_px,
    output wire logic [QTY_W-1:0]              dbg_bid_qty,
    output wire logic [PRICE_W-1:0]            dbg_ask_px,
    output wire logic [QTY_W-1:0]              dbg_ask_qty
);

    localparam USER_W = 1 + TS_W;

    taxi_axis_if #(.DATA_W(64), .USER_EN(1), .USER_W(USER_W)) axis_snoop();

    assign axis_snoop.tdata  = axis_mon.tdata;
    assign axis_snoop.tkeep  = axis_mon.tkeep;
    assign axis_snoop.tstrb  = axis_mon.tstrb;
    assign axis_snoop.tlast  = axis_mon.tlast;
    assign axis_snoop.tid    = '0;
    assign axis_snoop.tdest  = '0;
    assign axis_snoop.tuser  = axis_mon.tuser;

    assign axis_snoop.tvalid = axis_mon.tvalid && axis_mon.tready;

    taxi_axis_if #(.DATA_W(64), .USER_EN(1), .USER_W(USER_W)) axis_fifo();

    wire fifo_ovf;
    assign fifo_overflow = fifo_ovf;

    taxi_axis_async_fifo #(
        .DEPTH(FIFO_DEPTH),
        .FRAME_FIFO(1'b1),
        .DROP_OVERSIZE_FRAME(1'b1),
        .DROP_BAD_FRAME(1'b1),
        .DROP_WHEN_FULL(1'b1),
        .USER_BAD_FRAME_VALUE(1'b1),
        .USER_BAD_FRAME_MASK(1'b1)
    ) fifo (
        .s_clk(clk), .s_rst(rst), .s_axis(axis_snoop),
        .m_clk(clk), .m_rst(rst), .m_axis(axis_fifo),
        .s_pause_req(1'b0), .m_pause_req(1'b0),
        .s_pause_ack(), .m_pause_ack(),
        .s_status_depth(), .s_status_depth_commit(),
        .s_status_overflow(fifo_ovf), .s_status_bad_frame(), .s_status_good_frame(),
        .m_status_depth(), .m_status_depth_commit(),
        .m_status_overflow(), .m_status_bad_frame(), .m_status_good_frame()
    );

    taxi_axis_if #(.DATA_W(8), .USER_EN(1), .USER_W(USER_W)) axis_dec();

    taxi_axis_adapter dn (
        .clk(clk), .rst(rst),
        .s_axis(axis_fifo),
        .m_axis(axis_dec)
    );

    taxi_axis_if #(.DATA_W(64), .USER_EN(1), .USER_W(1)) axis_delta();
    assign axis_delta.tready = 1'b1;

    itch_decode #(
        .SYM_COUNT(SYM_COUNT),
        .LEVELS(LEVELS),
        .ORDER_COUNT(ORDER_COUNT),
        .PRICE_W(PRICE_W),
        .QTY_W(QTY_W),
        .ORDER_REF_W(ORDER_REF_W),
        .TS_W(TS_W),
        .HDR_SKIP_BYTES(HDR_SKIP_BYTES)
    ) dec (
        .clk(clk), .rst(rst),
        .s_axis_rx(axis_dec),
        .m_axis_delta(axis_delta),
        .trig_valid(trig_valid),
        .trig_sym(trig_sym),
        .trig_side(trig_side),
        .cfg_imbalance_thresh(cfg_imbalance_thresh),
        .ladder_overflow(ladder_overflow),
        .dbg_sym(dbg_sym),
        .dbg_bid_px(dbg_bid_px),
        .dbg_bid_qty(dbg_bid_qty),
        .dbg_ask_px(dbg_ask_px),
        .dbg_ask_qty(dbg_ask_qty)
    );

endmodule

`resetall
