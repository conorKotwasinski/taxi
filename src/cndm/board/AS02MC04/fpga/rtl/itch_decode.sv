`resetall
`timescale 1ns / 1ps
`default_nettype none

module itch_decode #
(
    parameter SYM_COUNT       = 64,

    parameter LEVELS          = 16,
    parameter ORDER_COUNT     = 4096,
    parameter PRICE_W         = 32,
    parameter QTY_W           = 32,
    parameter ORDER_REF_W     = 64,
    parameter TS_W            = 48,
    parameter HDR_SKIP_BYTES  = 14
)
(
    input  wire logic              clk,
    input  wire logic              rst,

    taxi_axis_if.snk               s_axis_rx,

    taxi_axis_if.src               m_axis_delta,

    output wire logic                          trig_valid,
    output wire logic [$clog2(SYM_COUNT)-1:0]  trig_sym,
    output wire logic                          trig_side,
    input  wire logic [QTY_W-1:0]              cfg_imbalance_thresh,

    output wire logic                          ladder_overflow,
    output wire logic [15:0]                   dbg_delta_ovf,

    input  wire logic [$clog2(SYM_COUNT)-1:0]  dbg_sym,
    output wire logic [PRICE_W-1:0]            dbg_bid_px,
    output wire logic [QTY_W-1:0]              dbg_bid_qty,
    output wire logic [PRICE_W-1:0]            dbg_ask_px,
    output wire logic [QTY_W-1:0]              dbg_ask_qty,

    output wire logic [15:0]                   dbg_lat_last,
    output wire logic [15:0]                   dbg_lat_min,
    output wire logic [15:0]                   dbg_lat_max,
    output wire logic [15:0]                   dbg_tlat_last,
    output wire logic [15:0]                   dbg_tlat_min,
    output wire logic [15:0]                   dbg_tlat_max
);

    localparam DATA_W   = s_axis_rx.DATA_W;
    localparam LANES    = DATA_W/8;
    localparam SYM_AW   = $clog2(SYM_COUNT);
    localparam ORDER_AW = $clog2(ORDER_COUNT);
    localparam LVL_AW   = $clog2(LEVELS);

    if (DATA_W % 8 != 0)
        $fatal(0, "itch_decode: decode bus must be a multiple of 8 bits (instance %m)");

    localparam MSG_BUF_N = 64;
    localparam BIDX_W    = $clog2(MSG_BUF_N);

    localparam [7:0]
        T_ADD      = "A",
        T_ADD_MPID = "F",
        T_EXEC     = "E",
        T_EXEC_PX  = "C",
        T_CANCEL   = "X",
        T_DELETE   = "D",
        T_REPLACE  = "U";

    localparam [63:0] SYM_TICKER0 = "AAPL    ";
    localparam [63:0] SYM_TICKER1 = "MSFT    ";
    localparam [63:0] SYM_TICKER2 = "NVDA    ";
    localparam [63:0] SYM_TICKER3 = "AMZN    ";

    typedef enum logic [3:0] {
        STATE_IDLE,
        STATE_SKIP_HDR,
        STATE_MSG_LEN,
        STATE_MSG_BODY,
        STATE_DECODE,
        STATE_SEARCH,
        STATE_APPLY,
        STATE_WRITE,
        STATE_SCAN,
        STATE_PUB,
        STATE_DRAIN
    } state_t;

    state_t state_reg = STATE_IDLE, state_next;

    logic [TS_W-1:0]   ts_reg,       ts_next;

    logic [15:0] cyc_cnt;
    logic [15:0] t0_cyc;
    logic [15:0] lat_last, lat_min, lat_max;
    logic [15:0] tlat_last, tlat_min, tlat_max;   // ingress -> trigger (tick-to-trade detect)
    logic              bad_reg,      bad_next;
    logic [15:0]       skip_reg,     skip_next;
    logic [1:0]        lencnt_reg,   lencnt_next;
    logic [15:0]       msg_len_reg,  msg_len_next;
    logic [15:0]       msg_rem_reg,  msg_rem_next;
    logic [BIDX_W-1:0] bidx_reg,     bidx_next;
    logic              frame_done_reg, frame_done_next;

    logic [7:0] msg_buf [0:MSG_BUF_N-1];
    logic              msg_buf_wr   [0:LANES-1];
    logic [BIDX_W-1:0] msg_buf_widx [0:LANES-1];
    logic [7:0]        msg_buf_wb   [0:LANES-1];

    wire       beat = s_axis_rx.tvalid && s_axis_rx.tready;

    wire [7:0]  w_type   = msg_buf[0];

    wire [ORDER_REF_W-1:0] w_ref =
        {msg_buf[11], msg_buf[12], msg_buf[13], msg_buf[14],
         msg_buf[15], msg_buf[16], msg_buf[17], msg_buf[18]};

    wire [ORDER_REF_W-1:0] w_new_ref =
        {msg_buf[19], msg_buf[20], msg_buf[21], msg_buf[22],
         msg_buf[23], msg_buf[24], msg_buf[25], msg_buf[26]};

    wire        w_side_bid   = (msg_buf[19] == "B");
    wire [31:0] w_shares_add = {msg_buf[20], msg_buf[21], msg_buf[22], msg_buf[23]};
    wire [63:0] w_stock      = {msg_buf[24], msg_buf[25], msg_buf[26], msg_buf[27],
                                msg_buf[28], msg_buf[29], msg_buf[30], msg_buf[31]};
    wire [31:0] w_price_add  = {msg_buf[32], msg_buf[33], msg_buf[34], msg_buf[35]};

    wire [31:0] w_shares_exec = {msg_buf[19], msg_buf[20], msg_buf[21], msg_buf[22]};

    wire [31:0] w_shares_repl = {msg_buf[27], msg_buf[28], msg_buf[29], msg_buf[30]};
    wire [31:0] w_price_repl  = {msg_buf[31], msg_buf[32], msg_buf[33], msg_buf[34]};

    logic [SYM_AW-1:0] w_sym;
    logic              w_sym_tracked;
    always_comb begin
        w_sym         = '0;
        w_sym_tracked = 1'b1;
        case (w_stock)
            SYM_TICKER0: w_sym = 0;
            SYM_TICKER1: w_sym = 1;
            SYM_TICKER2: w_sym = 2;
            SYM_TICKER3: w_sym = 3;
            default:     w_sym_tracked = 1'b0;
        endcase
    end

    logic                    ord_valid [0:ORDER_COUNT-1] = '{default: 1'b0};
    logic [ORDER_REF_W-1:0]  ord_tag   [0:ORDER_COUNT-1];
    logic [SYM_AW-1:0]       ord_sym   [0:ORDER_COUNT-1];
    logic                    ord_side  [0:ORDER_COUNT-1];
    logic [PRICE_W-1:0]      ord_px    [0:ORDER_COUNT-1];
    logic [QTY_W-1:0]        ord_qty   [0:ORDER_COUNT-1];

    wire [ORDER_AW-1:0] ref_h     = w_ref[ORDER_AW-1:0];
    wire [ORDER_AW-1:0] new_ref_h = w_new_ref[ORDER_AW-1:0];

    wire                 l_hit  = ord_valid[ref_h] && (ord_tag[ref_h] == w_ref);
    wire [SYM_AW-1:0]    l_sym  = ord_sym[ref_h];
    wire                 l_side = ord_side[ref_h];
    wire [PRICE_W-1:0]   l_px   = ord_px[ref_h];
    wire [QTY_W-1:0]     l_qty  = ord_qty[ref_h];
    wire [QTY_W-1:0]     l_take = (l_qty < w_shares_exec) ? l_qty : w_shares_exec;

    localparam LAD_N = SYM_COUNT * 2 * LEVELS;

    function automatic int lad_base(input [SYM_AW-1:0] sym, input side);
        lad_base = (int'(sym) * 2 + int'(side)) * LEVELS;
    endfunction

    logic               lad_v  [0:LAD_N-1] = '{default: 1'b0};
    logic [PRICE_W-1:0] lad_px [0:LAD_N-1];
    logic [QTY_W-1:0]   lad_q  [0:LAD_N-1];

    logic [PRICE_W-1:0] tob_bid_px [0:SYM_COUNT-1];
    logic [QTY_W-1:0]   tob_bid_q  [0:SYM_COUNT-1];
    logic [PRICE_W-1:0] tob_ask_px [0:SYM_COUNT-1];
    logic [QTY_W-1:0]   tob_ask_q  [0:SYM_COUNT-1];

    wire [PRICE_W-1:0] scan_bid_px = tob_bid_px[dbg_sym];
    wire [QTY_W-1:0]   scan_bid_q  = tob_bid_q [dbg_sym];
    wire [PRICE_W-1:0] scan_ask_px = tob_ask_px[dbg_sym];
    wire [QTY_W-1:0]   scan_ask_q  = tob_ask_q [dbg_sym];

    wire decoding = (state_reg == STATE_DECODE) || (state_reg == STATE_SEARCH) ||
                    (state_reg == STATE_APPLY)  || (state_reg == STATE_WRITE)  ||
                    (state_reg == STATE_SCAN)   || (state_reg == STATE_PUB);
    assign s_axis_rx.tready = !decoding;

    logic              emit_active_reg;
    logic [1:0]        beat_idx_reg;
    logic [31:0]       seq_reg;
    logic [31:0]       seq_snap_reg;
    logic              delta_ovf_reg;
    logic [15:0]       delta_ovf_cnt;
    assign dbg_delta_ovf = delta_ovf_cnt;

    logic [TS_W-1:0]   snap_ts_reg;
    logic [SYM_AW-1:0] snap_sym_reg;
    logic [7:0]        snap_flags_reg;
    logic [PRICE_W-1:0] snap_bidpx_reg, snap_askpx_reg;
    logic [QTY_W-1:0]   snap_bidq_reg,  snap_askq_reg;

    logic [63:0] delta_beat;
    always_comb begin
        case (beat_idx_reg)
            2'd0: delta_beat = 64'(snap_ts_reg);
            2'd1: delta_beat = {snap_askpx_reg, snap_bidpx_reg};
            2'd2: delta_beat = {snap_askq_reg,  snap_bidq_reg};
            default: delta_beat = {seq_snap_reg, snap_flags_reg, 8'd0,
                                   {(16-SYM_AW){1'b0}}, snap_sym_reg};
        endcase
    end

    assign m_axis_delta.tdata  = delta_beat;
    assign m_axis_delta.tkeep  = '1;
    assign m_axis_delta.tstrb  = '1;
    assign m_axis_delta.tlast  = emit_active_reg && (beat_idx_reg == 2'd3);
    assign m_axis_delta.tid    = '0;
    assign m_axis_delta.tdest  = '0;
    assign m_axis_delta.tuser  = '0;
    assign m_axis_delta.tvalid = emit_active_reg;

    logic [SYM_AW-1:0] upd_sym_reg;
    logic              upd_pending_reg;

    wire [QTY_W-1:0]   tsym_bid_q  = tob_bid_q [upd_sym_reg];
    wire [QTY_W-1:0]   tsym_ask_q  = tob_ask_q [upd_sym_reg];
    wire [PRICE_W-1:0] tsym_bid_px = tob_bid_px[upd_sym_reg];
    wire [PRICE_W-1:0] tsym_ask_px = tob_ask_px[upd_sym_reg];

    wire inc_is_best = inc_side ? (inc_px == tsym_ask_px && tsym_ask_q != 0)
                                : (inc_px == tsym_bid_px && tsym_bid_q != 0);
    wire need_rescan = !inc_ok || (inc_is_best && inc_newq == 0);

    logic              trig_valid_reg;
    logic [SYM_AW-1:0] trig_sym_reg;
    logic              trig_side_reg;
    assign trig_valid = trig_valid_reg;
    assign trig_sym   = trig_sym_reg;
    assign trig_side  = trig_side_reg;

    assign dbg_bid_px  = scan_bid_px;
    assign dbg_bid_qty = scan_bid_q;
    assign dbg_ask_px  = scan_ask_px;
    assign dbg_ask_qty = scan_ask_q;
    assign dbg_lat_last = lat_last;
    assign dbg_lat_min  = lat_min;
    assign dbg_lat_max  = lat_max;
    assign dbg_tlat_last = tlat_last;
    assign dbg_tlat_min  = tlat_min;
    assign dbg_tlat_max  = tlat_max;

    logic overflow_reg;
    assign ladder_overflow = overflow_reg;

    always_comb begin
        state_next       = state_reg;
        ts_next          = ts_reg;
        bad_next         = bad_reg;
        skip_next        = skip_reg;
        lencnt_next      = lencnt_reg;
        msg_len_next     = msg_len_reg;
        msg_rem_next     = msg_rem_reg;
        bidx_next        = bidx_reg;
        frame_done_next  = frame_done_reg;
        for (int l = 0; l < LANES; l = l + 1) begin
            msg_buf_wr[l]   = 1'b0;
            msg_buf_widx[l] = '0;
            msg_buf_wb[l]   = '0;
        end

        if (state_reg == STATE_DECODE)
            state_next = STATE_SEARCH;

        if (state_reg == STATE_SEARCH && srch_i == (LVL_AW+1)'(LEVELS))
            state_next = STATE_APPLY;

        if (state_reg == STATE_APPLY)
            state_next = STATE_WRITE;

        if (state_reg == STATE_WRITE)
            state_next = need_rescan ? STATE_SCAN : STATE_PUB;

        if (state_reg == STATE_SCAN && scan_i == (LVL_AW+1)'(LEVELS))
            state_next = STATE_PUB;

        if (state_reg == STATE_PUB) begin
            if (frame_done_reg)
                state_next = STATE_IDLE;
            else begin
                state_next  = STATE_MSG_LEN;
                lencnt_next = 2'd2;
            end
        end

        if (beat) begin
            for (int l = 0; l < LANES; l = l + 1) begin
                automatic logic [7:0] cb = s_axis_rx.tdata[l*8 +: 8];
                case (state_next)
                STATE_IDLE: begin
                    ts_next   = s_axis_rx.tuser[1 +: TS_W];
                    bad_next  = s_axis_rx.tuser[0];
                    if (HDR_SKIP_BYTES <= 1) begin
                        state_next  = STATE_MSG_LEN;
                        lencnt_next = 2'd2;
                    end else begin
                        state_next = STATE_SKIP_HDR;
                        skip_next  = 16'(HDR_SKIP_BYTES - 1);
                    end
                end
                STATE_SKIP_HDR: begin
                    if (skip_next <= 1) begin
                        state_next  = STATE_MSG_LEN;
                        lencnt_next = 2'd2;
                    end else begin
                        skip_next = skip_next - 1;
                    end
                end
                STATE_MSG_LEN: begin
                    automatic logic [15:0] mlen = {msg_len_next[7:0], cb};
                    msg_len_next = mlen;
                    if (lencnt_next == 2'd1) begin
                        if (mlen == 16'd0) begin
                            state_next = STATE_DRAIN;
                        end else begin
                            msg_rem_next = mlen;
                            bidx_next    = '0;
                            state_next   = STATE_MSG_BODY;
                        end
                    end else begin
                        lencnt_next = lencnt_next - 1;
                    end
                end
                STATE_MSG_BODY: begin
                    msg_buf_wr[l]  = 1'b1;
                    msg_buf_widx[l]= bidx_next;
                    msg_buf_wb[l]  = cb;
                    bidx_next = bidx_next + 1;
                    if (msg_rem_next == 16'd1)
                        state_next = STATE_DECODE;
                    else
                        msg_rem_next = msg_rem_next - 1;
                end
                STATE_DRAIN: begin
                    state_next = STATE_DRAIN;
                end
                default: ;
                endcase
            end

            if (s_axis_rx.tlast) begin
                frame_done_next = 1'b1;
                if (state_next != STATE_DECODE)
                    state_next = STATE_IDLE;
            end
        end

        if (state_next == STATE_IDLE)
            frame_done_next = 1'b0;
    end

    logic [7:0]             d_type;
    logic [ORDER_REF_W-1:0] d_ref;
    logic                   d_sym_tracked;
    logic                   upd_valid_reg;
    logic [ORDER_AW-1:0]    d_ref_h, d_new_ref_h;
    logic [ORDER_REF_W-1:0] d_new_ref;
    logic [SYM_AW-1:0]      d_sym;
    logic                   d_side;
    logic [PRICE_W-1:0]     d_px_a, d_px_b;
    logic [QTY_W-1:0]       d_shares, d_take, d_l_qty;
    logic                   d_hit;
    logic [31:0]            d_base;

    logic [LVL_AW:0]    srch_i;
    logic [LVL_AW:0]    slot_a, slot_b, slot_free;
    logic [QTY_W-1:0]   slot_a_q, slot_b_q;

    logic               sr_vld, sr_v;
    logic [LVL_AW:0]    sr_i;
    logic [PRICE_W-1:0] sr_px;
    logic [QTY_W-1:0]   sr_q;

    logic [LVL_AW:0]    scan_i;
    logic               rd_vld, rd_vb, rd_va;
    logic [PRICE_W-1:0] rd_pxb, rd_pxa;
    logic [QTY_W-1:0]   rd_qb,  rd_qa;
    logic [PRICE_W-1:0] scan_bpx, scan_apx;
    logic [QTY_W-1:0]   scan_bq,  scan_aq;

    logic               inc_ok;
    logic               inc_side;
    logic [PRICE_W-1:0] inc_px;
    logic [QTY_W-1:0]   inc_newq;

    logic [QTY_W-1:0] rpl_q;

    logic               wrA_v_en, wrA_v, wrA_px_en, wrA_q_en;
    logic [31:0]        wrA_idx;
    logic [PRICE_W-1:0] wrA_px;
    logic [QTY_W-1:0]   wrA_q;
    logic               wrB_v_en, wrB_v, wrB_px_en, wrB_q_en;
    logic [31:0]        wrB_idx;
    logic [PRICE_W-1:0] wrB_px;
    logic [QTY_W-1:0]   wrB_q;

    always_ff @(posedge clk) begin
        state_reg      <= state_next;

        cyc_cnt <= cyc_cnt + 16'd1;
        ts_reg         <= ts_next;
        bad_reg        <= bad_next;
        skip_reg       <= skip_next;
        lencnt_reg     <= lencnt_next;
        msg_len_reg    <= msg_len_next;
        msg_rem_reg    <= msg_rem_next;
        bidx_reg       <= bidx_next;
        frame_done_reg <= frame_done_next;

        trig_valid_reg  <= 1'b0;

        if (upd_pending_reg) begin
            trig_sym_reg <= upd_sym_reg;
            if (tsym_bid_q > tsym_ask_q) begin
                trig_side_reg  <= 1'b0;
                trig_valid_reg <= (tsym_bid_q - tsym_ask_q) > cfg_imbalance_thresh;
            end else begin
                trig_side_reg  <= 1'b1;
                trig_valid_reg <= (tsym_ask_q - tsym_bid_q) > cfg_imbalance_thresh;
            end
            if (((tsym_bid_q > tsym_ask_q) ? (tsym_bid_q - tsym_ask_q)
                                           : (tsym_ask_q - tsym_bid_q)) > cfg_imbalance_thresh) begin
                tlat_last <= cyc_cnt - t0_cyc;
                if ((cyc_cnt - t0_cyc) < tlat_min) tlat_min <= cyc_cnt - t0_cyc;
                if ((cyc_cnt - t0_cyc) > tlat_max) tlat_max <= cyc_cnt - t0_cyc;
            end
        end
        upd_pending_reg <= 1'b0;

        if (upd_pending_reg) begin
            if (!emit_active_reg) begin
                emit_active_reg <= 1'b1;
                beat_idx_reg    <= 2'd0;
                seq_snap_reg    <= seq_reg;
                seq_reg         <= seq_reg + 1;
                snap_ts_reg     <= ts_reg;
                snap_sym_reg    <= upd_sym_reg;
                snap_flags_reg  <= {5'd0, 1'b1, tsym_ask_q == 0, tsym_bid_q == 0};
                snap_bidpx_reg  <= tsym_bid_px;
                snap_bidq_reg   <= tsym_bid_q;
                snap_askpx_reg  <= tsym_ask_px;
                snap_askq_reg   <= tsym_ask_q;
            end else begin
                delta_ovf_reg <= 1'b1;
                delta_ovf_cnt <= delta_ovf_cnt + 1;
                seq_reg       <= seq_reg + 1;
            end
        end

        if (emit_active_reg && m_axis_delta.tready) begin
            if (beat_idx_reg == 2'd3)
                emit_active_reg <= 1'b0;
            else
                beat_idx_reg <= beat_idx_reg + 1;
        end

        if (beat)
            for (int l = 0; l < LANES; l = l + 1)
                if (msg_buf_wr[l])
                    msg_buf[msg_buf_widx[l]] <= msg_buf_wb[l];

        if (beat && state_reg == STATE_IDLE)
            t0_cyc <= cyc_cnt;

        case (state_reg)

        STATE_DECODE: begin
            d_type        <= w_type;
            d_ref         <= w_ref;
            d_ref_h       <= ref_h;
            d_new_ref     <= w_new_ref;
            d_new_ref_h   <= new_ref_h;
            d_hit         <= l_hit;
            d_l_qty       <= l_qty;
            d_take        <= l_take;
            d_sym_tracked <= w_sym_tracked;

            srch_i    <= '0;
            slot_a    <= (LVL_AW+1)'(LEVELS);
            slot_b    <= (LVL_AW+1)'(LEVELS);
            slot_free <= (LVL_AW+1)'(LEVELS);
            sr_vld    <= 1'b0;
            slot_a_q  <= '0;
            slot_b_q  <= '0;

            case (w_type)
                T_ADD, T_ADD_MPID: begin
                    d_sym    <= w_sym;
                    d_side   <= w_side_bid;
                    d_px_a   <= w_price_add;
                    d_px_b   <= w_price_add;
                    d_shares <= w_shares_add;
                    d_base   <= 32'((int'(w_sym)*2 + (w_side_bid ? 0 : 1)) * LEVELS);
                end
                T_REPLACE: begin
                    d_sym    <= l_sym;
                    d_side   <= l_side;
                    d_px_a   <= l_px;
                    d_px_b   <= w_price_repl;
                    d_shares <= w_shares_repl;
                    d_base   <= 32'((int'(l_sym)*2 + (l_side ? 0 : 1)) * LEVELS);
                end
                default: begin
                    d_sym    <= l_sym;
                    d_side   <= l_side;
                    d_px_a   <= l_px;
                    d_px_b   <= l_px;
                    d_shares <= '0;
                    d_base   <= 32'((int'(l_sym)*2 + (l_side ? 0 : 1)) * LEVELS);
                end
            endcase
        end

        STATE_SEARCH: begin
            srch_i <= srch_i + 1;
            sr_vld <= (srch_i < (LVL_AW+1)'(LEVELS));
            sr_i   <= srch_i;
            sr_v   <= lad_v [d_base + 32'(srch_i)];
            sr_px  <= lad_px[d_base + 32'(srch_i)];
            sr_q   <= lad_q [d_base + 32'(srch_i)];
            if (sr_vld) begin
                if (sr_v) begin
                    if (sr_px == d_px_a) begin
                        slot_a   <= sr_i;
                        slot_a_q <= sr_q;
                    end
                    if (sr_px == d_px_b) begin
                        slot_b   <= sr_i;
                        slot_b_q <= sr_q;
                    end
                end else if (slot_free == (LVL_AW+1)'(LEVELS)) begin
                    slot_free <= sr_i;
                end
            end
        end

        STATE_APPLY: begin
            logic ofree;
            upd_sym_reg   <= d_sym;
            upd_valid_reg <= 1'b0;
            scan_i   <= '0;
            scan_bpx <= '0; scan_bq <= '0;
            scan_apx <= '0; scan_aq <= '0;
            rd_vld   <= 1'b0;

            wrA_v_en <= 1'b0; wrA_px_en <= 1'b0; wrA_q_en <= 1'b0;
            wrB_v_en <= 1'b0; wrB_px_en <= 1'b0; wrB_q_en <= 1'b0;
            wrA_idx  <= d_base + 32'(slot_a);
            wrB_idx  <= d_base + 32'(slot_b);

            inc_ok   <= 1'b0;
            inc_side <= d_side ? 1'b0 : 1'b1;
            inc_px   <= d_px_a;

            case (d_type)
                T_ADD, T_ADD_MPID: begin
                    if (d_sym_tracked) begin
                        ord_valid[d_ref_h] <= 1'b1;
                        ord_tag  [d_ref_h] <= d_ref;
                        ord_sym  [d_ref_h] <= d_sym;
                        ord_side [d_ref_h] <= d_side;
                        ord_px   [d_ref_h] <= d_px_a;
                        ord_qty  [d_ref_h] <= d_shares;

                        if (slot_a != (LVL_AW+1)'(LEVELS)) begin
                            wrA_q_en <= 1'b1;
                            wrA_q    <= slot_a_q + d_shares;
                            inc_ok   <= 1'b1;
                            inc_newq <= slot_a_q + d_shares;
                        end else if (slot_free != (LVL_AW+1)'(LEVELS)) begin
                            wrA_idx  <= d_base + 32'(slot_free);
                            wrA_v_en <= 1'b1; wrA_v <= 1'b1;
                            wrA_px_en<= 1'b1; wrA_px <= d_px_a;
                            wrA_q_en <= 1'b1; wrA_q  <= d_shares;
                            inc_ok   <= 1'b1;
                            inc_newq <= d_shares;
                        end else begin
                            overflow_reg <= 1'b1;
                        end
                        upd_valid_reg <= 1'b1;
                    end
                end

                T_EXEC, T_EXEC_PX, T_CANCEL: begin
                    if (d_hit) begin
                        ord_qty[d_ref_h] <= d_l_qty - d_take;
                        if (d_l_qty - d_take == 0)
                            ord_valid[d_ref_h] <= 1'b0;
                        if (slot_a != (LVL_AW+1)'(LEVELS)) begin
                            if (slot_a_q <= d_take) begin
                                wrA_v_en <= 1'b1; wrA_v <= 1'b0;
                                inc_ok   <= 1'b1; inc_newq <= '0;
                            end else begin
                                wrA_q_en <= 1'b1; wrA_q <= slot_a_q - d_take;
                                inc_ok   <= 1'b1; inc_newq <= slot_a_q - d_take;
                            end
                        end
                        upd_valid_reg <= 1'b1;
                    end
                end

                T_DELETE: begin
                    if (d_hit) begin
                        ord_valid[d_ref_h] <= 1'b0;
                        if (slot_a != (LVL_AW+1)'(LEVELS)) begin
                            if (slot_a_q <= d_l_qty) begin
                                wrA_v_en <= 1'b1; wrA_v <= 1'b0;
                                inc_ok   <= 1'b1; inc_newq <= '0;
                            end else begin
                                wrA_q_en <= 1'b1; wrA_q <= slot_a_q - d_l_qty;
                                inc_ok   <= 1'b1; inc_newq <= slot_a_q - d_l_qty;
                            end
                        end
                        upd_valid_reg <= 1'b1;
                    end
                end

                T_REPLACE: begin
                    if (d_hit) begin
                        ord_valid[d_ref_h]     <= 1'b0;
                        ord_valid[d_new_ref_h] <= 1'b1;
                        ord_tag  [d_new_ref_h] <= d_new_ref;
                        ord_sym  [d_new_ref_h] <= d_sym;
                        ord_side [d_new_ref_h] <= d_side;
                        ord_px   [d_new_ref_h] <= d_px_b;
                        ord_qty  [d_new_ref_h] <= d_shares;

                        if (d_px_a == d_px_b) begin
                            if (slot_a != (LVL_AW+1)'(LEVELS)) begin
                                rpl_q = slot_a_q - d_l_qty + d_shares;
                                if (rpl_q == 0) begin
                                    wrA_v_en <= 1'b1; wrA_v <= 1'b0;
                                    inc_ok   <= 1'b1; inc_newq <= '0;
                                end else begin
                                    wrA_q_en <= 1'b1; wrA_q <= rpl_q;
                                    inc_ok   <= 1'b1; inc_newq <= rpl_q;
                                end
                            end
                        end else begin
                            ofree = 1'b0;
                            if (slot_a != (LVL_AW+1)'(LEVELS)) begin
                                if (slot_a_q <= d_l_qty) begin
                                    wrA_v_en <= 1'b1; wrA_v <= 1'b0;
                                    ofree = 1'b1;
                                end else begin
                                    wrA_q_en <= 1'b1; wrA_q <= slot_a_q - d_l_qty;
                                end
                            end

                            if (slot_b != (LVL_AW+1)'(LEVELS)) begin
                                wrB_q_en <= 1'b1; wrB_q <= slot_b_q + d_shares;
                            end else if (ofree) begin
                                wrA_v_en <= 1'b1; wrA_v <= 1'b1;
                                wrA_px_en<= 1'b1; wrA_px <= d_px_b;
                                wrA_q_en <= 1'b1; wrA_q  <= d_shares;
                            end else if (slot_free != (LVL_AW+1)'(LEVELS)) begin
                                wrB_idx  <= d_base + 32'(slot_free);
                                wrB_v_en <= 1'b1; wrB_v <= 1'b1;
                                wrB_px_en<= 1'b1; wrB_px <= d_px_b;
                                wrB_q_en <= 1'b1; wrB_q  <= d_shares;
                            end else begin
                                overflow_reg <= 1'b1;
                            end
                        end
                        upd_valid_reg <= 1'b1;
                    end
                end
                default: ;
            endcase
        end

        STATE_WRITE: begin
            if (wrA_v_en)  lad_v [wrA_idx] <= wrA_v;
            if (wrA_px_en) lad_px[wrA_idx] <= wrA_px;
            if (wrA_q_en)  lad_q [wrA_idx] <= wrA_q;
            if (wrB_v_en)  lad_v [wrB_idx] <= wrB_v;
            if (wrB_px_en) lad_px[wrB_idx] <= wrB_px;
            if (wrB_q_en)  lad_q [wrB_idx] <= wrB_q;

            if (!need_rescan) begin
                scan_bpx <= tsym_bid_px; scan_bq <= tsym_bid_q;
                scan_apx <= tsym_ask_px; scan_aq <= tsym_ask_q;
                if (inc_ok && inc_newq != 0) begin
                    if (!inc_side) begin
                        if (tsym_bid_q == 0 || inc_px > tsym_bid_px
                                || inc_px == tsym_bid_px) begin
                            scan_bpx <= inc_px; scan_bq <= inc_newq;
                        end
                    end else begin
                        if (tsym_ask_q == 0 || inc_px < tsym_ask_px
                                || inc_px == tsym_ask_px) begin
                            scan_apx <= inc_px; scan_aq <= inc_newq;
                        end
                    end
                end
            end
        end

        STATE_SCAN: begin
            int bb, ab;
            bb = (int'(upd_sym_reg)*2 + 0) * LEVELS;
            ab = (int'(upd_sym_reg)*2 + 1) * LEVELS;

            scan_i <= scan_i + 1;

            rd_vld <= (scan_i < (LVL_AW+1)'(LEVELS));
            if (scan_i < (LVL_AW+1)'(LEVELS)) begin
                rd_vb  <= lad_v [bb + 32'(scan_i)];
                rd_pxb <= lad_px[bb + 32'(scan_i)];
                rd_qb  <= lad_q [bb + 32'(scan_i)];
                rd_va  <= lad_v [ab + 32'(scan_i)];
                rd_pxa <= lad_px[ab + 32'(scan_i)];
                rd_qa  <= lad_q [ab + 32'(scan_i)];
            end

            if (rd_vld) begin
                if (rd_vb && (scan_bq == 0 || rd_pxb > scan_bpx)) begin
                    scan_bpx <= rd_pxb;
                    scan_bq  <= rd_qb;
                end
                if (rd_va && (scan_aq == 0 || rd_pxa < scan_apx)) begin
                    scan_apx <= rd_pxa;
                    scan_aq  <= rd_qa;
                end
            end
        end

        STATE_PUB: begin
            tob_bid_px[upd_sym_reg] <= scan_bpx;
            tob_bid_q [upd_sym_reg] <= scan_bq;
            tob_ask_px[upd_sym_reg] <= scan_apx;
            tob_ask_q [upd_sym_reg] <= scan_aq;
            upd_pending_reg <= upd_valid_reg;
            rd_vld <= 1'b0;
            lat_last <= cyc_cnt - t0_cyc;
            if ((cyc_cnt - t0_cyc) < lat_min) lat_min <= cyc_cnt - t0_cyc;
            if ((cyc_cnt - t0_cyc) > lat_max) lat_max <= cyc_cnt - t0_cyc;
        end

        default: ;
        endcase

        if (rst) begin
            state_reg      <= STATE_IDLE;
            skip_reg       <= '0;
            lencnt_reg     <= 2'd2;
            msg_rem_reg    <= '0;
            bidx_reg       <= '0;
            frame_done_reg <= 1'b0;
            trig_valid_reg  <= 1'b0;
            upd_pending_reg <= 1'b0;
            upd_valid_reg   <= 1'b0;
            srch_i          <= '0;
            scan_i          <= '0;
            emit_active_reg <= 1'b0;
            beat_idx_reg    <= 2'd0;
            cyc_cnt  <= '0;
            t0_cyc   <= '0;
            lat_last <= '0;
            lat_min  <= 16'hffff;
            lat_max  <= '0;
            tlat_last <= '0;
            tlat_min  <= 16'hffff;
            tlat_max  <= '0;
            seq_reg         <= '0;
            delta_ovf_reg   <= 1'b0;
            delta_ovf_cnt   <= '0;
            overflow_reg    <= 1'b0;
            for (int i = 0; i < LAD_N; i++)
                lad_v[i] <= 1'b0;
            for (int o = 0; o < ORDER_COUNT; o++)
                ord_valid[o] <= 1'b0;
            for (int t = 0; t < SYM_COUNT; t++) begin
                tob_bid_px[t] <= '0; tob_bid_q[t] <= '0;
                tob_ask_px[t] <= '0; tob_ask_q[t] <= '0;
            end
        end
    end

endmodule

`resetall
