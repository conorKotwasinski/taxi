`resetall
`timescale 1ns / 1ps
`default_nettype none

module itch_decode #
(
    parameter SYM_COUNT       = 64,
    parameter LEVELS          = 8,
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
    input  wire logic [QTY_W-1:0]              cfg_imbalance_thresh,

    input  wire logic [$clog2(SYM_COUNT)-1:0]  dbg_sym,
    output wire logic [PRICE_W-1:0]            dbg_bid_px,
    output wire logic [QTY_W-1:0]              dbg_bid_qty,
    output wire logic [PRICE_W-1:0]            dbg_ask_px,
    output wire logic [QTY_W-1:0]              dbg_ask_qty
);

    localparam DATA_W   = s_axis_rx.DATA_W;
    localparam SYM_AW   = $clog2(SYM_COUNT);
    localparam ORDER_AW = $clog2(ORDER_COUNT);

    if (DATA_W != 8)
        $fatal(0, "itch_decode: Phase-1 decode bus is 8-bit (instance %m)");

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

    logic [TS_W-1:0] ts_reg,       ts_next;
    logic            bad_reg,      bad_next;
    logic [15:0]     skip_reg,     skip_next;
    logic [1:0]      lencnt_reg,   lencnt_next;
    logic [15:0]     msg_len_reg,  msg_len_next;
    logic [15:0]     msg_rem_reg,  msg_rem_next;
    logic [BIDX_W-1:0] bidx_reg,   bidx_next;
    logic            frame_done_reg, frame_done_next;

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

    wire       w_side_bid = (msg_buf[19] == "B");
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

    logic [PRICE_W-1:0]      bid_px    [0:SYM_COUNT-1] = '{default: '0};
    logic [QTY_W-1:0]        bid_qty   [0:SYM_COUNT-1] = '{default: '0};
    logic [PRICE_W-1:0]      ask_px    [0:SYM_COUNT-1] = '{default: '0};
    logic [QTY_W-1:0]        ask_qty   [0:SYM_COUNT-1] = '{default: '0};

    wire [ORDER_AW-1:0] ref_h     = w_ref[ORDER_AW-1:0];
    wire [ORDER_AW-1:0] new_ref_h = w_new_ref[ORDER_AW-1:0];

    wire                 l_hit  = ord_valid[ref_h] && (ord_tag[ref_h] == w_ref);
    wire [SYM_AW-1:0]    l_sym  = ord_sym[ref_h];
    wire                 l_side = ord_side[ref_h];
    wire [PRICE_W-1:0]   l_px   = ord_px[ref_h];
    wire [QTY_W-1:0]     l_qty  = ord_qty[ref_h];
    wire [QTY_W-1:0]     l_take = (l_qty < w_shares_exec) ? l_qty : w_shares_exec;

    wire [SYM_AW-1:0]  rpl_sym = l_sym;
    wire               rpl_bid = l_side;
    wire [PRICE_W-1:0] rpl_opx = l_px;
    wire [QTY_W-1:0]   rpl_oqty = l_qty;

    assign s_axis_rx.tready = (state_reg != STATE_DECODE);

    assign m_axis_delta.tdata  = '0;
    assign m_axis_delta.tkeep  = '0;
    assign m_axis_delta.tstrb  = '0;
    assign m_axis_delta.tlast  = 1'b0;
    assign m_axis_delta.tid    = '0;
    assign m_axis_delta.tdest  = '0;
    assign m_axis_delta.tuser  = '0;
    assign m_axis_delta.tvalid = 1'b0;

    assign trig_valid = 1'b0;
    assign trig_sym   = '0;

    assign dbg_bid_px  = bid_px[dbg_sym];
    assign dbg_bid_qty = bid_qty[dbg_sym];
    assign dbg_ask_px  = ask_px[dbg_sym];
    assign dbg_ask_qty = ask_qty[dbg_sym];

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

    logic [PRICE_W-1:0] lvl_px_v;
    logic [QTY_W-1:0]   lvl_qty_v;

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

        if (beat && state_reg == STATE_MSG_BODY)
            msg_buf[bidx_reg] <= rx_b;

        if (state_reg == STATE_DECODE) begin
            case (w_type)
                T_ADD, T_ADD_MPID: begin
                    if (w_sym_tracked) begin

                        ord_valid[ref_h] <= 1'b1;
                        ord_tag  [ref_h] <= w_ref;
                        ord_sym  [ref_h] <= w_sym;
                        ord_side [ref_h] <= w_side_bid;
                        ord_px   [ref_h] <= w_price_add;
                        ord_qty  [ref_h] <= w_shares_add;

                        if (w_side_bid) begin
                            if (bid_qty[w_sym] == 0 || w_price_add > bid_px[w_sym]) begin
                                bid_px [w_sym] <= w_price_add;
                                bid_qty[w_sym] <= w_shares_add;
                            end else if (w_price_add == bid_px[w_sym]) begin
                                bid_qty[w_sym] <= bid_qty[w_sym] + w_shares_add;
                            end
                        end else begin
                            if (ask_qty[w_sym] == 0 || w_price_add < ask_px[w_sym]) begin
                                ask_px [w_sym] <= w_price_add;
                                ask_qty[w_sym] <= w_shares_add;
                            end else if (w_price_add == ask_px[w_sym]) begin
                                ask_qty[w_sym] <= ask_qty[w_sym] + w_shares_add;
                            end
                        end
                    end
                end
                T_EXEC, T_EXEC_PX, T_CANCEL: begin
                    if (l_hit) begin
                        ord_qty[ref_h] <= l_qty - l_take;
                        if (l_qty - l_take == 0)
                            ord_valid[ref_h] <= 1'b0;

                        if (l_side) begin
                            if (l_px == bid_px[l_sym])
                                bid_qty[l_sym] <= bid_qty[l_sym] - l_take;
                        end else begin
                            if (l_px == ask_px[l_sym])
                                ask_qty[l_sym] <= ask_qty[l_sym] - l_take;
                        end
                    end
                end
                T_DELETE: begin
                    if (l_hit) begin
                        ord_valid[ref_h] <= 1'b0;
                        if (l_side) begin
                            if (l_px == bid_px[l_sym])
                                bid_qty[l_sym] <= bid_qty[l_sym] - l_qty;
                        end else begin
                            if (l_px == ask_px[l_sym])
                                ask_qty[l_sym] <= ask_qty[l_sym] - l_qty;
                        end
                    end
                end

                T_REPLACE: begin
                    if (l_hit) begin

                        ord_valid[ref_h]     <= 1'b0;
                        ord_valid[new_ref_h] <= 1'b1;
                        ord_tag  [new_ref_h] <= w_new_ref;
                        ord_sym  [new_ref_h] <= rpl_sym;
                        ord_side [new_ref_h] <= rpl_bid;
                        ord_px   [new_ref_h] <= w_price_repl;
                        ord_qty  [new_ref_h] <= w_shares_repl;

                        if (rpl_bid) begin
                            lvl_px_v  = bid_px[rpl_sym];
                            lvl_qty_v = bid_qty[rpl_sym];
                            if (rpl_opx == lvl_px_v)
                                lvl_qty_v = lvl_qty_v - rpl_oqty;
                            if (lvl_qty_v == 0 || w_price_repl > lvl_px_v) begin
                                lvl_px_v  = w_price_repl;
                                lvl_qty_v = w_shares_repl;
                            end else if (w_price_repl == lvl_px_v) begin
                                lvl_qty_v = lvl_qty_v + w_shares_repl;
                            end
                            bid_px [rpl_sym] <= lvl_px_v;
                            bid_qty[rpl_sym] <= lvl_qty_v;
                        end else begin
                            lvl_px_v  = ask_px[rpl_sym];
                            lvl_qty_v = ask_qty[rpl_sym];
                            if (rpl_opx == lvl_px_v)
                                lvl_qty_v = lvl_qty_v - rpl_oqty;
                            if (lvl_qty_v == 0 || w_price_repl < lvl_px_v) begin
                                lvl_px_v  = w_price_repl;
                                lvl_qty_v = w_shares_repl;
                            end else if (w_price_repl == lvl_px_v) begin
                                lvl_qty_v = lvl_qty_v + w_shares_repl;
                            end
                            ask_px [rpl_sym] <= lvl_px_v;
                            ask_qty[rpl_sym] <= lvl_qty_v;
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
            for (int s = 0; s < SYM_COUNT; s++) begin
                bid_px[s]  <= '0; bid_qty[s] <= '0;
                ask_px[s]  <= '0; ask_qty[s] <= '0;
            end
            for (int o = 0; o < ORDER_COUNT; o++)
                ord_valid[o] <= 1'b0;
        end
    end

endmodule

`resetall
