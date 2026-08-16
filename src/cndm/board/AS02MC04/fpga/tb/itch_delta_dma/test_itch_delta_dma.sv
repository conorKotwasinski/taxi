`resetall
`timescale 1ns / 1ps
`default_nettype none

module test_itch_delta_dma #
(

    parameter REC_BYTES    = 32,
    parameter RING_ENTRIES = 8,
    parameter ADDR_W       = 64,
    parameter LEN_W        = 20,
    parameter TAG_W        = 8,
    parameter RAM_SEGS       = 2,
    parameter RAM_SEG_ADDR_W = 12,
    parameter RAM_SEG_DATA_W = 128,
    parameter RAM_SEG_BE_W   = RAM_SEG_DATA_W/8,
    parameter RAM_SEL_W      = 2

)
();

logic clk;
logic rst;

taxi_axis_if #(.DATA_W(64), .USER_EN(1), .USER_W(1)) s_axis_delta();

taxi_dma_desc_if #(.SRC_ADDR_W(16), .DST_ADDR_W(ADDR_W), .LEN_W(LEN_W), .TAG_W(TAG_W))
    host_desc();

taxi_dma_ram_if #(
    .SEGS(RAM_SEGS), .SEG_ADDR_W(RAM_SEG_ADDR_W),
    .SEG_DATA_W(RAM_SEG_DATA_W), .SEG_BE_W(RAM_SEG_BE_W), .SEL_W(RAM_SEL_W)
) dma_ram_rd();

logic [ADDR_W-1:0] cfg_ring_base;
logic              cfg_ring_enable;
logic [31:0]       prod_ptr;
logic              ring_busy;

cndm_axis_rec_dma #(
    .REC_BYTES(REC_BYTES), .RING_ENTRIES(RING_ENTRIES),
    .ADDR_W(ADDR_W), .LEN_W(LEN_W), .TAG_W(TAG_W),
    .RAM_SEGS(RAM_SEGS), .RAM_SEG_ADDR_W(RAM_SEG_ADDR_W),
    .RAM_SEG_DATA_W(RAM_SEG_DATA_W), .RAM_SEG_BE_W(RAM_SEG_BE_W),
    .RAM_SEL_W(RAM_SEL_W)
)
uut (
    .clk(clk), .rst(rst),
    .s_axis_rec(s_axis_delta),
    .m_host_desc_req(host_desc),
    .s_host_desc_sts(host_desc),
    .dma_ram_rd(dma_ram_rd),
    .cfg_ring_base(cfg_ring_base),
    .cfg_ring_enable(cfg_ring_enable),
    .prod_ptr(prod_ptr),
    .ring_busy(ring_busy)
);

localparam SEG_BYTES = RAM_SEG_DATA_W/8;

logic [ADDR_W-1:0] last_dst_addr;
logic [31:0]       accept_count;
logic [8*REC_BYTES-1:0] captured;

typedef enum logic [1:0] {M_IDLE, M_READ, M_DONE} mstate_t;
mstate_t ms = M_IDLE;

logic [15:0] rd_off;
logic [ADDR_W-1:0] dst_hold;
logic [LEN_W-1:0]  len_hold;

always_comb begin
    for (int s = 0; s < RAM_SEGS; s++) begin
        dma_ram_rd.rd_cmd_sel[s]   = '0;
        dma_ram_rd.rd_cmd_addr[s]  = '0;
        dma_ram_rd.rd_cmd_valid[s] = 1'b0;
        dma_ram_rd.rd_resp_ready[s] = 1'b1;
    end

    if (ms == M_READ) begin
        for (int s = 0; s < RAM_SEGS; s++) begin
            dma_ram_rd.rd_cmd_addr[s]  = '0;
            dma_ram_rd.rd_cmd_valid[s] = 1'b1;
        end
    end
end

assign host_desc.req_ready = (ms == M_IDLE);

assign host_desc.sts_len   = len_hold;
assign host_desc.sts_tag   = '0;
assign host_desc.sts_id    = '0;
assign host_desc.sts_dest  = '0;
assign host_desc.sts_user  = '0;
assign host_desc.sts_error = '0;
logic sts_valid_reg;
assign host_desc.sts_valid = sts_valid_reg;

always_ff @(posedge clk) begin
    sts_valid_reg <= 1'b0;
    if (rst) begin
        ms <= M_IDLE; rd_off <= '0; accept_count <= '0;
        last_dst_addr <= '0; captured <= '0;
    end else begin
        case (ms)
            M_IDLE: begin
                if (host_desc.req_valid && host_desc.req_ready) begin
                    dst_hold <= host_desc.req_dst_addr;
                    len_hold <= host_desc.req_len;
                    rd_off   <= '0;
                    ms       <= M_READ;
                end
            end
            M_READ: begin

                if (dma_ram_rd.rd_resp_valid[0]) begin
                    for (int s = 0; s < RAM_SEGS; s++)
                        captured[8*(s*SEG_BYTES) +: RAM_SEG_DATA_W] <= dma_ram_rd.rd_resp_data[s];
                    ms <= M_DONE;
                end
            end
            M_DONE: begin
                last_dst_addr <= dst_hold;
                accept_count  <= accept_count + 1;
                sts_valid_reg <= 1'b1;
                ms            <= M_IDLE;
            end
            default: ms <= M_IDLE;
        endcase
    end
end

endmodule

`resetall
