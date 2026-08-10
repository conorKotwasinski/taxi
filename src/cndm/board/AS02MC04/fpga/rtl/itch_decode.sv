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

    input  wire logic [$clog2(SYM_COUNT)-1:0]  dbg_sym,
    output wire logic [PRICE_W-1:0]            dbg_bid_px,
    output wire logic [QTY_W-1:0]              dbg_bid_qty,
    output wire logic [PRICE_W-1:0]            dbg_ask_px,
    output wire logic [QTY_W-1:0]              dbg_ask_qty
);

    localparam DATA_W   = s_axis_rx.DATA_W;
    localparam SYM_AW   = $clog2(SYM_COUNT);
    localparam ORDER_AW = $clog2(ORDER_COUNT);
    localparam LVL_AW   = $clog2(LEVELS);

    if (DATA_W != 8)
        $fatal(0, "itch_decode: decode bus is 8-bit (instance %m)");

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

    typedef enum logic [2:0] {
        STATE_IDLE,
        STATE_SKIP_HDR,
        STATE_MSG_LEN,
        STATE_MSG_BODY,
        STATE_DECODE,
        STATE_DRAIN
    } state_t;

    state_t state_reg = STATE_IDLE, state_next;

    logic [TS_W-1:0]   ts_reg,       ts_next;
    logic              bad_reg,      bad_next;
    logic [15:0]       skip_reg,     skip_next;
    logic [1:0]        lencnt_reg,   lencnt_next;
    logic [15:0]       msg_len_reg,  msg_len_next;
    logic [15:0]       msg_rem_reg,  msg_rem_next;
    logic [BIDX_W-1:0] bidx_reg,     bidx_next;
    logic              frame_done_reg, frame_done_next;

    logic [7:0] msg_buf [0:MSG_BUF_N-1];

    wire [7:0] rx_b = s_axis_rx.tdata[7:0];
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

    logic [PRICE_W-1:0] scan_bid_px, scan_ask_px;
    logic [QTY_W-1:0]   scan_bid_q,  scan_ask_q;
    always_comb begin
        int bb, ab; int i;
        bb = (int'(dbg_sym) * 2 + 0) * LEVELS;
        ab = (int'(dbg_sym) * 2 + 1) * LEVELS;
        scan_bid_px = '0; scan_bid_q = '0;
        scan_ask_px = '0; scan_ask_q = '0;
        for (i = 0; i < LEVELS; i++) begin
            if (lad_v[bb + i]) begin
                if (scan_bid_q == 0 || lad_px[bb + i] > scan_bid_px) begin
                    scan_bid_px = lad_px[bb + i];
                    scan_bid_q  = lad_q [bb + i];
                end
            end
            if (lad_v[ab + i]) begin
                if (scan_ask_q == 0 || lad_px[ab + i] < scan_ask_px) begin
                    scan_ask_px = lad_px[ab + i];
                    scan_ask_q  = lad_q [ab + i];
                end
            end
        end
    end

    assign s_axis_rx.tready = (state_reg != STATE_DECODE);

    logic              emit_active_reg;
    logic [1:0]        beat_idx_reg;
    logic [31:0]       seq_reg;
    logic [31:0]       seq_snap_reg;
    logic              delta_ovf_reg;

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

    logic [QTY_W-1:0]   tsym_bid_q, tsym_ask_q;
    logic [PRICE_W-1:0] tsym_bid_px, tsym_ask_px;
    always_comb begin
        int tb, ta; int i;
        tb = (int'(upd_sym_reg) * 2 + 0) * LEVELS;
        ta = (int'(upd_sym_reg) * 2 + 1) * LEVELS;
        tsym_bid_q = '0; tsym_bid_px = '0;
        tsym_ask_q = '0; tsym_ask_px = '0;
        for (i = 0; i < LEVELS; i++) begin
            if (lad_v[tb + i] && (tsym_bid_q == 0 || lad_px[tb + i] > tsym_bid_px)) begin
                tsym_bid_px = lad_px[tb + i];
                tsym_bid_q  = lad_q [tb + i];
            end
            if (lad_v[ta + i] && (tsym_ask_q == 0 || lad_px[ta + i] < tsym_ask_px)) begin
                tsym_ask_px = lad_px[ta + i];
                tsym_ask_q  = lad_q [ta + i];
            end
        end
    end

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

        if (state_reg == STATE_DECODE) begin
            if (frame_done_reg)
                state_next = STATE_IDLE;
            else begin
                state_next  = STATE_MSG_LEN;
                lencnt_next = 2'd2;
            end
        end

        if (beat) begin
            case (state_reg)
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
                    if (skip_reg <= 1) begin
                        state_next  = STATE_MSG_LEN;
                        lencnt_next = 2'd2;
                    end else begin
                        skip_next = skip_reg - 1;
                    end
                end
                STATE_MSG_LEN: begin
                    msg_len_next = {msg_len_reg[7:0], rx_b};
                    if (lencnt_reg == 2'd1) begin
                        msg_rem_next = {msg_len_reg[7:0], rx_b};
                        bidx_next    = '0;
                        state_next   = STATE_MSG_BODY;
                    end else begin
                        lencnt_next = lencnt_reg - 1;
                    end
                end
                STATE_MSG_BODY: begin
                    bidx_next = bidx_reg + 1;
                    if (msg_rem_reg == 16'd1)
                        state_next = STATE_DECODE;
                    else
                        msg_rem_next = msg_rem_reg - 1;
                end
                default: state_next = STATE_IDLE;
            endcase

            if (s_axis_rx.tlast)
                frame_done_next = 1'b1;
        end

        if (state_next == STATE_IDLE)
            frame_done_next = 1'b0;
    end

    function automatic int lad_find(input int base, input [PRICE_W-1:0] price);
        int i; lad_find = LEVELS;
        for (i = 0; i < LEVELS; i++)
            if (lad_v[base + i] && lad_px[base + i] == price) lad_find = i;
    endfunction

    function automatic int lad_free(input int base);
        int i; lad_free = LEVELS;
        for (i = LEVELS - 1; i >= 0; i--)
            if (!lad_v[base + i]) lad_free = i;
    endfunction

    int dec_base;
    int dec_slot;
    int rpl_oslot;
    int rpl_nslot;
    logic rpl_ofree;
    logic [QTY_W-1:0] rpl_q;

    always_ff @(posedge clk) begin
        state_reg      <= state_next;
        ts_reg         <= ts_next;
        bad_reg        <= bad_next;
        skip_reg       <= skip_next;
        lencnt_reg     <= lencnt_next;
        msg_len_reg    <= msg_len_next;
        msg_rem_reg    <= msg_rem_next;
        bidx_reg       <= bidx_next;
        frame_done_reg <= frame_done_next;

        overflow_reg <= 1'b0;

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
                snap_flags_reg  <= {6'd0, tsym_ask_q == 0, tsym_bid_q == 0};
                snap_bidpx_reg  <= tsym_bid_px;
                snap_bidq_reg   <= tsym_bid_q;
                snap_askpx_reg  <= tsym_ask_px;
                snap_askq_reg   <= tsym_ask_q;
            end else begin
                delta_ovf_reg <= 1'b1;
            end
        end

        if (emit_active_reg && m_axis_delta.tready) begin
            if (beat_idx_reg == 2'd3)
                emit_active_reg <= 1'b0;
            else
                beat_idx_reg <= beat_idx_reg + 1;
        end

        if (beat && state_reg == STATE_MSG_BODY)
            msg_buf[bidx_reg] <= rx_b;

        if (state_reg == STATE_DECODE) begin

            case (w_type)
                T_ADD, T_ADD_MPID: begin
                    if (w_sym_tracked) begin upd_sym_reg <= w_sym; upd_pending_reg <= 1'b1; end
                end
                T_EXEC, T_EXEC_PX, T_CANCEL, T_DELETE, T_REPLACE: begin
                    if (l_hit) begin upd_sym_reg <= l_sym; upd_pending_reg <= 1'b1; end
                end
                default: ;
            endcase

            case (w_type)
                T_ADD, T_ADD_MPID: begin
                    if (w_sym_tracked) begin
                        ord_valid[ref_h] <= 1'b1;
                        ord_tag  [ref_h] <= w_ref;
                        ord_sym  [ref_h] <= w_sym;
                        ord_side [ref_h] <= w_side_bid;
                        ord_px   [ref_h] <= w_price_add;
                        ord_qty  [ref_h] <= w_shares_add;

                        dec_base = (int'(w_sym) * 2 + (w_side_bid ? 0 : 1)) * LEVELS;
                        dec_slot = lad_find(dec_base, w_price_add);
                        if (dec_slot != LEVELS) begin
                            lad_q[dec_base + dec_slot] <= lad_q[dec_base + dec_slot] + w_shares_add;
                        end else begin
                            dec_slot = lad_free(dec_base);
                            if (dec_slot != LEVELS) begin
                                lad_v [dec_base + dec_slot] <= 1'b1;
                                lad_px[dec_base + dec_slot] <= w_price_add;
                                lad_q [dec_base + dec_slot] <= w_shares_add;
                            end else begin
                                overflow_reg <= 1'b1;
                            end
                        end
                    end
                end

                T_EXEC, T_EXEC_PX, T_CANCEL: begin
                    if (l_hit) begin
                        ord_qty[ref_h] <= l_qty - l_take;
                        if (l_qty - l_take == 0)
                            ord_valid[ref_h] <= 1'b0;

                        dec_base = (int'(l_sym) * 2 + (l_side ? 0 : 1)) * LEVELS;
                        dec_slot = lad_find(dec_base, l_px);
                        if (dec_slot != LEVELS) begin
                            if (lad_q[dec_base + dec_slot] <= l_take)
                                lad_v[dec_base + dec_slot] <= 1'b0;
                            else
                                lad_q[dec_base + dec_slot] <= lad_q[dec_base + dec_slot] - l_take;
                        end
                    end
                end

                T_DELETE: begin
                    if (l_hit) begin
                        ord_valid[ref_h] <= 1'b0;
                        dec_base = (int'(l_sym) * 2 + (l_side ? 0 : 1)) * LEVELS;
                        dec_slot = lad_find(dec_base, l_px);
                        if (dec_slot != LEVELS) begin
                            if (lad_q[dec_base + dec_slot] <= l_qty)
                                lad_v[dec_base + dec_slot] <= 1'b0;
                            else
                                lad_q[dec_base + dec_slot] <= lad_q[dec_base + dec_slot] - l_qty;
                        end
                    end
                end

                T_REPLACE: begin
                    if (l_hit) begin

                        ord_valid[ref_h]     <= 1'b0;
                        ord_valid[new_ref_h] <= 1'b1;
                        ord_tag  [new_ref_h] <= w_new_ref;
                        ord_sym  [new_ref_h] <= l_sym;
                        ord_side [new_ref_h] <= l_side;
                        ord_px   [new_ref_h] <= w_price_repl;
                        ord_qty  [new_ref_h] <= w_shares_repl;

                        dec_base  = (int'(l_sym) * 2 + (l_side ? 0 : 1)) * LEVELS;
                        rpl_oslot = lad_find(dec_base, l_px);
                        rpl_nslot = lad_find(dec_base, w_price_repl);

                        if (l_px == w_price_repl) begin

                            if (rpl_oslot != LEVELS) begin
                                rpl_q = lad_q[dec_base + rpl_oslot] - l_qty + w_shares_repl;
                                if (rpl_q == 0)
                                    lad_v[dec_base + rpl_oslot] <= 1'b0;
                                else
                                    lad_q[dec_base + rpl_oslot] <= rpl_q;
                            end
                        end else begin

                            rpl_ofree = 1'b0;
                            if (rpl_oslot != LEVELS) begin
                                if (lad_q[dec_base + rpl_oslot] <= l_qty) begin
                                    lad_v[dec_base + rpl_oslot] <= 1'b0;
                                    rpl_ofree = 1'b1;
                                end else begin
                                    lad_q[dec_base + rpl_oslot] <= lad_q[dec_base + rpl_oslot] - l_qty;
                                end
                            end

                            if (rpl_nslot != LEVELS) begin
                                lad_q[dec_base + rpl_nslot] <= lad_q[dec_base + rpl_nslot] + w_shares_repl;
                            end else if (rpl_ofree) begin
                                lad_v [dec_base + rpl_oslot] <= 1'b1;
                                lad_px[dec_base + rpl_oslot] <= w_price_repl;
                                lad_q [dec_base + rpl_oslot] <= w_shares_repl;
                            end else begin
                                rpl_nslot = lad_free(dec_base);
                                if (rpl_nslot != LEVELS) begin
                                    lad_v [dec_base + rpl_nslot] <= 1'b1;
                                    lad_px[dec_base + rpl_nslot] <= w_price_repl;
                                    lad_q [dec_base + rpl_nslot] <= w_shares_repl;
                                end else begin
                                    overflow_reg <= 1'b1;
                                end
                            end
                        end
                    end
                end
                default: ;
            endcase
        end

        if (rst) begin
            state_reg      <= STATE_IDLE;
            skip_reg       <= '0;
            lencnt_reg     <= 2'd2;
            msg_rem_reg    <= '0;
            bidx_reg       <= '0;
            frame_done_reg <= 1'b0;
            trig_valid_reg <= 1'b0;
            upd_pending_reg <= 1'b0;
            emit_active_reg <= 1'b0;
            beat_idx_reg    <= 2'd0;
            seq_reg         <= '0;
            delta_ovf_reg   <= 1'b0;
            for (int i = 0; i < LAD_N; i++)
                lad_v[i] <= 1'b0;
            for (int o = 0; o < ORDER_COUNT; o++)
                ord_valid[o] <= 1'b0;
        end
    end

endmodule

`resetall
