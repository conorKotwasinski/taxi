`resetall
`timescale 1ns / 1ps
`default_nettype none

module itch_delta_dma #
(

    parameter REC_BYTES     = 32,

    parameter RING_ENTRIES  = 4096,

    parameter ADDR_W        = 64,
    parameter LEN_W         = 16,
    parameter TAG_W         = 8
)
(
    input  wire logic              clk,
    input  wire logic              rst,

    taxi_axis_if.snk               s_axis_delta,

    taxi_dma_desc_if.req_src       m_desc_req,
    taxi_dma_desc_if.sts_snk       s_desc_sts,

    input  wire logic [ADDR_W-1:0] cfg_ring_base,
    input  wire logic              cfg_ring_enable,

    output wire logic [31:0]       prod_ptr,
    output wire logic              ring_overflow
);

    localparam RING_AW = $clog2(RING_ENTRIES);
    localparam REC_AW  = $clog2(REC_BYTES);

    typedef enum logic [1:0] {
        ST_IDLE,
        ST_REQ,
        ST_WAIT
    } state_t;

    state_t state_reg = ST_IDLE, state_next;

    localparam CNT_W = $clog2(REC_BYTES + 1);
    logic [CNT_W-1:0] rx_bytes_reg, rx_bytes_next;
    logic             rec_ready_reg, rec_ready_next;

    logic [RING_AW-1:0] wr_slot_reg,  wr_slot_next;
    logic [31:0]        prod_ptr_reg, prod_ptr_next;
    logic [TAG_W-1:0]   tag_reg,      tag_next;
    logic               ovf_reg,      ovf_next;

    wire       beat = s_axis_delta.tvalid && s_axis_delta.tready;
    localparam AXIS_BYTES = s_axis_delta.KEEP_W;

    assign s_axis_delta.tready = 1'b1;

    logic [ADDR_W-1:0] req_addr_reg;
    logic              req_valid_reg;
    assign m_desc_req.req_dst_addr = req_addr_reg;
    assign m_desc_req.req_src_addr = '0;
    assign m_desc_req.req_len      = LEN_W'(REC_BYTES);
    assign m_desc_req.req_tag      = tag_reg;
    assign m_desc_req.req_valid    = req_valid_reg;
    assign m_desc_req.req_src_sel  = '0;
    assign m_desc_req.req_src_asid = '0;
    assign m_desc_req.req_dst_sel  = '0;
    assign m_desc_req.req_dst_asid = '0;
    assign m_desc_req.req_imm      = '0;
    assign m_desc_req.req_imm_en   = '0;
    assign m_desc_req.req_id       = '0;
    assign m_desc_req.req_dest     = '0;
    assign m_desc_req.req_user     = '0;

    assign prod_ptr      = prod_ptr_reg;
    assign ring_overflow = ovf_reg;

    always_comb begin
        state_next     = state_reg;
        rx_bytes_next  = rx_bytes_reg;
        rec_ready_next = rec_ready_reg;
        wr_slot_next   = wr_slot_reg;
        prod_ptr_next  = prod_ptr_reg;
        tag_next       = tag_reg;
        ovf_next       = 1'b0;

        if (beat) begin
            if (s_axis_delta.tlast) begin
                rx_bytes_next = '0;

                if (rec_ready_reg)
                    ovf_next = 1'b1;
                rec_ready_next = 1'b1;
            end else begin
                rx_bytes_next = rx_bytes_reg + CNT_W'(AXIS_BYTES);
            end
        end

        case (state_reg)
            ST_IDLE: begin
                if (rec_ready_reg && cfg_ring_enable) begin
                    state_next = ST_REQ;
                end
            end
            ST_REQ: begin
                if (m_desc_req.req_ready)
                    state_next = ST_WAIT;
            end
            ST_WAIT: begin
                if (s_desc_sts.sts_valid) begin

                    wr_slot_next   = (wr_slot_reg == RING_AW'(RING_ENTRIES-1)) ? '0 : wr_slot_reg + 1;
                    prod_ptr_next  = prod_ptr_reg + 1;
                    tag_next       = tag_reg + 1;
                    rec_ready_next = 1'b0;
                    state_next     = ST_IDLE;
                end
            end
            default: state_next = ST_IDLE;
        endcase
    end

    always_ff @(posedge clk) begin
        state_reg     <= state_next;
        rx_bytes_reg  <= rx_bytes_next;
        rec_ready_reg <= rec_ready_next;
        wr_slot_reg   <= wr_slot_next;
        prod_ptr_reg  <= prod_ptr_next;
        tag_reg       <= tag_next;
        ovf_reg       <= ovf_next;

        if (state_reg == ST_REQ) begin
            req_valid_reg <= 1'b1;
            req_addr_reg  <= cfg_ring_base + (ADDR_W'(wr_slot_reg) << REC_AW);
        end else if (m_desc_req.req_ready) begin
            req_valid_reg <= 1'b0;
        end

        if (rst) begin
            state_reg     <= ST_IDLE;
            rx_bytes_reg  <= '0;
            rec_ready_reg <= 1'b0;
            wr_slot_reg   <= '0;
            prod_ptr_reg  <= '0;
            tag_reg       <= '0;
            ovf_reg       <= 1'b0;
            req_valid_reg <= 1'b0;
        end
    end

endmodule

`resetall
