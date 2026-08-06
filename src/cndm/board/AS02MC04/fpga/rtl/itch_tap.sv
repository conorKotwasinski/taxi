`resetall
`timescale 1ns / 1ps
`default_nettype none

module itch_tap #
(
    parameter SYM_COUNT      = 64,
    parameter LEVELS         = 8,
    parameter ORDER_COUNT    = 4096,
    parameter PRICE_W        = 32,
    parameter QTY_W          = 32,
    parameter ORDER_REF_W    = 64,
    parameter TS_W           = 48,
    parameter HDR_SKIP_BYTES = 14
)
(
    input  wire logic  clk,
    input  wire logic  rst,

    taxi_axis_if.snk   s_axis_rx,

    taxi_axis_if.src   m_axis_pass,

    input  wire logic [$clog2(SYM_COUNT)-1:0]  dbg_sym,
    output wire logic [PRICE_W-1:0]            dbg_bid_px,
    output wire logic [QTY_W-1:0]              dbg_bid_qty,
    output wire logic [PRICE_W-1:0]            dbg_ask_px,
    output wire logic [QTY_W-1:0]              dbg_ask_qty
);

    localparam USER_W = 1 + TS_W;

    taxi_axis_if #(.DATA_W(64), .USER_EN(1), .USER_W(USER_W)) axis_bc[2]();

    taxi_axis_broadcast #(.M_COUNT(2)) bc (
        .clk(clk), .rst(rst),
        .s_axis(s_axis_rx),
        .m_axis(axis_bc)
    );

    assign m_axis_pass.tdata  = axis_bc[0].tdata;
    assign m_axis_pass.tkeep  = axis_bc[0].tkeep;
    assign m_axis_pass.tstrb  = axis_bc[0].tstrb;
    assign m_axis_pass.tlast  = axis_bc[0].tlast;
    assign m_axis_pass.tid    = axis_bc[0].tid;
    assign m_axis_pass.tdest  = axis_bc[0].tdest;
    assign m_axis_pass.tuser  = axis_bc[0].tuser;
    assign m_axis_pass.tvalid = axis_bc[0].tvalid;
    assign axis_bc[0].tready  = m_axis_pass.tready;

    taxi_axis_if #(.DATA_W(8), .USER_EN(1), .USER_W(USER_W)) axis_dec();

    taxi_axis_adapter dn (
        .clk(clk), .rst(rst),
        .s_axis(axis_bc[1]),
        .m_axis(axis_dec)
    );

    taxi_axis_if #(.DATA_W(64), .USER_EN(1), .USER_W(1)) axis_delta();
    assign axis_delta.tready = 1'b1;

    logic                          trig_valid;
    logic [$clog2(SYM_COUNT)-1:0]  trig_sym;

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
        .cfg_imbalance_thresh('0),
        .dbg_sym(dbg_sym),
        .dbg_bid_px(dbg_bid_px),
        .dbg_bid_qty(dbg_bid_qty),
        .dbg_ask_px(dbg_ask_px),
        .dbg_ask_qty(dbg_ask_qty)
    );

endmodule

`resetall
