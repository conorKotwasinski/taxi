`resetall
`timescale 1ns / 1ps
`default_nettype none

module test_itch_order_emit #
(
    parameter DATA_W = 64
)
();

logic clk;
logic rst;
logic trig;

taxi_axis_if #(.DATA_W(DATA_W), .ID_W(8), .USER_EN(1), .USER_W(1)) axis_tx();
assign axis_tx.tready = 1'b1;

itch_order_emit
uut (
    .clk(clk),
    .rst(rst),
    .trig(trig),
    .m_axis_tx(axis_tx)
);

endmodule

`resetall
