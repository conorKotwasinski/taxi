
`resetall
`timescale 1ns / 1ps
`default_nettype none

module itch_order_emit #
(
    parameter NBEATS = 8
)
(
    input  wire logic   clk,
    input  wire logic   rst,

    input  wire logic   trig,

    taxi_axis_if.src    m_axis_tx
);

    localparam CL_BEATS = $clog2(NBEATS);

    logic              active_reg = 1'b0;
    logic [CL_BEATS-1:0] beat_reg = '0;

    logic [63:0] beat_data;
    always_comb begin
        case (beat_reg)
            3'd0: beat_data = 64'h00000000_00000002;
            3'd1: beat_data = 64'h4f000008_00000000;
            3'd2: beat_data = 64'h00000000_5244_5200;
            3'd3: beat_data = 64'h00000064_00015000;
            3'd4: beat_data = 64'h00000000_00000000;
            3'd5: beat_data = 64'h00000000_00000000;
            3'd6: beat_data = 64'h00000000_00000000;
            default: beat_data = 64'h00000000_00000000;
        endcase
    end

    assign m_axis_tx.tdata  = beat_data;
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
