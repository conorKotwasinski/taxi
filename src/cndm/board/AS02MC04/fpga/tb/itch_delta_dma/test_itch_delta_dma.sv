`resetall
`timescale 1ns / 1ps
`default_nettype none

module test_itch_delta_dma #
(

    parameter REC_BYTES    = 32,
    parameter RING_ENTRIES = 8,
    parameter ADDR_W       = 64,
    parameter LEN_W        = 16,
    parameter TAG_W        = 8

)
();

logic clk;
logic rst;

taxi_axis_if #(.DATA_W(64), .USER_EN(1), .USER_W(1)) s_axis_delta();

taxi_dma_desc_if #(.DST_ADDR_W(ADDR_W), .LEN_W(LEN_W), .TAG_W(TAG_W)) desc();

logic [ADDR_W-1:0] cfg_ring_base;
logic              cfg_ring_enable;
logic [31:0]       prod_ptr;
logic              ring_overflow;

itch_delta_dma #(
    .REC_BYTES(REC_BYTES),
    .RING_ENTRIES(RING_ENTRIES),
    .ADDR_W(ADDR_W),
    .LEN_W(LEN_W),
    .TAG_W(TAG_W)
)
uut (
    .clk(clk),
    .rst(rst),
    .s_axis_delta(s_axis_delta),
    .m_desc_req(desc),
    .s_desc_sts(desc),
    .cfg_ring_base(cfg_ring_base),
    .cfg_ring_enable(cfg_ring_enable),
    .prod_ptr(prod_ptr),
    .ring_overflow(ring_overflow)
);

logic [ADDR_W-1:0] last_dst_addr;
logic [31:0]       accept_count;
logic [3:0]        sts_delay;

assign desc.req_ready = (sts_delay == 0);

assign desc.sts_len   = LEN_W'(REC_BYTES);
assign desc.sts_tag   = '0;
assign desc.sts_id    = '0;
assign desc.sts_dest  = '0;
assign desc.sts_user  = '0;
assign desc.sts_error = '0;

logic sts_valid_reg;
assign desc.sts_valid = sts_valid_reg;

always_ff @(posedge clk) begin
    sts_valid_reg <= 1'b0;
    if (rst) begin
        sts_delay     <= '0;
        last_dst_addr <= '0;
        accept_count  <= '0;
    end else begin
        if (desc.req_valid && desc.req_ready) begin
            last_dst_addr <= desc.req_dst_addr;
            accept_count  <= accept_count + 1;
            sts_delay     <= 4'd3;
        end else if (sts_delay > 1) begin
            sts_delay <= sts_delay - 1;
        end else if (sts_delay == 1) begin
            sts_delay     <= '0;
            sts_valid_reg <= 1'b1;
        end
    end
end

endmodule

`resetall
