`resetall
`timescale 1ns / 1ps
`default_nettype none

module itch_frame_gen #
(

    parameter INTERVAL = 32'd6250000
)
(
    input  wire logic   clk,
    input  wire logic   rst,

    taxi_axis_if.src    m_axis_tx
);

    localparam DATA_W      = m_axis_tx.DATA_W;
    localparam BYTE_LANES  = DATA_W/8;

    localparam FRAME_BYTES = 128;
    localparam NBEATS      = FRAME_BYTES/BYTE_LANES;
    localparam CL_BEATS    = $clog2(NBEATS);

    localparam [FRAME_BYTES*8-1:0] FRAME = {
        64'h60e3160020202020,
        64'h4c5041412c010000,
        64'h4203000000000000,
        64'h0000000000000000,
        64'h000000412400c4e3,
        64'h1600202020204c50,
        64'h4141c80000005302,
        64'h0000000000000000,
        64'h0000000000000000,
        64'h0041240060e31600,
        64'h202020204c504141,
        64'h6400000042010000,
        64'h0000000000000000,
        64'h0000000000000041,
        64'h2400000802000000,
        64'h0002ffffffffffff
    };

    logic [31:0]          timer_reg = '0;
    logic                 active_reg = 1'b0;
    logic [CL_BEATS-1:0]  beat_reg = '0;

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
            if (timer_reg == 0) begin
                active_reg <= 1'b1;
                beat_reg   <= '0;
                timer_reg  <= INTERVAL;
            end else begin
                timer_reg <= timer_reg - 1;
            end
        end else if (m_axis_tx.tready) begin
            if (beat_reg == CL_BEATS'(NBEATS-1))
                active_reg <= 1'b0;
            else
                beat_reg <= beat_reg + 1;
        end

        if (rst) begin
            timer_reg  <= INTERVAL;
            active_reg <= 1'b0;
            beat_reg   <= '0;
        end
    end

endmodule

`resetall
