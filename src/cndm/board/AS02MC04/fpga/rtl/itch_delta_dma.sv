`resetall
`timescale 1ns / 1ps
`default_nettype none

module itch_delta_dma #
(
    parameter REC_BYTES     = 32,
    parameter RING_ENTRIES  = 4096,
    parameter ADDR_W        = 64,
    parameter LEN_W         = 20,
    parameter TAG_W         = 8,

    parameter RAM_SEGS      = 2,
    parameter RAM_SEG_ADDR_W = 12,
    parameter RAM_SEG_DATA_W = 128,
    parameter RAM_SEG_BE_W   = RAM_SEG_DATA_W/8,
    parameter RAM_SEL_W      = 2
)
(
    input  wire logic              clk,
    input  wire logic              rst,

    taxi_axis_if.snk               s_axis_delta,

    taxi_dma_desc_if.req_src       m_host_desc_req,
    taxi_dma_desc_if.sts_snk       s_host_desc_sts,

    taxi_dma_ram_if.rd_slv         dma_ram_rd,

    input  wire logic [ADDR_W-1:0] cfg_ring_base,
    input  wire logic              cfg_ring_enable,

    output wire logic [31:0]       prod_ptr,
    output wire logic              ring_overflow
);

    localparam RING_AW = $clog2(RING_ENTRIES);
    localparam REC_AW  = $clog2(REC_BYTES);
    localparam RAM_ADDR_W = RAM_SEG_ADDR_W + $clog2(RAM_SEGS*RAM_SEG_BE_W);

    taxi_dma_ram_if #(
        .SEGS(RAM_SEGS), .SEG_ADDR_W(RAM_SEG_ADDR_W),
        .SEG_DATA_W(RAM_SEG_DATA_W), .SEG_BE_W(RAM_SEG_BE_W), .SEL_W(RAM_SEL_W)
    ) ram_wr();

    taxi_dma_psdpram #(
        .SIZE(REC_BYTES*4)
    ) ram_inst (
        .clk(clk), .rst(rst),
        .dma_ram_wr(ram_wr),
        .dma_ram_rd(dma_ram_rd)
    );

    taxi_dma_desc_if #(
        .SRC_ADDR_W(RAM_ADDR_W), .DST_ADDR_W(RAM_ADDR_W),
        .LEN_W(16), .TAG_W(1), .USER_EN(1), .USER_W(s_axis_delta.USER_W)
    ) ram_desc();

    taxi_dma_client_axis_sink
    sink_inst (
        .clk(clk), .rst(rst),
        .desc_req(ram_desc),
        .desc_sts(ram_desc),
        .s_axis_wr_data(s_axis_delta),
        .dma_ram_wr(ram_wr),
        .enable(1'b1),
        .abort(1'b0)
    );

    typedef enum logic [1:0] {
        ST_ARM,
        ST_CAPTURE,
        ST_HOST,
        ST_WAIT
    } state_t;

    state_t state_reg = ST_ARM, state_next;

    logic [RING_AW-1:0] wr_slot_reg,  wr_slot_next;
    logic [31:0]        prod_ptr_reg, prod_ptr_next;
    logic [TAG_W-1:0]   tag_reg,      tag_next;
    logic [15:0]        cap_len_reg,  cap_len_next;
    logic               ovf_reg,      ovf_next;

    logic ram_req_valid_reg;
    assign ram_desc.req_src_addr = '0;
    assign ram_desc.req_dst_addr = '0;
    assign ram_desc.req_len      = 16'(REC_BYTES);
    assign ram_desc.req_tag      = '0;
    assign ram_desc.req_src_sel  = '0;
    assign ram_desc.req_src_asid = '0;
    assign ram_desc.req_dst_sel  = '0;
    assign ram_desc.req_dst_asid = '0;
    assign ram_desc.req_imm      = '0;
    assign ram_desc.req_imm_en   = '0;
    assign ram_desc.req_id       = '0;
    assign ram_desc.req_dest     = '0;
    assign ram_desc.req_user     = '0;
    assign ram_desc.req_valid    = ram_req_valid_reg;

    logic [ADDR_W-1:0] host_addr_reg;
    logic [LEN_W-1:0]  host_len_reg;
    logic              host_req_valid_reg;
    assign m_host_desc_req.req_src_addr = '0;
    assign m_host_desc_req.req_dst_addr = host_addr_reg;
    assign m_host_desc_req.req_len      = host_len_reg;
    assign m_host_desc_req.req_tag      = tag_reg;
    assign m_host_desc_req.req_src_sel  = '0;
    assign m_host_desc_req.req_src_asid = '0;
    assign m_host_desc_req.req_dst_sel  = '0;
    assign m_host_desc_req.req_dst_asid = '0;
    assign m_host_desc_req.req_imm      = '0;
    assign m_host_desc_req.req_imm_en   = '0;
    assign m_host_desc_req.req_id       = '0;
    assign m_host_desc_req.req_dest     = '0;
    assign m_host_desc_req.req_user     = '0;
    assign m_host_desc_req.req_valid    = host_req_valid_reg;

    assign prod_ptr      = prod_ptr_reg;
    assign ring_overflow = ovf_reg;

    always_comb begin
        state_next    = state_reg;
        wr_slot_next  = wr_slot_reg;
        prod_ptr_next = prod_ptr_reg;
        tag_next      = tag_reg;
        cap_len_next  = cap_len_reg;
        ovf_next      = 1'b0;

        case (state_reg)
            ST_ARM: begin

                if (cfg_ring_enable && ram_desc.req_ready)
                    state_next = ST_CAPTURE;
            end
            ST_CAPTURE: begin
                if (ram_desc.sts_valid) begin
                    cap_len_next = ram_desc.sts_len;
                    state_next   = ST_HOST;
                end
            end
            ST_HOST: begin
                if (m_host_desc_req.req_ready)
                    state_next = ST_WAIT;
            end
            ST_WAIT: begin
                if (s_host_desc_sts.sts_valid) begin
                    wr_slot_next  = (wr_slot_reg == RING_AW'(RING_ENTRIES-1)) ? '0 : wr_slot_reg + 1;
                    prod_ptr_next = prod_ptr_reg + 1;
                    tag_next      = tag_reg + 1;
                    state_next    = ST_ARM;
                end
            end
            default: state_next = ST_ARM;
        endcase
    end

    always_ff @(posedge clk) begin
        state_reg    <= state_next;
        wr_slot_reg  <= wr_slot_next;
        prod_ptr_reg <= prod_ptr_next;
        tag_reg      <= tag_next;
        cap_len_reg  <= cap_len_next;
        ovf_reg      <= ovf_next;

        if (state_reg == ST_ARM && cfg_ring_enable)
            ram_req_valid_reg <= 1'b1;
        else if (ram_desc.req_ready)
            ram_req_valid_reg <= 1'b0;

        if (state_reg == ST_CAPTURE && ram_desc.sts_valid) begin
            host_req_valid_reg <= 1'b1;
            host_addr_reg      <= cfg_ring_base + (ADDR_W'(wr_slot_reg) << REC_AW);
            host_len_reg       <= LEN_W'(ram_desc.sts_len);
        end else if (m_host_desc_req.req_ready) begin
            host_req_valid_reg <= 1'b0;
        end

        if (rst) begin
            state_reg          <= ST_ARM;
            wr_slot_reg        <= '0;
            prod_ptr_reg       <= '0;
            tag_reg            <= '0;
            cap_len_reg        <= '0;
            ovf_reg            <= 1'b0;
            ram_req_valid_reg  <= 1'b0;
            host_req_valid_reg <= 1'b0;
        end
    end

endmodule

`resetall
