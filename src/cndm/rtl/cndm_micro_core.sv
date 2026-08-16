// SPDX-License-Identifier: CERN-OHL-S-2.0
/*

Copyright (c) 2025 FPGA Ninja, LLC

Authors:
- Alex Forencich

*/

`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * Corundum-micro core logic
 */
module cndm_micro_core #(
    // simulation (set to avoid vendor primitives)
    parameter logic SIM = 1'b0,
    // vendor ("GENERIC", "XILINX", "ALTERA")
    parameter string VENDOR = "XILINX",
    // device family
    parameter string FAMILY = "virtexuplus",

    // FW ID
    parameter FPGA_ID = 32'hDEADBEEF,
    parameter FW_ID = 32'h0000C001,
    parameter FW_VER = 32'h000_01_000,
    parameter BOARD_ID = 32'h1234_0000,
    parameter BOARD_VER = 32'h001_00_000,
    parameter BUILD_DATE = 32'd602976000,
    parameter GIT_HASH = 32'h5f87c2e8,
    parameter RELEASE_INFO = 32'h00000000,

    // Structural configuration
    parameter PORTS = 2,
    parameter EXTRA_DMA_PORTS = 0,
    parameter logic BRD_CTRL_EN = 1'b0,
    parameter SYS_CLK_PER_NS_NUM = 4,
    parameter SYS_CLK_PER_NS_DEN = 1,

    // Queue configuration
    parameter WQN_W = 5,
    parameter CQN_W = WQN_W,

    // PTP configuration
    parameter logic PTP_TS_EN = 1'b1,
    parameter logic PTP_TS_FMT_TOD = 1'b0,
    parameter PTP_CLK_PER_NS_NUM = 512,
    parameter PTP_CLK_PER_NS_DEN = 165
)
(
    input  wire logic              clk,
    input  wire logic              rst,

    /*
     * Control register interface
     */
    taxi_axil_if.wr_slv            s_axil_ctrl_wr,
    taxi_axil_if.rd_slv            s_axil_ctrl_rd,

    /*
     * DMA
     */
    taxi_dma_desc_if.req_src       dma_rd_desc_req,
    taxi_dma_desc_if.sts_snk       dma_rd_desc_sts,
    taxi_dma_desc_if.req_src       dma_wr_desc_req,
    taxi_dma_desc_if.sts_snk       dma_wr_desc_sts,
    taxi_dma_ram_if.wr_slv         dma_ram_wr,
    taxi_dma_ram_if.rd_slv         dma_ram_rd,

    /*
     * Interrupts
     */
    taxi_axis_if.src               m_axis_irq,

    /*
     * Board control
     */
    taxi_axis_if.src               m_axis_brd_ctrl_cmd,
    taxi_axis_if.snk               s_axis_brd_ctrl_rsp,

    /*
     * PTP
     */
    input  wire logic              ptp_clk = 1'b0,
    input  wire logic              ptp_rst = 1'b0,
    input  wire logic              ptp_sample_clk = 1'b0,
    input  wire logic              ptp_td_sdi = 1'b0,
    output wire logic              ptp_td_sdo,
    output wire logic              ptp_pps,
    output wire logic              ptp_pps_str,
    output wire logic              ptp_sync_locked,
    output wire logic [63:0]       ptp_sync_ts_rel,
    output wire logic              ptp_sync_ts_rel_step,
    output wire logic [95:0]       ptp_sync_ts_tod,
    output wire logic              ptp_sync_ts_tod_step,
    output wire logic              ptp_sync_pps,
    output wire logic              ptp_sync_pps_str,

    /*
     * Ethernet
     */
    input  wire logic              mac_tx_clk[PORTS],
    input  wire logic              mac_tx_rst[PORTS],
    taxi_axis_if.src               mac_axis_tx[PORTS],
    taxi_axis_if.snk               mac_axis_tx_cpl[PORTS],

    input  wire logic              mac_rx_clk[PORTS],
    input  wire logic              mac_rx_rst[PORTS],
    taxi_axis_if.snk               mac_axis_rx[PORTS],

    taxi_axis_if.snk               s_axis_rec,
    input  wire logic [63:0]       rec_ring_base = '0,
    input  wire logic              rec_ring_enable = 1'b0,
    output wire logic [31:0]       rec_prod_ptr
);

localparam DMA_PORTS = PORTS + EXTRA_DMA_PORTS;
localparam CL_PORTS = $clog2(DMA_PORTS);

localparam AXIL_ADDR_W = s_axil_ctrl_wr.ADDR_W;
localparam AXIL_DATA_W = s_axil_ctrl_wr.DATA_W;

localparam RAM_SEGS = dma_ram_wr.SEGS;
localparam RAM_SEG_ADDR_W = dma_ram_wr.SEG_ADDR_W;
localparam RAM_SEG_DATA_W = dma_ram_wr.SEG_DATA_W;
localparam RAM_SEG_BE_W = dma_ram_wr.SEG_BE_W;
localparam RAM_SEL_W = dma_ram_wr.SEL_W;

localparam PTP_OFFSET_DP = 0;
localparam PORT_OFFSET_DP = PTP_OFFSET_DP + (PTP_TS_EN ? 1 : 0);
localparam PORT_OFFSET_HOST = 2;
localparam RING_CTRL_SLAVE = PORTS + PORT_OFFSET_HOST;
localparam AXIL_CTRL_M = PORTS + PORT_OFFSET_HOST + (EXTRA_DMA_PORTS > 0 ? 1 : 0);

localparam PTP_BASE_ADDR_DP = PTP_OFFSET_DP * 32'h00010000;
localparam PORT_BASE_ADDR_DP = PORT_OFFSET_DP * 32'h00010000;
localparam PORT_BASE_ADDR_HOST = PORT_OFFSET_HOST * 32'h00010000;

localparam SYS_CLK_CYC_PER_US = (1000*SYS_CLK_PER_NS_DEN+SYS_CLK_PER_NS_NUM-1)/SYS_CLK_PER_NS_NUM;

taxi_axil_if #(
    .DATA_W(s_axil_ctrl_wr.DATA_W),
    .ADDR_W(16),
    .STRB_W(s_axil_ctrl_wr.STRB_W),
    .AWUSER_EN(s_axil_ctrl_wr.AWUSER_EN),
    .AWUSER_W(s_axil_ctrl_wr.AWUSER_W),
    .WUSER_EN(s_axil_ctrl_wr.WUSER_EN),
    .WUSER_W(s_axil_ctrl_wr.WUSER_W),
    .BUSER_EN(s_axil_ctrl_wr.BUSER_EN),
    .BUSER_W(s_axil_ctrl_wr.BUSER_W),
    .ARUSER_EN(s_axil_ctrl_wr.ARUSER_EN),
    .ARUSER_W(s_axil_ctrl_wr.ARUSER_W),
    .RUSER_EN(s_axil_ctrl_wr.RUSER_EN),
    .RUSER_W(s_axil_ctrl_wr.RUSER_W)
)
axil_ctrl[AXIL_CTRL_M]();

taxi_axil_interconnect_1s #(
    .M_COUNT($size(axil_ctrl)),
    .ADDR_W(s_axil_ctrl_wr.ADDR_W),
    .M_REGIONS(1),
    .M_BASE_ADDR('0),
    .M_ADDR_W({$size(axil_ctrl){{1{32'd16}}}}),
    .M_SECURE({$size(axil_ctrl){1'b0}})
)
port_intercon_inst (
    .clk(clk),
    .rst(rst),

    /*
     * AXI4-lite slave interface
     */
    .s_axil_wr(s_axil_ctrl_wr),
    .s_axil_rd(s_axil_ctrl_rd),

    /*
     * AXI4-lite master interfaces
     */
    .m_axil_wr(axil_ctrl),
    .m_axil_rd(axil_ctrl)
);

logic s_axil_awready_reg = 1'b0;
logic s_axil_wready_reg = 1'b0;
logic s_axil_bvalid_reg = 1'b0;

logic s_axil_arready_reg = 1'b0;
logic [AXIL_DATA_W-1:0] s_axil_rdata_reg = '0;
logic s_axil_rvalid_reg = 1'b0;

assign axil_ctrl[0].awready = s_axil_awready_reg;
assign axil_ctrl[0].wready = s_axil_wready_reg;
assign axil_ctrl[0].bresp = '0;
assign axil_ctrl[0].buser = '0;
assign axil_ctrl[0].bvalid = s_axil_bvalid_reg;

assign axil_ctrl[0].arready = s_axil_arready_reg;
assign axil_ctrl[0].rdata = s_axil_rdata_reg;
assign axil_ctrl[0].rresp = '0;
assign axil_ctrl[0].ruser = '0;
assign axil_ctrl[0].rvalid = s_axil_rvalid_reg;

logic cmd_mbox_start_reg = 1'b0;
wire cmd_mbox_busy;

logic [95:0] get_ptp_ts_tod_reg = '0;
logic [63:0] get_ptp_ts_rel_reg = '0;

always_ff @(posedge clk) begin
    s_axil_awready_reg <= 1'b0;
    s_axil_wready_reg <= 1'b0;
    s_axil_bvalid_reg <= s_axil_bvalid_reg && !axil_ctrl[0].bready;

    s_axil_arready_reg <= 1'b0;
    s_axil_rvalid_reg <= s_axil_rvalid_reg && !axil_ctrl[0].rready;

    cmd_mbox_start_reg <= 1'b0;

    if (axil_ctrl[0].awvalid && axil_ctrl[0].wvalid && !s_axil_bvalid_reg) begin
        s_axil_awready_reg <= 1'b1;
        s_axil_wready_reg <= 1'b1;
        s_axil_bvalid_reg <= 1'b1;

        case ({axil_ctrl[0].awaddr[15:2], 2'b00})
            // 16'h0100: begin
            //     txq_en_reg <= axil_ctrl[0].wdata[0];
            //     txq_size_reg <= axil_ctrl[0].wdata[19:16];
            // end
            // 16'h0104: txq_prod_reg <= axil_ctrl[0].wdata[15:0];
            // 16'h0108: txq_base_addr_reg[31:0] <= axil_ctrl[0].wdata;
            // 16'h010c: txq_base_addr_reg[63:32] <= axil_ctrl[0].wdata;
            16'h0200: begin
                cmd_mbox_start_reg <= axil_ctrl[0].wdata[0];
            end
            default: begin end
        endcase
    end

    if (axil_ctrl[0].arvalid && !s_axil_rvalid_reg) begin
        s_axil_rdata_reg <= '0;

        s_axil_arready_reg <= 1'b1;
        s_axil_rvalid_reg <= 1'b1;

        case ({axil_ctrl[0].araddr[15:2], 2'b00})
            16'h0200: begin
                s_axil_rdata_reg[0] <= cmd_mbox_busy;
            end
            16'h0300: s_axil_rdata_reg <= {ptp_sync_ts_tod[15:0], 16'd0};  // PTP cur fns
            16'h0304: s_axil_rdata_reg <= ptp_sync_ts_tod[47:16];          // PTP cur ToD ns
            16'h0308: s_axil_rdata_reg <= ptp_sync_ts_tod[79:48];          // PTP cur ToD sec l
            16'h030C: s_axil_rdata_reg <= 32'(ptp_sync_ts_tod[95:80]);     // PTP cur ToD sec h
            16'h0310: s_axil_rdata_reg <= ptp_sync_ts_rel[47:16];          // PTP cur rel ns l
            16'h0314: s_axil_rdata_reg <= 32'(ptp_sync_ts_rel[63:48]);     // PTP cur rel ns h
            16'h0318: s_axil_rdata_reg <= '0;                              // PTP cur PTM l
            16'h031C: s_axil_rdata_reg <= '0;                              // PTP cur PTM h
            16'h0320: begin
                // PTP snapshot fns
                get_ptp_ts_tod_reg <= ptp_sync_ts_tod;
                get_ptp_ts_rel_reg <= ptp_sync_ts_rel;
                s_axil_rdata_reg <= {ptp_sync_ts_tod[15:0], 16'd0};
            end
            16'h0324: s_axil_rdata_reg <= 32'(get_ptp_ts_tod_reg[45:16]);  // PTP snapshot ToD ns
            16'h0328: s_axil_rdata_reg <= get_ptp_ts_tod_reg[79:48];       // PTP snapshot ToD sec l
            16'h032C: s_axil_rdata_reg <= 32'(get_ptp_ts_tod_reg[95:80]);  // PTP snapshot ToD sec h
            16'h0330: s_axil_rdata_reg <= get_ptp_ts_rel_reg[47:16];       // PTP snapshot rel ns l
            16'h0334: s_axil_rdata_reg <= 32'(get_ptp_ts_rel_reg[63:48]);  // PTP snapshot rel ns h
            16'h0338: s_axil_rdata_reg <= '0;                              // PTP snapshot PTM l
            16'h033C: s_axil_rdata_reg <= '0;                              // PTP snapshot PTM h
            default: begin end
        endcase
    end

    if (rst) begin
        s_axil_awready_reg <= 1'b0;
        s_axil_wready_reg <= 1'b0;
        s_axil_bvalid_reg <= 1'b0;

        s_axil_arready_reg <= 1'b0;
        s_axil_rvalid_reg <= 1'b0;
    end
end

// command mailbox
taxi_axis_if #(
    .DATA_W(32),
    .KEEP_EN(1),
    .LAST_EN(1),
    .ID_EN(0),
    .DEST_EN(0),
    .USER_EN(0)
) axis_cmd();

taxi_axis_if #(
    .DATA_W(32),
    .KEEP_EN(1),
    .LAST_EN(1),
    .ID_EN(0),
    .DEST_EN(0),
    .USER_EN(0)
) axis_rsp();

cndm_micro_cmd_mbox
cmd_mbox_inst (
    .clk(clk),
    .rst(rst),

    /*
     * AXI lite interface
     */
     .s_axil_wr(axil_ctrl[1]),
     .s_axil_rd(axil_ctrl[1]),

    /*
     * Control
     */
    .start(cmd_mbox_start_reg),
    .busy(cmd_mbox_busy),

    /*
     * Command interface
     */
    .m_axis_cmd(axis_cmd),
    .s_axis_rsp(axis_rsp)
);

// datapath manager

localparam APB_DP_ADDR_W = 16+$clog2(PORTS+PORT_OFFSET_DP);

taxi_apb_if #(
    .DATA_W(32),
    .ADDR_W(APB_DP_ADDR_W)
)
apb_dp_ctrl();

cndm_micro_dp_mgr #(
    // FW ID
    .FPGA_ID(FPGA_ID),
    .FW_ID(FW_ID),
    .FW_VER(FW_VER),
    .BOARD_ID(BOARD_ID),
    .BOARD_VER(BOARD_VER),
    .BUILD_DATE(BUILD_DATE),
    .GIT_HASH(GIT_HASH),
    .RELEASE_INFO(RELEASE_INFO),

    // Structural configuration
    .PORTS(PORTS),
    .BRD_CTRL_EN(BRD_CTRL_EN),
    .SYS_CLK_PER_NS_NUM(SYS_CLK_PER_NS_NUM),
    .SYS_CLK_PER_NS_DEN(SYS_CLK_PER_NS_DEN),

    // Queue configuration
    .EQN_W(CQN_W),
    .CQN_W(CQN_W),
    .SQN_W(WQN_W),
    .RQN_W(WQN_W),

    // PTP configuration
    .PTP_EN(PTP_TS_EN),
    .PTP_CLK_PER_NS_NUM(PTP_CLK_PER_NS_NUM),
    .PTP_CLK_PER_NS_DEN(PTP_CLK_PER_NS_DEN),

    // Addressing
    .PTP_BASE_ADDR_DP(PTP_BASE_ADDR_DP),
    .PORT_BASE_ADDR_DP(PORT_BASE_ADDR_DP),
    .PORT_BASE_ADDR_HOST(PORT_BASE_ADDR_HOST)
)
dp_mgr_inst (
    .clk(clk),
    .rst(rst),

    /*
     * Command interface
     */
    .s_axis_cmd(axis_cmd),
    .m_axis_rsp(axis_rsp),

    /*
     * APB master interface (datapath control)
     */
    .m_apb_dp_ctrl(apb_dp_ctrl),

    /*
     * Board control
     */
    .m_axis_brd_ctrl_cmd(m_axis_brd_ctrl_cmd),
    .s_axis_brd_ctrl_rsp(s_axis_brd_ctrl_rsp)
);

taxi_apb_if #(
    .DATA_W(32),
    .ADDR_W(16)
)
apb_port_dp_ctrl[PORT_OFFSET_DP+PORTS]();

taxi_apb_interconnect_1s #(
    .M_CNT($size(apb_port_dp_ctrl)),
    .ADDR_W(APB_DP_ADDR_W),
    .M_REGIONS(1),
    .M_BASE_ADDR('0),
    .M_ADDR_W({$size(apb_port_dp_ctrl){{1{32'd16}}}}),
    .M_SECURE({$size(apb_port_dp_ctrl){1'b0}})
)
port_dp_intercon_inst (
    .clk(clk),
    .rst(rst),

    /*
     * APB slave interface
     */
    .s_apb(apb_dp_ctrl),

    /*
     * APB master interfaces
     */
    .m_apb(apb_port_dp_ctrl)
);

if (PTP_TS_EN) begin : ptp

    taxi_ptp_td_phc_apb #(
        .PTP_CLK_PER_NS_NUM(PTP_CLK_PER_NS_NUM),
        .PTP_CLK_PER_NS_DENOM(PTP_CLK_PER_NS_DEN)
    )
    ptp_inst (
        .clk(clk),
        .rst(rst),

        /*
         * Control register interface
         */
        .s_apb(apb_port_dp_ctrl[PTP_OFFSET_DP]),

        /*
         * PTP
         */
        .ptp_clk(ptp_clk),
        .ptp_rst(ptp_rst),
        .ptp_sample_clk(ptp_sample_clk),
        .ptp_td_sdo(ptp_td_sdo),
        .ptp_pps(ptp_pps),
        .ptp_pps_str(ptp_pps_str),
        .ptp_sync_locked(ptp_sync_locked),
        .ptp_sync_ts_rel(ptp_sync_ts_rel),
        .ptp_sync_ts_rel_step(ptp_sync_ts_rel_step),
        .ptp_sync_ts_tod(ptp_sync_ts_tod),
        .ptp_sync_ts_tod_step(ptp_sync_ts_tod_step),
        .ptp_sync_pps(ptp_sync_pps),
        .ptp_sync_pps_str(ptp_sync_pps_str)
    );

end else begin : ptp

    assign ptp_td_sdo = 1'b0;
    assign ptp_pps = 1'b0;
    assign ptp_pps_str = 1'b0;
    assign ptp_sync_locked = 1'b0;
    assign ptp_sync_ts_rel = '0;
    assign ptp_sync_ts_rel_step = 1'b0;
    assign ptp_sync_ts_tod = '0;
    assign ptp_sync_ts_tod_step = 1'b0;
    assign ptp_sync_pps = 1'b0;
    assign ptp_sync_pps_str = 1'b0;

end

taxi_dma_desc_if #(
    .SRC_ADDR_W(dma_rd_desc_req.SRC_ADDR_W),
    .SRC_SEL_EN(dma_rd_desc_req.SRC_SEL_EN),
    .SRC_SEL_W(dma_rd_desc_req.SRC_SEL_W),
    .SRC_ASID_EN(dma_rd_desc_req.SRC_ASID_EN),
    .DST_ADDR_W(dma_rd_desc_req.DST_ADDR_W),
    .DST_SEL_EN(dma_rd_desc_req.DST_SEL_EN),
    .DST_SEL_W(dma_rd_desc_req.DST_SEL_W-CL_PORTS),
    .DST_ASID_EN(dma_rd_desc_req.DST_ASID_EN),
    .IMM_EN(dma_rd_desc_req.IMM_EN),
    .LEN_W(dma_rd_desc_req.LEN_W),
    .TAG_W(dma_rd_desc_req.TAG_W-CL_PORTS),
    .ID_EN(dma_rd_desc_req.ID_EN),
    .DEST_EN(dma_rd_desc_req.DEST_EN),
    .USER_EN(dma_rd_desc_req.USER_EN)
) dma_rd_desc_int[DMA_PORTS]();

taxi_dma_desc_if #(
    .SRC_ADDR_W(dma_wr_desc_req.SRC_ADDR_W),
    .SRC_SEL_EN(dma_wr_desc_req.SRC_SEL_EN),
    .SRC_SEL_W(dma_wr_desc_req.SRC_SEL_W-CL_PORTS),
    .SRC_ASID_EN(dma_wr_desc_req.SRC_ASID_EN),
    .DST_ADDR_W(dma_wr_desc_req.DST_ADDR_W),
    .DST_SEL_EN(dma_wr_desc_req.DST_SEL_EN),
    .DST_SEL_W(dma_wr_desc_req.DST_SEL_W),
    .DST_ASID_EN(dma_wr_desc_req.DST_ASID_EN),
    .IMM_EN(dma_wr_desc_req.IMM_EN),
    .IMM_W(dma_wr_desc_req.IMM_W),
    .LEN_W(dma_wr_desc_req.LEN_W),
    .TAG_W(dma_wr_desc_req.TAG_W-CL_PORTS),
    .ID_EN(dma_wr_desc_req.ID_EN),
    .DEST_EN(dma_wr_desc_req.DEST_EN),
    .USER_EN(dma_wr_desc_req.USER_EN)
) dma_wr_desc_int[DMA_PORTS]();

taxi_dma_ram_if #(
    .SEGS(RAM_SEGS),
    .SEG_ADDR_W(RAM_SEG_ADDR_W),
    .SEG_DATA_W(RAM_SEG_DATA_W),
    .SEG_BE_W(RAM_SEG_BE_W),
    .SEL_W(RAM_SEL_W-CL_PORTS)
) dma_ram_int[DMA_PORTS]();

taxi_dma_if_mux #(
    .PORTS(DMA_PORTS),
    .ARB_ROUND_ROBIN(1),
    .ARB_LSB_HIGH_PRIO(1)
)
dma_mux_inst (
    .clk(clk),
    .rst(rst),

    /*
     * DMA descriptors from clients
     */
    .client_rd_req(dma_rd_desc_int),
    .client_rd_sts(dma_rd_desc_int),
    .client_wr_req(dma_wr_desc_int),
    .client_wr_sts(dma_wr_desc_int),

    /*
     * DMA descriptors to DMA engines
     */
    .dma_rd_req(dma_rd_desc_req),
    .dma_rd_sts(dma_rd_desc_sts),
    .dma_wr_req(dma_wr_desc_req),
    .dma_wr_sts(dma_wr_desc_sts),

    /*
     * RAM interface (from DMA interface)
     */
    .dma_ram_wr(dma_ram_wr),
    .dma_ram_rd(dma_ram_rd),

    /*
     * RAM interface (towards RAM)
     */
    .client_ram_wr(dma_ram_int),
    .client_ram_rd(dma_ram_int)
);

if (EXTRA_DMA_PORTS > 0) begin : g_rec_dma
    localparam e = PORTS;

    localparam logic [31:0] REC_RING_MAGIC = 32'h52454331;
    logic [63:0] ring_base_reg = '0;
    logic        ring_enable_reg = 1'b0;
    logic        rc_awready_reg = 1'b0, rc_wready_reg = 1'b0, rc_bvalid_reg = 1'b0;
    logic        rc_arready_reg = 1'b0, rc_rvalid_reg = 1'b0;
    logic [31:0] rc_rdata_reg = '0;

    assign axil_ctrl[RING_CTRL_SLAVE].awready = rc_awready_reg;
    assign axil_ctrl[RING_CTRL_SLAVE].wready  = rc_wready_reg;
    assign axil_ctrl[RING_CTRL_SLAVE].bresp   = '0;
    assign axil_ctrl[RING_CTRL_SLAVE].buser   = '0;
    assign axil_ctrl[RING_CTRL_SLAVE].bvalid  = rc_bvalid_reg;
    assign axil_ctrl[RING_CTRL_SLAVE].arready = rc_arready_reg;
    assign axil_ctrl[RING_CTRL_SLAVE].rdata   = rc_rdata_reg;
    assign axil_ctrl[RING_CTRL_SLAVE].rresp   = '0;
    assign axil_ctrl[RING_CTRL_SLAVE].ruser   = '0;
    assign axil_ctrl[RING_CTRL_SLAVE].rvalid  = rc_rvalid_reg;

    always_ff @(posedge clk) begin
        rc_awready_reg <= 1'b0;
        rc_wready_reg  <= 1'b0;
        rc_bvalid_reg  <= rc_bvalid_reg && !axil_ctrl[RING_CTRL_SLAVE].bready;
        rc_arready_reg <= 1'b0;
        rc_rvalid_reg  <= rc_rvalid_reg && !axil_ctrl[RING_CTRL_SLAVE].rready;

        if (axil_ctrl[RING_CTRL_SLAVE].awvalid && axil_ctrl[RING_CTRL_SLAVE].wvalid
                && !rc_bvalid_reg) begin
            rc_awready_reg <= 1'b1;
            rc_wready_reg  <= 1'b1;
            rc_bvalid_reg  <= 1'b1;
            case ({axil_ctrl[RING_CTRL_SLAVE].awaddr[15:2], 2'b00})
                16'h0004: ring_base_reg[31:0]  <= axil_ctrl[RING_CTRL_SLAVE].wdata;
                16'h0008: ring_base_reg[63:32] <= axil_ctrl[RING_CTRL_SLAVE].wdata;
                16'h000C: ring_enable_reg      <= axil_ctrl[RING_CTRL_SLAVE].wdata[0];
                default: begin end
            endcase
        end

        if (axil_ctrl[RING_CTRL_SLAVE].arvalid && !rc_rvalid_reg) begin
            rc_arready_reg <= 1'b1;
            rc_rvalid_reg  <= 1'b1;
            case ({axil_ctrl[RING_CTRL_SLAVE].araddr[15:2], 2'b00})
                16'h0000: rc_rdata_reg <= REC_RING_MAGIC;
                16'h0004: rc_rdata_reg <= ring_base_reg[31:0];
                16'h0008: rc_rdata_reg <= ring_base_reg[63:32];
                16'h000C: rc_rdata_reg <= {31'd0, ring_enable_reg};
                default:  rc_rdata_reg <= '0;
            endcase
        end

        if (rst) begin
            ring_base_reg   <= '0;
            ring_enable_reg <= 1'b0;
            rc_bvalid_reg   <= 1'b0;
            rc_rvalid_reg   <= 1'b0;
        end
    end

    assign dma_rd_desc_int[e].req_src_addr = '0;
    assign dma_rd_desc_int[e].req_dst_addr = '0;
    assign dma_rd_desc_int[e].req_len      = '0;
    assign dma_rd_desc_int[e].req_tag      = '0;
    assign dma_rd_desc_int[e].req_src_sel  = '0;
    assign dma_rd_desc_int[e].req_src_asid = '0;
    assign dma_rd_desc_int[e].req_dst_sel  = '0;
    assign dma_rd_desc_int[e].req_dst_asid = '0;
    assign dma_rd_desc_int[e].req_imm      = '0;
    assign dma_rd_desc_int[e].req_imm_en   = '0;
    assign dma_rd_desc_int[e].req_id       = '0;
    assign dma_rd_desc_int[e].req_dest     = '0;
    assign dma_rd_desc_int[e].req_user     = '0;
    assign dma_rd_desc_int[e].req_valid    = 1'b0;

    assign dma_ram_int[e].wr_cmd_ready  = '1;
    assign dma_ram_int[e].wr_done       = '0;

    cndm_axis_rec_dma #(
        .REC_BYTES(32),
        .RING_ENTRIES(4096),
        .ADDR_W(64),
        .LEN_W(dma_wr_desc_int[e].LEN_W),
        .TAG_W(dma_wr_desc_int[e].TAG_W),
        .RAM_SEGS(RAM_SEGS),
        .RAM_SEG_ADDR_W(RAM_SEG_ADDR_W),
        .RAM_SEG_DATA_W(RAM_SEG_DATA_W),
        .RAM_SEG_BE_W(RAM_SEG_BE_W),
        .RAM_SEL_W(RAM_SEL_W-CL_PORTS)
    )
    itch_delta_dma_inst (
        .clk(clk),
        .rst(rst),
        .s_axis_rec(s_axis_rec),
        .m_host_desc_req(dma_wr_desc_int[e]),
        .s_host_desc_sts(dma_wr_desc_int[e]),
        .dma_ram_rd(dma_ram_int[e]),
        .cfg_ring_base(ring_base_reg),
        .cfg_ring_enable(ring_enable_reg),
        .prod_ptr(rec_prod_ptr)
    );
end else begin : g_no_rec_dma
    assign s_axis_rec.tready = 1'b1;
    assign rec_prod_ptr = '0;
end

taxi_axis_if #(
    .DATA_W(m_axis_irq.DATA_W),
    .KEEP_EN(0),
    .KEEP_W(1)
) axis_irq_int(), axis_irq_port[PORTS]();

taxi_axis_arb_mux #(
    .S_COUNT($size(axis_irq_port)),
    .ARB_ROUND_ROBIN(1),
    .ARB_LSB_HIGH_PRIO(1)
)
irq_mux_inst (
    .clk(clk),
    .rst(rst),

    /*
     * AXI4-Stream input (sink)
     */
    .s_axis(axis_irq_port),

    /*
     * AXI4-Stream output (source)
     */
    .m_axis(axis_irq_int)
);

taxi_irq_rate_limit
irq_rate_limit_inst (
    .clk(clk),
    .rst(rst),

    /*
     * Interrupt request input
     */
    .s_axis_irq(axis_irq_int),

    /*
     * Interrupt request output
     */
    .m_axis_irq(m_axis_irq),

    /*
     * Configuration
     */
    .prescale(16'(SYS_CLK_CYC_PER_US)),
    .min_interval(10) // TODO make configurable
);

for (genvar p = 0; p < PORTS; p = p + 1) begin : port

    cndm_micro_port #(
        // Queue configuration
        .WQN_W(WQN_W),
        .CQN_W(CQN_W),

        // PTP configuration
        .PTP_TS_EN(PTP_TS_EN),
        .PTP_TS_FMT_TOD(PTP_TS_FMT_TOD)
    )
    port_inst (
        .clk(clk),
        .rst(rst),

        /*
         * Control register interface
         */
        .s_axil_ctrl_wr(axil_ctrl[PORT_OFFSET_HOST+p]),
        .s_axil_ctrl_rd(axil_ctrl[PORT_OFFSET_HOST+p]),

        /*
         * Datapath control register interface
         */
        .s_apb_dp_ctrl(apb_port_dp_ctrl[PORT_OFFSET_DP+p]),

        /*
         * DMA
         */
        .dma_rd_desc_req(dma_rd_desc_int[p]),
        .dma_rd_desc_sts(dma_rd_desc_int[p]),
        .dma_wr_desc_req(dma_wr_desc_int[p]),
        .dma_wr_desc_sts(dma_wr_desc_int[p]),
        .dma_ram_wr(dma_ram_int[p]),
        .dma_ram_rd(dma_ram_int[p]),

        /*
         * Interrupts
         */
        .m_axis_irq(axis_irq_port[p]),

        /*
         * PTP
         */
        .ptp_clk(ptp_clk),
        .ptp_rst(ptp_rst),
        .ptp_td_sdi(ptp_td_sdo),

        /*
         * Ethernet
         */
        .mac_tx_clk(mac_tx_clk[p]),
        .mac_tx_rst(mac_tx_rst[p]),
        .mac_axis_tx(mac_axis_tx[p]),
        .mac_axis_tx_cpl(mac_axis_tx_cpl[p]),

        .mac_rx_clk(mac_rx_clk[p]),
        .mac_rx_rst(mac_rx_rst[p]),
        .mac_axis_rx(mac_axis_rx[p])
    );

end

endmodule

`resetall
