`timescale 1ns/1ps
// Hall screen (UI v3, 10/24; multi-room ENT department 10/25): full-screen photo, anti-aliased text.
//
//  * The photo is shown unattenuated over the whole 640x480 screen, except two bands
//    (header y 0..45 and the information block y 322..479) where it is lightened to
//    in*5/8 + 96 ("light translucent white"), so the text stands apart from the photo.
//  * All text comes from ui_text_engine (ROMs from verification/ui3/ui3_assets.py) and is
//    blended onto the picture with its 2-bit coverage: out = bg + (fg - bg) * a, a = 0,1/3,2/3,1.
//  * The audio waveform (promax_audio_waveform, first-version colours) is drawn before this
//    layer, directly on the photo.
//  * Bottom line: the ticker (fixed "温馨提示" label + scrolling text). For 3 s after
//    brightness, contrast, volume, rotation or a rejected request it is replaced by the
//    adjust line / the prompt; then the ticker returns.
//  * 10/25 multi-room: the call line names the room of the latest call ("请 006 号到 2 诊室就诊"),
//    the info row lists every present room's current patient (rooms_present), help shows which
//    room confirmed it, voice faults are shown in the header (red, in place of the photo error).
//    When the latest call's patient registered "听力差" (call_needs bit 0), and on every accepted
//    replay (replay_pulse: a room's K2 or the touch screen's replay), an amber pill badge
//    "请留意屏幕" (white text) shows right of the number for FLASH_FRAMES, on/off every 16 frames:
//    x 196.., y 120..149, rounded ends of radius 15 (row inset table pill_inset). Nothing else in
//    the call area changes (10/26: the frosted panel, the amber bar and the old amber box are gone).
//  * 10/28 layout: the call area is two lines, "请 [006] 号" and "到 [02] 诊室就诊" (digits 96 px amber,
//    words 30 px bold ink on the digits' baseline); idle: "等待叫号" on line 1, line 2 empty.
//    The pill sits right of "号" (PILL_X0 / PILL_Y0 from the generator).
//    Bottom line priority: reject prompt (3 s, red) > adjust line > SW4 resolution > ticker. The
//    adjust line shows while SW1 is up (volume_mode, permanent, the selected volume target
//    underlined in amber: target_voice) or for 3 s after a setting changed with SW1 down.
//    The ticker text is orange-red (#C2410C).
//  * 10/26 扩展要求3 (SW4, res_show): the bottom line shows the picture on screen and the resolution
//    the board itself read from its BMP header - "PIC2.BMP  原图 1024×768 → 显示 640×480" - in place
//    of the ticker (an adjust line / prompt still wins for its 3 s). res_pic / res_cells come from
//    bmp_res_info (block RAM read with the frame-latched picture number), so they only change at a
//    frame start; res_cells are ready-made digit cells (10 = blank, 12 = '×'), fields 54..68.
module hospital_screen #(
    parameter integer H_BLANK = 160, ADJUST_FRAMES = 180, PROMPT_FRAMES = 180, FLASH_FRAMES = 300
)(
    input wire clk, rst, frame_start, in_de, input wire [23:0] in_rgb,
    input wire [11:0] video_x, pixel_y,
    input wire [4:0] call_number, issued_number, waiting_count,
    input wire [1:0] help_state, input wire [2:0] voice_status,
    input wire [1:0] brightness_idx, contrast_idx,
    input wire volume_mode, volume_target, input wire [3:0] music_level, voice_level,
    input wire [7:0] reject_invalid, reject_duplicate, reject_full, reject_conflict,
    input wire [4:0] history1, history2, history3,
    input wire [19:0] room_numbers,                 // {room4..room1} current patient
    input wire [1:0] last_room, help_room,
    input wire [3:0] call_needs,                    // registration needs of the latest call
    input wire replay_pulse,                        // a replay was accepted (one clock, any time)
    input wire [3:0] rooms_present,                 // rooms listed in the info row
    input wire phy_connected, clinic_online, media_ready, auto_enabled,
    input wire [3:0] media_error,
    input wire res_show,                            // SW4 (synchronised): show the resolution line
    input wire [1:0] res_pic,                       // picture on screen, 0..3 = PIC1..PIC4
    input wire [59:0] res_cells,                    // its digit cells (bmp_res_info)
    output wire out_de, output reg [23:0] out_rgb
);
`include "hall_ui.vh"
    // ---------------- frame-latched state ----------------
    reg [4:0] number_q, issued_q, waiting_q, h1_q, h2_q, h3_q;
    reg [19:0] rooms_q;
    reg [1:0] lroom_q, hroom_q;
    reg [3:0] present_q;
    reg [2:0] voice_q;
    reg [1:0] help_q, bri_q, con_q;
    reg phy_q, online_q, ready_q, auto_q, volmode_q, res_q, target_q;
    reg [3:0] error_q, music_q, speech_q;
    reg [10:0] scroll;
    reg [7:0] adjust_timer, prompt_timer;
    reg [8:0] flash_timer;
    reg [4:0] blink;
    reg [2:0] prompt_id;
    // what changed -> adjust line (brightness/contrast/volume/rotation) for ADJUST_FRAMES frames
    wire setting_changed = brightness_idx != bri_q || contrast_idx != con_q || music_level != music_q ||
                           voice_level != speech_q || auto_enabled != auto_q || volume_mode != volmode_q;
    wire rejected = |(reject_invalid | reject_duplicate | reject_full | reject_conflict);
    reg [2:0] reason;
    always @* begin
        if (|reject_conflict) reason = 6;
        else if (|reject_full) reason = 5;
        else if (reject_invalid[0]) reason = 0;
        else if (reject_invalid[1] || reject_invalid[6]) reason = 1;
        else if (reject_invalid[2]) reason = 2;
        else if (reject_invalid[7]) reason = 3;
        else if (reject_duplicate[5] && help_state == 1) reason = 7;
        else reason = 4;
    end
    reg rejected_seen, replay_seen;
    reg [1:0] settle;                   // the first frames after reset only latch the settings
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            number_q <= 0; issued_q <= 0; waiting_q <= 0; h1_q <= 0; h2_q <= 0; h3_q <= 0;
            rooms_q <= 0; lroom_q <= 0; hroom_q <= 0; present_q <= 0;
            voice_q <= 7; help_q <= 0; bri_q <= 0; con_q <= 0;
            phy_q <= 0; online_q <= 0; ready_q <= 0; res_q <= 0;
            auto_q <= 0; volmode_q <= 0; target_q <= 0; error_q <= 0; music_q <= 2; speech_q <= 10;
            scroll <= 0; adjust_timer <= 0; prompt_timer <= 0; prompt_id <= 0; rejected_seen <= 0; settle <= 0;
            flash_timer <= 0; blink <= 0; replay_seen <= 0;
        end else begin
            if (rejected) begin rejected_seen <= 1'b1; prompt_id <= reason; end
            if (replay_pulse) replay_seen <= 1'b1;
            if (frame_start) begin
                rejected_seen <= 1'b0; replay_seen <= 1'b0;
                if (settle != 2'd3) settle <= settle + 1'b1;
                if (setting_changed && settle == 2'd3) adjust_timer <= ADJUST_FRAMES;
                else if (adjust_timer != 0) adjust_timer <= adjust_timer - 1'b1;
                if (rejected_seen || rejected) prompt_timer <= PROMPT_FRAMES;
                else if (prompt_timer != 0) prompt_timer <= prompt_timer - 1'b1;
                // a new call of a "听力差" patient, or a replay, starts the badge
                if ((call_number != number_q && call_number != 0 && call_needs[0]) || replay_seen || replay_pulse) begin
                    flash_timer <= FLASH_FRAMES; blink <= 0;
                end else begin
                    if (flash_timer != 0) flash_timer <= flash_timer - 1'b1;
                    blink <= blink + 1'b1;
                end
                number_q <= call_number; issued_q <= issued_number; waiting_q <= waiting_count;
                h1_q <= history1; h2_q <= history2; h3_q <= history3;
                rooms_q <= room_numbers; lroom_q <= last_room; hroom_q <= help_room; present_q <= rooms_present;
                help_q <= help_state; voice_q <= voice_status;
                bri_q <= brightness_idx; con_q <= contrast_idx; music_q <= music_level; speech_q <= voice_level;
                auto_q <= auto_enabled; volmode_q <= volume_mode; target_q <= volume_target;
                phy_q <= phy_connected; online_q <= clinic_online; ready_q <= media_ready; res_q <= res_show;
                error_q <= media_error;
                // 1 pixel per frame; the period is the ticker text width plus its gap
                scroll <= scroll == TICKER_PERIOD - 1 ? 11'd0 : scroll + 1'b1;
            end
        end
    end
    // 10/28 priority: prompt > adjust (SW1 up: always; down: 3 s after a change) > resolution > ticker
    wire show_prompt = prompt_timer != 0;
    wire show_adjust = (volmode_q || adjust_timer != 0) && !show_prompt;
    wire flash_on = flash_timer != 0 && !blink[4];   // badge (pulses)
    wire show_res = res_q && ready_q && !show_adjust && !show_prompt;

    // ---------------- digit fields ----------------
    function [3:0] tens; input [4:0] v; begin tens = v >= 20 ? 4'd2 : v >= 10 ? 4'd1 : 4'd0; end endfunction
    function [3:0] ones; input [4:0] v; begin ones = v >= 20 ? v - 5'd20 : v >= 10 ? v - 5'd10 : v[3:0]; end endfunction
    // percentages as three digits {hundreds, tens, ones}, 10 = blank (no divider):
    // brightness 100/75/50/25 %, contrast 100/125/150/75 %, volume level*10 %
    function [11:0] bri_digits; input [1:0] i;
        begin case (i) 0: bri_digits = {4'd1, 4'd0, 4'd0}; 1: bri_digits = {4'd10, 4'd7, 4'd5};
            2: bri_digits = {4'd10, 4'd5, 4'd0}; default: bri_digits = {4'd10, 4'd2, 4'd5}; endcase end
    endfunction
    function [11:0] con_digits; input [1:0] i;
        begin case (i) 0: con_digits = {4'd1, 4'd0, 4'd0}; 1: con_digits = {4'd1, 4'd2, 4'd5};
            2: con_digits = {4'd1, 4'd5, 4'd0}; default: con_digits = {4'd10, 4'd7, 4'd5}; endcase end
    endfunction
    function [11:0] vol_digits; input [3:0] l;
        begin
            if (l >= 4'd10) vol_digits = {4'd1, l - 4'd10, 4'd0};
            else if (l == 4'd0) vol_digits = {4'd10, 4'd10, 4'd0};
            else vol_digits = {4'd10, l, 4'd0};
        end
    endfunction
    wire [11:0] bri_d = bri_digits(bri_q), con_d = con_digits(con_q);
    wire [11:0] mus_d = vol_digits(music_q), voi_d = vol_digits(speech_q);
    wire [4:0] next_n = number_q + 1'b1;
    wire [7:0] f_no;
    reg [3:0] f_val;
    // fields 41..52: room r's number, digit d at 41 + 3r + d
    wire [5:0] rf = f_no[5:0] - 6'd41;
    wire [1:0] rf_room = rf >= 9 ? 2'd3 : rf >= 6 ? 2'd2 : rf >= 3 ? 2'd1 : 2'd0;
    wire [1:0] rf_digit = rf - {rf_room, 1'b0} - rf_room;
    wire [4:0] rf_n = rooms_q[5 * rf_room +: 5];
    wire [3:0] rc = f_no[3:0] - 4'd6;                // fields 54..68 -> cell 0..14 (54 = 0x36)
    always @* begin
        case (f_no)
            0: f_val = 0; 1: f_val = tens(number_q); 2: f_val = ones(number_q);
            3: f_val = 0; 4: f_val = tens(next_n); 5: f_val = ones(next_n);
            6: f_val = waiting_q >= 10 ? tens(waiting_q) : 4'd10; 7: f_val = ones(waiting_q);
            8: f_val = 0; 9: f_val = tens(issued_q); 10: f_val = ones(issued_q);
            11: f_val = h1_q == 0 ? 4'd11 : 4'd0; 12: f_val = h1_q == 0 ? 4'd11 : tens(h1_q); 13: f_val = h1_q == 0 ? 4'd11 : ones(h1_q);
            14: f_val = h2_q == 0 ? 4'd11 : 4'd0; 15: f_val = h2_q == 0 ? 4'd11 : tens(h2_q); 16: f_val = h2_q == 0 ? 4'd11 : ones(h2_q);
            17: f_val = h3_q == 0 ? 4'd11 : 4'd0; 18: f_val = h3_q == 0 ? 4'd11 : tens(h3_q); 19: f_val = h3_q == 0 ? 4'd11 : ones(h3_q);
            25: f_val = bri_d[11:8]; 26: f_val = bri_d[7:4]; 27: f_val = bri_d[3:0];
            28: f_val = con_d[11:8]; 29: f_val = con_d[7:4]; 30: f_val = con_d[3:0];
            31: f_val = mus_d[11:8]; 32: f_val = mus_d[7:4]; 33: f_val = mus_d[3:0];
            34: f_val = voi_d[11:8]; 35: f_val = voi_d[7:4]; 36: f_val = voi_d[3:0];
            37: f_val = error_q >= 10 ? 4'd1 : 4'd0; 38: f_val = error_q >= 10 ? error_q - 4'd10 : error_q;
            39: f_val = {2'b00, lroom_q} + 4'd1;
            40: f_val = {2'b00, hroom_q} + 4'd1;
            41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52:
                f_val = rf_digit == 0 ? 4'd0 : rf_digit == 1 ? tens(rf_n) : ones(rf_n);
            53: f_val = {2'b00, res_pic} + 4'd1;
            54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64, 65, 66, 67, 68: f_val = res_cells[4 * rc +: 4];
            default: f_val = 10;
        endcase
    end

    // ---------------- slot -> string / colour ----------------
    localparam [2:0] C_INK = 0, C_LABEL = 1, C_TEAL = 2, C_AMBER = 3, C_GREEN = 4, C_RED = 5, C_TICK = 6, C_WHITE = 7;
    wire [5:0] slot;
    reg [11:0] s_sel;
    reg [2:0] c_sel;
    function [11:0] prompt_str; input [2:0] p;
        begin case (p) 0: prompt_str = S_PROMPT0; 1: prompt_str = S_PROMPT1; 2: prompt_str = S_PROMPT2;
            3: prompt_str = S_PROMPT3; 4: prompt_str = S_PROMPT4; 5: prompt_str = S_PROMPT5;
            6: prompt_str = S_PROMPT6; default: prompt_str = S_PROMPT7; endcase end
    endfunction
    // room list: present rooms only; a room without a patient says "空闲"
    function [11:0] room_str; input [1:0] r; input on;
        begin case (r)
            0: room_str = on ? S_ROOM0_ON : S_ROOM0_OFF; 1: room_str = on ? S_ROOM1_ON : S_ROOM1_OFF;
            2: room_str = on ? S_ROOM2_ON : S_ROOM2_OFF; default: room_str = on ? S_ROOM3_ON : S_ROOM3_OFF;
        endcase end
    endfunction
    reg [1:0] rs;
    always @* begin
        s_sel = 12'd0; c_sel = C_INK;
        rs = slot == SL_ROOM0 ? 2'd0 : slot == SL_ROOM1 ? 2'd1 : slot == SL_ROOM2 ? 2'd2 : 2'd3;
        case (slot)
            SL_TITLE: s_sel = S_TITLE;
            SL_ERR: begin                               // voice faults first, then the photo error
                c_sel = C_RED;
                s_sel = voice_q == 2 ? S_VFAULT0 : voice_q == 3 ? S_VFAULT1 : voice_q == 4 ? S_VFAULT2 :
                        error_q != 0 ? S_ERR : 12'd0;
            end
            SL_NET: begin s_sel = phy_q ? S_NET_OK : S_NET_DOWN; c_sel = phy_q ? C_LABEL : C_RED; end
            SL_CLIN: begin s_sel = online_q ? S_CLIN_ON : S_CLIN_OFF; c_sel = online_q ? C_GREEN : C_RED; end
            SL_CALL_LABEL: s_sel = S_CALL_LABEL;
            SL_BIGNUM: begin s_sel = number_q != 0 ? S_BIGNUM : 12'd0; c_sel = C_AMBER; end
            SL_ROOMNUM: begin s_sel = number_q != 0 ? S_ROOMNUM : 12'd0; c_sel = C_AMBER; end
            SL_C1_PRE: s_sel = number_q != 0 ? S_C1_PRE : S_C_WAIT;
            SL_C1_POST: s_sel = number_q != 0 ? S_C1_POST : 12'd0;
            SL_C2_PRE: s_sel = number_q != 0 ? S_C2_PRE : 12'd0;
            SL_C2_POST: s_sel = number_q != 0 ? S_C2_POST : 12'd0;
            SL_FLASH_TAG: begin s_sel = flash_on ? S_FLASH_TAG : 12'd0; c_sel = C_WHITE; end
            SL_LOADING: s_sel = ready_q ? 12'd0 : S_LOADING;
            SL_L_NEXT: begin s_sel = S_L_NEXT; c_sel = C_LABEL; end
            SL_L_WAIT: begin s_sel = S_L_WAIT; c_sel = C_LABEL; end
            SL_L_ISSUED: begin s_sel = S_L_ISSUED; c_sel = C_LABEL; end
            SL_L_HIST: begin s_sel = S_L_HIST; c_sel = C_LABEL; end
            SL_L_ROOMS: begin s_sel = S_L_ROOMS; c_sel = C_LABEL; end
            SL_L_HELP: begin s_sel = S_L_HELP; c_sel = C_LABEL; end
            SL_V_NEXT: s_sel = waiting_q != 0 ? S_V_NEXT : S_V_NEXT_NONE;
            SL_V_WAIT: s_sel = S_V_WAIT;
            SL_V_ISSUED: s_sel = S_V_ISSUED;
            SL_V_HIST: s_sel = S_V_HIST;
            SL_ROOM0, SL_ROOM1, SL_ROOM2, SL_ROOM3: begin
                s_sel = present_q[rs] ? room_str(rs, rooms_q[5 * rs +: 5] != 0) : 12'd0;
                c_sel = number_q != 0 && rs == lroom_q && rooms_q[5 * rs +: 5] == number_q ? C_AMBER :
                        rooms_q[5 * rs +: 5] != 0 ? C_INK : C_LABEL;
            end
            SL_V_HELP: begin
                s_sel = help_q == 0 ? S_HELP0 : help_q == 1 ? S_HELP1 : S_HELP2;
                c_sel = help_q == 1 ? C_RED : C_GREEN;
            end
            SL_B0: begin
                if (show_prompt) begin s_sel = prompt_str(prompt_id); c_sel = C_RED; end
                else if (show_adjust) begin s_sel = S_A_BRI; c_sel = C_INK; end
                else if (show_res) begin s_sel = S_RES_PIC; c_sel = C_TEAL; end
                else begin s_sel = S_TIP; c_sel = C_TEAL; end
            end
            SL_B1: s_sel = show_adjust ? S_A_CON : 12'd0;
            SL_B2: s_sel = show_adjust ? S_A_MUS : 12'd0;
            SL_B3: s_sel = show_adjust ? S_A_VOI : 12'd0;
            SL_B4: s_sel = show_adjust ? (auto_q ? S_A_AUTO : S_A_MANUAL) : 12'd0;
            SL_TICKER: begin s_sel = show_adjust || show_prompt || show_res ? 12'd0 : S_TICKER; c_sel = C_TICK; end
            SL_RES_LINE: s_sel = show_res ? S_RES_LINE : 12'd0;
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
    // tables: one-clock read, 9K BRAM (TD would build these small ROMs from LUTs)
    ui_table_rom #(.WIDTH(32), .WORDS(1 << UI_ITEM_AW), .AW(UI_ITEM_AW), .INIT("hall_item.mif"), .HEX("hall_item.hex"))
        u_items(.clk(clk), .addr(it_addr[UI_ITEM_AW-1:0]), .q(it_q));
    ui_table_rom #(.WIDTH(12), .WORDS(1 << UI_STR_AW), .AW(UI_STR_AW), .INIT("hall_str.mif"), .HEX("hall_str.hex"))
        u_strings(.clk(clk), .addr(s_addr[UI_STR_AW-1:0]), .q(s_q));
    ui_table_rom #(.WIDTH(25), .WORDS(1 << UI_GTAB_AW), .AW(UI_GTAB_AW), .INIT("hall_gtab.mif"), .HEX("hall_gtab.hex"))
        u_gtab(.clk(clk), .addr(g_addr[UI_GTAB_AW-1:0]), .q(g_q));
    ui_glyph_rom #(.WORDS(UI_GLYPH_WORDS), .INIT("hall_glyph.mif"), .HEX("hall_glyph.hex"), .BRAM(UI_GLYPH_BRAM)) u_glyphs(
        .clk(clk), .addr(p_addr), .q(p_q));
    wire [2:0] q_font;
    wire [1:0] cov;
    wire [2:0] tcolor;
    ui_text_engine #(.H_BLANK(H_BLANK), .ITEMS(UI_ITEMS), .TICKER_SLOT(SL_TICKER),
                     .TICKER_X0(TICKER_X0), .TICKER_X1(TICKER_X1), .TICKER_GAP(TICKER_GAP)) u_text(
        .clk(clk), .rst(rst), .video_x(video_x), .pixel_y(pixel_y), .scroll(scroll),
        .it_addr(it_addr), .it_q(it_q), .q_slot(slot), .slot_saddr(s_sel), .slot_color(c_sel),
        .slot_xov(1'b0), .slot_x(10'd0),
        .s_addr(s_addr), .s_q(s_q), .q_field(f_no), .field_val(f_val), .q_font(q_font),
        .digit_base(font_digit_base(q_font)),
        .g_addr(g_addr), .g_q(g_q), .p_addr(p_addr), .p_q(p_q), .cov(cov), .color(tcolor));

    // ---------------- compositing ----------------
    wire [11:0] ax = video_x - H_BLANK;
    wire [8:0] y = pixel_y[8:0];
    wire band = y < 9'd46 || y >= 9'd322;
    // lightened photo: in*5/8 + 96 per channel (shift-add, no multiplier)
    function [7:0] lift; input [7:0] v; begin lift = (v >> 1) + (v >> 3) + 8'd96; end endfunction
    // header rule and accent, info-block rule
    wire accent = ax >= 18 && ax < 46 && y >= 41 && y < 44;
    wire rule = (y == 9'd45 || y == 9'd428) && ax >= 18 && ax < 622;
    // "听力差" call / replay: pill badge (pulsing)
    localparam integer PILL_X1 = PILL_X0 + W_FLASH_TAG + 28;      // PILL_X0 / PILL_Y0: hall_ui.vh
    wire [4:0] py_pill = y[4:0] - PILL_Y0[4:0];      // row inside the badge (valid when in_pill_y)
    wire in_pill_y = y >= PILL_Y0 && y < PILL_Y0 + 30;
    reg [3:0] pill_inset;                             // round(15 - sqrt(15^2 - (row - 14.5)^2))
    always @* begin
        case (py_pill)
            0, 29: pill_inset = 11; 1, 28: pill_inset = 8; 2, 27: pill_inset = 7; 3, 26: pill_inset = 5;
            4, 25: pill_inset = 4; 5, 6, 23, 24: pill_inset = 3; 7, 22: pill_inset = 2;
            8, 9, 10, 19, 20, 21: pill_inset = 1; default: pill_inset = 0;
        endcase
    end
    // x >= X0 + inset and x < X1 - inset, as 4-bit tests on the distance from each end (cheaper)
    wire in_pill_x = ax >= PILL_X0 && ax < PILL_X1;
    wire [11:0] dl = ax - PILL_X0, dr = PILL_X1 - 1 - ax;
    wire end_ok = (dl >= 16 || dl[3:0] >= pill_inset) && (dr >= 16 || dr[3:0] >= pill_inset);
    wire flash_pill = flash_on && in_pill_y && in_pill_x && end_ok;
    // SW1 up: amber underline (2 px) under the volume being adjusted
    wire [11:0] ul_x0 = target_q ? UL_VOI_X0 : UL_MUS_X0;
    wire underline = volmode_q && show_adjust && (y == UL_Y0 || y == UL_Y0 + 1) &&
                     ax >= ul_x0 && ax < ul_x0 + (target_q ? W_A_VOI : W_A_MUS);
    reg [23:0] fg;
    always @* begin
        case (tcolor)
            C_INK: fg = 24'h1f2933; C_LABEL: fg = 24'h4b5563; C_TEAL: fg = 24'h0e6e6e; C_AMBER: fg = 24'hf08c00;
            C_GREEN: fg = 24'h2e9e5b; C_RED: fg = 24'hd64545; C_TICK: fg = 24'hc2410c; default: fg = 24'hffffff;
        endcase
    end
    // out = bg + (fg - bg) * a, a = 85/256 or 171/256 for the partial coverages (one multiplier
    // per channel, DSP), a = 0 / 1 exactly
    wire [8:0] alpha = cov == 2'd1 ? 9'd85 : 9'd171;
    function [7:0] mix; input [7:0] b, f; input [1:0] a; input [8:0] k;
        reg signed [9:0] d; reg signed [18:0] m;
        begin
            d = $signed({2'b00, f}) - $signed({2'b00, b});
            m = d * $signed({1'b0, k});
            mix = a == 2'd3 ? f : a == 2'd0 ? b : b + m[15:8];
        end
    endfunction
    reg [23:0] base;
    always @* begin
        base = in_rgb;
        if (band) base = {lift(in_rgb[23:16]), lift(in_rgb[15:8]), lift(in_rgb[7:0])};
        if (rule) base = 24'hd2d6dc;
        if (accent) base = 24'h0e6e6e;
        if (flash_pill || underline) base = 24'hf08c00;
    end
    assign out_de = in_de;
    always @* begin
        out_rgb = in_rgb;
        if (in_de && ax < 640 && pixel_y < 480)
            out_rgb = {mix(base[23:16], fg[23:16], cov, alpha), mix(base[15:8], fg[15:8], cov, alpha),
                       mix(base[7:0], fg[7:0], cov, alpha)};
    end
endmodule
