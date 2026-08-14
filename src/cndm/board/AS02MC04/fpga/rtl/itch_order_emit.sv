`resetall
`timescale 1ns / 1ps
`default_nettype none

module itch_order_emit
(
    input  wire logic   clk,
    input  wire logic   rst,

    input  wire logic   trig,

    taxi_axis_if.src    m_axis_tx
);

    localparam DATA_W      = m_axis_tx.DATA_W;
    localparam BYTE_LANES  = DATA_W/8;
    localparam FRAME_BYTES = 64;
    localparam NBEATS      = FRAME_BYTES/BYTE_LANES;
    localparam CL_BEATS    = $clog2(NBEATS);

    localparam [FRAME_BYTES*8-1:0] FRAME = {
        64'h0000000000000000,
        64'h0000000000000000,
        64'h0000000000000000,
        64'h0000000000000000,
        64'h0000006400015000,
        64'h0000000052445200,
        64'h4f00000803000000,
        64'h0002ffffffffffff
    };

    logic                active_reg = 1'b0;
    logic [CL_BEATS-1:0] beat_reg = '0;

    wire [DATA_W-1:0] beat_rom[NBEATS];
    for (genvar i = 0; i < NBEATS; i = i + 1) begin : g_beat
        assign beat_rom[i] = FRAME[i*DATA_W +: DATA_W];
    end

    assign m_axis_tx.tdata  = beat_rom[beat_reg];
    assign m_axis_tx.tkeep  = '1;
    assign m_axis_tx.tstrb  = '1;
    assign m_axis_tx.tlast  = active_reg && (beat_reg == CL_BEATS'(NBEATS-1));
    assign m_axis_tx.tid    = '0;
    assign m_axis_tx.tdest  = '0;
    assign m_axis_tx.tuser  = '0;
    assign m_axis_tx.tvalid = active_reg;

    always_ff @(posedge clk) begin
        if (!active_reg) begin
            if (trig) begin
                active_reg <= 1'b1;
                beat_reg   <= '0;
            end
        end else if (m_axis_tx.tready) begin
            if (beat_reg == CL_BEATS'(NBEATS-1))
                active_reg <= 1'b0;
            else
                beat_reg <= beat_reg + 1;
        end

        if (rst) begin
            active_reg <= 1'b0;
            beat_reg   <= '0;
        end
    end

endmodule

`resetall
