`timescale 1ns/1ps
// Clinic (consulting room) HDMI screen, 640x480, video_clk domain.
//
// A pure display layer: it draws the hall board's decoded status. No business state lives
// here; the hall board stays the only place where numbers, queues and help state are decided.
//
// 10/25 ENT department, multi-room (UI v3 style: warm white, anti-aliased text):
//   header y 0..45: title, queue summary (waiting / checked in), link state
//   two columns (x 0..319 = room A, 320..639 = room B, divider x 320):
//     room name, current patient number (amber), its check-in registration (communication needs
//     in red, packed in bit order into four places, main symptom, how unwell 0..10, red from 7), the result of the doctor's latest
//     button, the help alert (blinking red bar) / "X 诊室已确认求助" for 5 s, the key legend.
//   dual = 0 (single-room board): column B shows the queue instead (next number, waiting,
//   checked in).
// While clinic_card_view zooms a card (zoom_active) the column texts that share lines with the
// zoom box / its title are blanked; the title strip below the box (y 384..413) names the room
// and patient (zoom_room / zoom_number) or says the hall patient asked for help (zoom_help); a
// card without a picture shows its words in the white centre box (zoom_panel). 10/30: the title
// ends with "需求 i/n" (need card i of the patient's n, from clinic_need_trigger).
// Text comes from ui_text_engine (ROMs from verification/ui3/ui3_assets.py); every value is
// latched at the frame start, so a frame never mixes old and new status.
module clinic_screen #(
    parameter integer H_BLANK = 160, TAKEN_FRAMES = 300
)(
    input wire clk, rst, frame_start,
    input wire in_de,
    input wire [23:0] in_rgb,
    input wire [11:0] video_x,      // raw horizontal counter, active x = video_x - H_BLANK
    input wire [11:0] pixel_y,      // active y
    input wire dual,
    input wire [4:0] call_number, issued_number, waiting_count,
    input wire [1:0] help_state, help_room,
    input wire link_up,
    input wire alarm_on,
    input wire [1:0] a_room, b_room,
    input wire [4:0] a_number, b_number,
    input wire [11:0] a_record, b_record,           // {needs[3:0], symptom[3:0], level[3:0]}
    input wire a_record_ok, b_record_ok,
    input wire [1:0] a_op, b_op,                    // 0 none, 1 call, 2 replay, 3 confirm help
    input wire [2:0] a_ops, b_ops,                  // 1 sending .. 5 not delivered
    input wire zoom_active, zoom_panel,
    input wire [2:0] zoom_card,
    input wire zoom_help,
    input wire [1:0] zoom_room,
    input wire [4:0] zoom_number,
    input wire [2:0] zoom_idx, zoom_total,           // 10/30: "需求 idx/total" in the zoom title
    output wire out_de,
    output reg [23:0] out_rgb
);
`include "clinic_ui.vh"
    localparam integer ZOOM_X0 = 140, ZOOM_Y0 = 105;

    // ---------------- frame-latched state ----------------
    reg dual_q, link_q, alarm_q, zact_q, zhelp_q;
    reg [4:0] call_q, issued_q, wait_q, an_q, bn_q, zn_q;
    reg [1:0] help_q, hroom_q, ar_q, br_q, zr_q, aop_q, bop_q;
    reg [2:0] aops_q, bops_q, zi_q, zt_q;
    reg [11:0] arec_q, brec_q;
    reg arok_q, brok_q;
    reg [8:0] taken_timer;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            dual_q <= 0; link_q <= 0; alarm_q <= 0; zact_q <= 0; zhelp_q <= 0;
            call_q <= 0; issued_q <= 0; wait_q <= 0; an_q <= 0; bn_q <= 0; zn_q <= 0;
            help_q <= 0; hroom_q <= 0; ar_q <= 0; br_q <= 0; zr_q <= 0; aop_q <= 0; bop_q <= 0;
            aops_q <= 0; bops_q <= 0; zi_q <= 0; zt_q <= 0; arec_q <= 12'h0FF; brec_q <= 12'h0FF; arok_q <= 0; brok_q <= 0;
            taken_timer <= 0;
        end else if (frame_start) begin
            dual_q <= dual; link_q <= link_up; alarm_q <= alarm_on; zact_q <= zoom_active; zhelp_q <= zoom_help;
            call_q <= call_number; issued_q <= issued_number; wait_q <= waiting_count;
            an_q <= a_number; bn_q <= b_number; zn_q <= zoom_number; zi_q <= zoom_idx; zt_q <= zoom_total;
            help_q <= help_state; hroom_q <= help_room; ar_q <= a_room; br_q <= b_room; zr_q <= zoom_room;
            aop_q <= a_op; bop_q <= b_op; aops_q <= a_ops; bops_q <= b_ops;
            arec_q <= a_record; brec_q <= b_record; arok_q <= a_record_ok; brok_q <= b_record_ok;
            // "X 诊室已确认求助" for TAKEN_FRAMES after the help request was confirmed
            if (help_q == 2'd1 && help_state == 2'd2) taken_timer <= TAKEN_FRAMES;
            else if (taken_timer != 0) taken_timer <= taken_timer - 1'b1;
        end
    end
    // zoom_panel / zoom_card already change only at frame_start (clinic_card_view registers)
    wire panel_q = zoom_panel;
    wire [2:0] zcard_q = zoom_card;

    // ---------------- digit fields ----------------
    function [3:0] tens; input [4:0] v; begin tens = v >= 20 ? 4'd2 : v >= 10 ? 4'd1 : 4'd0; end endfunction
    function [3:0] ones; input [4:0] v; begin ones = v >= 20 ? v - 5'd20 : v >= 10 ? v - 5'd10 : v[3:0]; end endfunction
    wire [4:0] next_n = call_q + 1'b1;
    wire [4:0] b_big = dual_q ? bn_q : next_n;      // column B: room B's patient / the next number
    wire [7:0] f_no;
    reg [3:0] f_val;
    always @* begin
        case (f_no)
            0: f_val = 0; 1: f_val = tens(an_q); 2: f_val = ones(an_q);
            3: f_val = 0; 4: f_val = tens(b_big); 5: f_val = ones(b_big);
            6: f_val = arec_q[3:0] >= 10 ? 4'd1 : 4'd10; 7: f_val = arec_q[3:0] >= 10 ? 4'd0 : arec_q[3:0];
            8: f_val = brec_q[3:0] >= 10 ? 4'd1 : 4'd10; 9: f_val = brec_q[3:0] >= 10 ? 4'd0 : brec_q[3:0];
            10: f_val = wait_q >= 10 ? tens(wait_q) : 4'd10; 11: f_val = ones(wait_q);
            12: f_val = 0; 13: f_val = tens(issued_q); 14: f_val = ones(issued_q);
            18: f_val = {2'b00, hroom_q} + 4'd1;
            19: f_val = {2'b00, ar_q} + 4'd1;
            20: f_val = {2'b00, br_q} + 4'd1;
            21: f_val = {2'b00, zr_q} + 4'd1;
            22: f_val = 0; 23: f_val = tens(zn_q); 24: f_val = ones(zn_q);
            25: f_val = {1'b0, zi_q}; 26: f_val = {1'b0, zt_q};
            default: f_val = 10;
        endcase
    end

    // ---------------- slot -> string / colour ----------------
    localparam [2:0] C_INK = 0, C_LABEL = 1, C_TEAL = 2, C_AMBER = 3, C_GREEN = 4, C_RED = 5;
    wire [5:0] slot;
    reg [11:0] s_sel;
    reg [2:0] c_sel;
    reg slot_xov;
    reg [9:0] slot_x;
    function [11:0] sym_str; input [3:0] s;
        begin case (s)
            0: sym_str = S_SYM0; 1: sym_str = S_SYM1; 2: sym_str = S_SYM2; 3: sym_str = S_SYM3; 4: sym_str = S_SYM4;
            5: sym_str = S_SYM5; 6: sym_str = S_SYM6; 7: sym_str = S_SYM7; 8: sym_str = S_SYM8; 9: sym_str = S_SYM9;
            default: sym_str = S_SYM_NONE;
        endcase end
    endfunction
    function [11:0] op_str; input [1:0] o; input [2:0] r;
        begin case ({o, r})
            {2'd1, 3'd1}: op_str = S_OP0_0; {2'd1, 3'd2}: op_str = S_OP0_1; {2'd1, 3'd3}: op_str = S_OP0_2;
            {2'd1, 3'd4}: op_str = S_OP0_3; {2'd1, 3'd5}: op_str = S_OP0_4;
            {2'd2, 3'd1}: op_str = S_OP1_0; {2'd2, 3'd2}: op_str = S_OP1_1; {2'd2, 3'd3}: op_str = S_OP1_2;
            {2'd2, 3'd4}: op_str = S_OP1_3; {2'd2, 3'd5}: op_str = S_OP1_4;
            {2'd3, 3'd1}: op_str = S_OP2_0; {2'd3, 3'd2}: op_str = S_OP2_1; {2'd3, 3'd3}: op_str = S_OP2_2;
            {2'd3, 3'd4}: op_str = S_OP2_3; {2'd3, 3'd5}: op_str = S_OP2_4;
            default: op_str = 12'd0;
        endcase end
    endfunction
    function [9:0] zoom_x; input [2:0] c;              // words centred in the 360-pixel box
        begin case (c) 0: zoom_x = 320 - W_ZOOM0 / 2; 1: zoom_x = 320 - W_ZOOM1 / 2; 2: zoom_x = 320 - W_ZOOM2 / 2;
            3: zoom_x = 320 - W_ZOOM3 / 2; default: zoom_x = 320 - W_ZOOM4 / 2; endcase end
    endfunction
    function [11:0] zoom_str; input [2:0] c;
        begin case (c) 0: zoom_str = S_ZOOM0; 1: zoom_str = S_ZOOM1; 2: zoom_str = S_ZOOM2; 3: zoom_str = S_ZOOM3;
            default: zoom_str = S_ZOOM4; endcase end
    endfunction
    // the k-th registered need (needs are packed in bit order into the slots NEED0..3); 4 = none
    function [2:0] nth_need; input [3:0] m; input [1:0] k;
        integer j; reg [2:0] c;
        begin
            nth_need = 3'd4; c = 0;
            for (j = 0; j < 4; j = j + 1)
                if (m[j]) begin if (c == {1'b0, k} && nth_need == 3'd4) nth_need = j; c = c + 1'b1; end
        end
    endfunction
    function [11:0] need_str; input [2:0] i;
        begin case (i) 0: need_str = S_NEED0; 1: need_str = S_NEED1; 2: need_str = S_NEED2; 3: need_str = S_NEED3;
            default: need_str = 12'd0; endcase end
    endfunction
    // per-column view (the generator numbers the slots A_* 0..15, then B_* 16..31); column B is
    // the queue on a single-room board
    wire col_b = slot >= SL_B_BIG && slot <= SL_B_SYM;
    wire queue_col = col_b && !dual_q;
    wire [4:0] cn = col_b ? bn_q : an_q;
    wire [11:0] crec = col_b ? brec_q : arec_q;
    wire crok = col_b ? brok_q : arok_q;
    wire [1:0] cop = col_b ? bop_q : aop_q;
    wire [2:0] cops = col_b ? bops_q : aops_q;
    wire registered = crec != 12'h0FF;               // something was entered at check-in
    wire show_rec = cn != 0 && crok;
    // the zoom box (y 105..375) and its title strip (y 384..413) share lines with the columns
    wire mid_blank = zact_q;
    always @* begin
        s_sel = 12'd0; c_sel = C_INK; slot_xov = 1'b0; slot_x = 10'd0;
        case (slot)
            SL_TITLE: s_sel = S_TITLE;
            SL_QUEUE: begin s_sel = dual_q ? S_QUEUE : 12'd0; c_sel = C_LABEL; end
            SL_LINK: begin s_sel = link_q ? S_LINK_OK : S_LINK_DOWN; c_sel = link_q ? C_GREEN : C_RED; end
            SL_A_ROOM: begin s_sel = S_A_ROOM; c_sel = C_TEAL; end
            SL_B_ROOM: begin s_sel = dual_q ? S_B_ROOM : S_B_QROOM; c_sel = C_TEAL; end
            SL_A_LCUR, SL_B_LCUR: begin s_sel = mid_blank ? 12'd0 : queue_col ? S_L_NEXTQ : S_L_CUR; c_sel = C_LABEL; end
            SL_A_BIG, SL_B_BIG: begin
                c_sel = C_AMBER;
                if (mid_blank) s_sel = 12'd0;
                else if (queue_col) s_sel = wait_q != 0 ? S_B_BIG : S_BIGNONE;
                else s_sel = cn == 0 ? S_BIGNONE : col_b ? S_B_BIG : S_A_BIG;
            end
            SL_A_LNEED, SL_B_LNEED: begin s_sel = mid_blank ? 12'd0 : queue_col ? S_L_WAITQ : S_L_NEED; c_sel = C_LABEL; end
            SL_A_NEED0, SL_B_NEED0: begin
                c_sel = C_RED;
                if (mid_blank) s_sel = 12'd0;
                else if (queue_col) begin s_sel = S_V_WAITQ; c_sel = C_INK; end
                else if (!show_rec) s_sel = 12'd0;
                else if (!registered) begin s_sel = S_NEED_UNREG; c_sel = C_LABEL; end
                else if (crec[11:8] == 0) begin s_sel = S_NEED_NONE; c_sel = C_LABEL; end
                else s_sel = need_str(nth_need(crec[11:8], 2'd0));
            end
            SL_A_NEED1, SL_B_NEED1: begin s_sel = !mid_blank && !queue_col && show_rec && registered ? need_str(nth_need(crec[11:8], 2'd1)) : 12'd0; c_sel = C_RED; end
            SL_A_NEED2, SL_B_NEED2: begin s_sel = !mid_blank && !queue_col && show_rec && registered ? need_str(nth_need(crec[11:8], 2'd2)) : 12'd0; c_sel = C_RED; end
            SL_A_NEED3, SL_B_NEED3: begin s_sel = !mid_blank && !queue_col && show_rec && registered ? need_str(nth_need(crec[11:8], 2'd3)) : 12'd0; c_sel = C_RED; end
            SL_A_LSYM, SL_B_LSYM: begin s_sel = mid_blank ? 12'd0 : queue_col ? S_L_ISSUEDQ : S_L_SYM; c_sel = C_LABEL; end
            SL_A_LLVL, SL_B_LLVL: begin s_sel = mid_blank || queue_col ? 12'd0 : S_L_LVL; c_sel = C_LABEL; end
            SL_A_SYM, SL_B_SYM: begin
                if (mid_blank) s_sel = 12'd0;
                else if (queue_col) s_sel = S_V_ISSUEDQ;
                else if (!show_rec) s_sel = 12'd0;
                else begin s_sel = sym_str(crec[7:4]); c_sel = crec[7:4] <= 9 ? C_INK : C_LABEL; end
            end
            SL_A_LVL, SL_B_LVL: begin
                if (mid_blank || queue_col || !show_rec) s_sel = 12'd0;
                else if (crec[3:0] > 10) begin s_sel = S_LVL_NONE; c_sel = C_LABEL; end
                else begin s_sel = col_b ? S_B_LVL : S_A_LVL; c_sel = crec[3:0] >= 7 ? C_RED : C_INK; end
            end
            SL_A_OP, SL_B_OP: begin
                s_sel = mid_blank || queue_col || cop == 0 || cops == 0 || cops > 5 ? 12'd0 : op_str(cop, cops);
                c_sel = cops == 1 ? C_LABEL : cops == 2 ? C_GREEN : C_RED;
            end
            SL_A_HELP, SL_B_HELP: begin
                if (mid_blank || queue_col) s_sel = 12'd0;
                else if (link_q && help_q == 1) begin s_sel = S_ALERT; c_sel = C_RED; end
                else if (link_q && taken_timer != 0) begin s_sel = S_HELP_TAKEN; c_sel = C_GREEN; end
            end
            SL_A_KEY0: begin s_sel = S_A_KEY0; c_sel = C_LABEL; end
            SL_A_KEY1: begin s_sel = S_A_KEY1; c_sel = C_LABEL; end
            SL_B_KEY0: begin s_sel = dual_q ? S_B_KEY0 : 12'd0; c_sel = C_LABEL; end
            SL_B_KEY1: begin s_sel = dual_q ? S_B_KEY1 : 12'd0; c_sel = C_LABEL; end
            SL_ZOOM: begin
                s_sel = panel_q ? zoom_str(zcard_q) : 12'd0;
                slot_xov = 1'b1; slot_x = zoom_x(zcard_q);
            end
            SL_ZOOM_TITLE: begin
                s_sel = !zact_q ? 12'd0 : zhelp_q ? S_ZOOM_HELP : S_ZOOM_TITLE;
                c_sel = zhelp_q ? C_RED : C_INK;
                slot_xov = 1'b1; slot_x = zhelp_q ? 320 - W_ZOOM_HELP / 2 : 320 - W_ZOOM_TITLE / 2;
            end
            default: ;
        endcase
    end

    // ---------------- ROMs ----------------
    wire [5:0] it_addr;
    wire [11:0] s_addr;
    wire [9:0] g_addr;
    wire [15:0] p_addr;
    wire [31:0] it_q;
    wire [11:0] s_q;
    wire [24:0] g_q;
    wire [7:0] p_q;
    ui_table_rom #(.WIDTH(32), .WORDS(1 << UI_ITEM_AW), .AW(UI_ITEM_AW), .INIT("clinic_item.mif"), .HEX("clinic_item.hex"))
        u_items(.clk(clk), .addr(it_addr[UI_ITEM_AW-1:0]), .q(it_q));
    ui_table_rom #(.WIDTH(12), .WORDS(1 << UI_STR_AW), .AW(UI_STR_AW), .INIT("clinic_str.mif"), .HEX("clinic_str.hex"))
        u_strings(.clk(clk), .addr(s_addr[UI_STR_AW-1:0]), .q(s_q));
    ui_table_rom #(.WIDTH(25), .WORDS(1 << UI_GTAB_AW), .AW(UI_GTAB_AW), .INIT("clinic_gtab.mif"), .HEX("clinic_gtab.hex"))
        u_gtab(.clk(clk), .addr(g_addr[UI_GTAB_AW-1:0]), .q(g_q));
    ui_glyph_rom #(.WORDS(UI_GLYPH_WORDS), .INIT("clinic_glyph.mif"), .HEX("clinic_glyph.hex"), .BRAM(UI_GLYPH_BRAM)) u_glyphs(
        .clk(clk), .addr(p_addr), .q(p_q));
    wire [2:0] q_font;
    wire [1:0] cov;
    wire [2:0] tcolor;
    ui_text_engine #(.H_BLANK(H_BLANK), .ITEMS(UI_ITEMS), .TICKER_SLOT(63)) u_text(
        .clk(clk), .rst(rst), .video_x(video_x), .pixel_y(pixel_y), .scroll(11'd0),
        .it_addr(it_addr), .it_q(it_q), .q_slot(slot), .slot_saddr(s_sel), .slot_color(c_sel),
        .slot_xov(slot_xov), .slot_x(slot_x),
        .s_addr(s_addr), .s_q(s_q), .q_field(f_no), .field_val(f_val), .q_font(q_font),
        .digit_base(font_digit_base(q_font)),
        .g_addr(g_addr), .g_q(g_q), .p_addr(p_addr), .p_q(p_q), .cov(cov), .color(tcolor));

    // ---------------- page ----------------
    localparam [23:0] PAGE = 24'hfafaf9, RULE = 24'he2e5e9, WHITE = 24'hffffff, TEAL = 24'h0e6e6e, RED = 24'hd64545;
    wire [11:0] ax = video_x - H_BLANK;
    wire [11:0] y = pixel_y;
    wire [11:0] cx = ax >= 320 ? ax - 12'd320 : ax;        // x inside the column
    wire in_panel = panel_q && ax >= ZOOM_X0 && ax < ZOOM_X0 + 360 && y >= ZOOM_Y0 && y < ZOOM_Y0 + 270;
    wire alert_bar = link_q && help_q == 1 && alarm_q && !zact_q && (dual_q || ax < 320) &&
                     cx >= 8 && cx < 11 && y >= 372 && y < 398;
    reg [23:0] base;
    always @* begin
        base = PAGE;
        if (y == 45 && ax >= 18 && ax < 622) base = RULE;
        if (ax >= 18 && ax < 46 && y >= 41 && y < 44) base = TEAL;
        if (ax == 320 && y >= 56 && y < 464) base = RULE;
        if ((y == 188 || y == 334 || y == 406) && cx >= 18 && cx < 302) base = RULE;
        if (alert_bar) base = RED;
        if (in_panel) base = WHITE;
    end
    reg [23:0] fg;
    always @* begin
        case (tcolor)
            C_INK: fg = 24'h1f2933; C_LABEL: fg = 24'h6b7280; C_TEAL: fg = 24'h0e6e6e;
            C_AMBER: fg = 24'hf08c00; C_GREEN: fg = 24'h2e9e5b; C_RED: fg = 24'hd64545; default: fg = 24'h1f2933;
        endcase
    end
    wire [1:0] a = cov;
    wire [8:0] alpha = a == 2'd1 ? 9'd85 : 9'd171;
    function [7:0] mix; input [7:0] b, f; input [1:0] a; input [8:0] k;
        reg signed [9:0] d; reg signed [18:0] m;
        begin
            d = $signed({2'b00, f}) - $signed({2'b00, b});
            m = d * $signed({1'b0, k});
            mix = a == 2'd3 ? f : a == 2'd0 ? b : b + m[15:8];
        end
    endfunction
    assign out_de = in_de;
    always @* begin
        out_rgb = in_rgb;
        if (in_de && ax < 640 && y < 480)
            out_rgb = {mix(base[23:16], fg[23:16], a, alpha), mix(base[15:8], fg[15:8], a, alpha),
                       mix(base[7:0], fg[7:0], a, alpha)};
    end
endmodule
