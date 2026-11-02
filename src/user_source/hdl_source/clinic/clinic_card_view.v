`timescale 1ns/1ps
// 10/23 诊室板：表达卡片图层 —— 两排小卡片 + 触摸点卡后的放大动画。
//
// Sits after clinic_screen (which draws the frames, the text fallback and the rest of the page)
// and before the HDMI path; DE/HS/VS are not delayed. Everything is in video_clk.
//
//  * Small cards: six 120x90 cells, row-major in card order, cell (c, r) at
//    x = 24 + 136c, y = 262 + 100r. A loaded card is drawn 1:1 from the store
//    (index -> palette); a card that is not loaded keeps clinic_screen's text fallback.
//  * Trigger (the hall board is unchanged): the status frame's last_card/last_card_valid.
//    A card zooms when last_card becomes valid or changes, or the click counter (status d9,
//    10/24) changes - so the same card zooms again once it has shrunk; a new help request
//    (help_state -> 1) zooms card 0. The first ARM_FRAMES frames after the link comes up only
//    record the state (no zoom at power-up or reconnect). Clicking the card that is zoomed
//    is ignored; another card during the hold ends the hold and is shown next (one pending).
//  * Animation: GROW k = 1..N (ease-out, N = 18 frames, about 0.3 s), HOLD HOLD_FRAMES
//    (298 frames = 5.0 s at 59.5 Hz), SHRINK k = N-1..1, back in the cell. Frame k draws the
//    card at size zw x zh (120x90 -> 360x270) between its cell and the screen centre
//    (140,105), bilinear filtered, with a 3-pixel border; the rest of the screen is darkened
//    by up to 55 %. Geometry only changes at frame_start.
//  * Bilinear: per line, the two source rows are read during horizontal blanking
//    (index -> palette -> RGB) into row buffers (two copies each, so columns j and j+1 are
//    read in the same clock). Pixel centres are aligned: s = (o + 0.5) * step - 0.5, Q16.
//  * Card not loaded: the zoom box is white while moving and shows clinic_screen's centred
//    text panel during the hold (zoom_panel = 1).
//  Pipeline: the pixel at active x is fetched LA = 6 clocks ahead; stage-5 registers belong to
//  the pixel shown in the current clock, which is when clinic_screen's in_rgb is valid too.
module clinic_card_view #(
    parameter integer H_BLANK = 160,
    parameter integer HOLD_FRAMES = 298,
    parameter integer ARM_FRAMES = 2,
    // 10/25 ENT clinic screen: no small-card grid (SHOW_GRID 0, the zoom still starts from the
    // card's grid cell); the help request zooms HELP_CARD (red border) instead of card 0
    parameter integer SHOW_GRID = 1,
    parameter integer HELP_CARD = 0,
    // a strip below the zoom box that is not darkened (clinic_screen writes the zoom title there)
    parameter integer KEEP_Y0 = 0, KEEP_Y1 = 0
)(
    input wire clk, rst, frame_start,
    input wire [11:0] video_x,          // raw horizontal counter (active x = video_x - H_BLANK)
    input wire [11:0] pixel_y,          // active y (wraps to large values in vertical blanking)
    input wire de,
    input wire [23:0] in_rgb,           // clinic_screen output for the current pixel
    output reg [23:0] out_rgb,
    // hall status, frame-latched by the top
    input wire link_up,
    input wire [2:0] last_card,
    input wire last_card_valid,
    input wire [1:0] help_state,
    input wire [7:0] card_clicks,
    // card store
    input wire [5:0] card_ready,
    input wire store_busy,
    output reg [15:0] pix_ra, pix_rb, input wire [7:0] pix_qa, pix_qb,
    output reg [10:0] pal_ra, pal_rb, input wire [23:0] pal_qa, pal_qb,
    // to clinic_screen
    output reg zoom_panel,
    output reg [2:0] zoom_card,
    output wire zoom_active,
    output reg zoom_full                // 10/30: this zoom's hold ran its full time (cleared at GROW)
);
    localparam integer N = 18, CW = 120, CH = 90, LA = 6;
    localparam integer XC = 140, YC = 105;           // final top-left: (640-360)/2, (480-270)/2
    localparam integer GX = 24, GDX = 136, GY = 262, GDY = 100;
    localparam [23:0] WHITE = 24'hffffff, BORDER = 24'h0e6e6e, BORDER_HELP = 24'hd64545;   // 10/24 palette
    localparam [1:0] IDLE = 0, GROW = 1, HOLD = 2, SHRINK = 3;

    // ================= trigger and animation state (frame rate) =================
    reg [1:0] st;
    reg [4:0] k;
    reg [8:0] hold_cnt;
    reg pend;
    reg [2:0] pcard;
    reg armed;
    reg [1:0] arm_cnt;
    reg [2:0] prev_card;
    reg prev_valid;
    reg [1:0] prev_help;
    reg [7:0] prev_clicks;
    wire new_card = last_card_valid && (!prev_valid || last_card != prev_card || card_clicks != prev_clicks);
    wire new_help = help_state == 2'd1 && prev_help != 2'd1;
    wire trig = armed && link_up && (new_card || new_help);
    wire [2:0] trig_card = new_card ? last_card : HELP_CARD[2:0];
    wire other = trig && trig_card != zoom_card;     // a different card while one is zoomed
    assign zoom_active = st != IDLE;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            st <= IDLE; k <= 0; hold_cnt <= 0; pend <= 0; pcard <= 0; zoom_card <= 0; zoom_full <= 0;
            armed <= 0; arm_cnt <= 0; prev_card <= 0; prev_valid <= 0; prev_help <= 0; prev_clicks <= 0;
        end else if (frame_start) begin
            prev_card <= last_card; prev_valid <= last_card_valid; prev_help <= help_state; prev_clicks <= card_clicks;
            if (!link_up) begin armed <= 0; arm_cnt <= 0; end
            else if (arm_cnt != ARM_FRAMES) arm_cnt <= arm_cnt + 1'b1;
            else armed <= 1;
            case (st)
                IDLE: if (trig) begin st <= GROW; k <= 1; zoom_card <= trig_card; zoom_full <= 0; end
                GROW: begin
                    if (other) begin pend <= 1; pcard <= trig_card; end
                    if (k == N) begin st <= HOLD; hold_cnt <= 0; end
                    else k <= k + 1'b1;
                end
                HOLD: begin
                    if (other) begin pend <= 1; pcard <= trig_card; end
                    if (other || pend || hold_cnt == HOLD_FRAMES - 1) begin
                        st <= SHRINK; k <= N - 1; zoom_full <= !other && !pend;
                    end
                    else hold_cnt <= hold_cnt + 1'b1;
                end
                SHRINK: begin
                    if (other) begin pend <= 1; pcard <= trig_card; end
                    if (k == 1) begin
                        if (other) begin st <= GROW; k <= 1; zoom_card <= trig_card; pend <= 0; zoom_full <= 0; end
                        else if (pend) begin st <= GROW; k <= 1; zoom_card <= pcard; pend <= 0; zoom_full <= 0; end
                        else begin st <= IDLE; k <= 0; end
                    end else k <= k - 1'b1;
                end
            endcase
        end
    end

    // ================= frame constants =================
    reg [8:0] t_e, t_w, t_h;
    reg [16:0] t_sx, t_sy;
    reg [7:0] t_dim;
    // GEOM BEGIN (generated by delivery/clinic_cards_20261023/tools/make_zoom_table.py)
    always @* begin
        case (k)
            0: begin t_e = 9'd0; t_w = 9'd120; t_h = 9'd90; t_sx = 17'd65536; t_sy = 17'd65536; t_dim = 8'd0; end
            1: begin t_e = 9'd40; t_w = 9'd158; t_h = 9'd118; t_sx = 17'd49774; t_sy = 17'd49985; t_dim = 8'd22; end
            2: begin t_e = 9'd76; t_w = 9'd191; t_h = 9'd143; t_sx = 17'd41174; t_sy = 17'd41246; t_dim = 8'd42; end
            3: begin t_e = 9'd108; t_w = 9'd221; t_h = 9'd166; t_sx = 17'd35585; t_sy = 17'd35531; t_dim = 8'd59; end
            4: begin t_e = 9'd136; t_w = 9'd248; t_h = 9'd186; t_sx = 17'd31710; t_sy = 17'd31710; t_dim = 8'd74; end
            5: begin t_e = 9'd160; t_w = 9'd270; t_h = 9'd203; t_sx = 17'd29127; t_sy = 17'd29055; t_dim = 8'd88; end
            6: begin t_e = 9'd180; t_w = 9'd289; t_h = 9'd217; t_sx = 17'd27212; t_sy = 17'd27180; t_dim = 8'd98; end
            7: begin t_e = 9'd198; t_w = 9'd306; t_h = 9'd229; t_sx = 17'd25700; t_sy = 17'd25756; t_dim = 8'd108; end
            8: begin t_e = 9'd212; t_w = 9'd319; t_h = 9'd239; t_sx = 17'd24653; t_sy = 17'd24678; t_dim = 8'd116; end
            9: begin t_e = 9'd224; t_w = 9'd330; t_h = 9'd248; t_sx = 17'd23831; t_sy = 17'd23783; t_dim = 8'd123; end
            10: begin t_e = 9'd234; t_w = 9'd339; t_h = 9'd255; t_sx = 17'd23198; t_sy = 17'd23130; t_dim = 8'd128; end
            11: begin t_e = 9'd241; t_w = 9'd346; t_h = 9'd259; t_sx = 17'd22729; t_sy = 17'd22773; t_dim = 8'd132; end
            12: begin t_e = 9'd247; t_w = 9'd352; t_h = 9'd264; t_sx = 17'd22341; t_sy = 17'd22341; t_dim = 8'd135; end
            13: begin t_e = 9'd251; t_w = 9'd355; t_h = 9'd266; t_sx = 17'd22153; t_sy = 17'd22173; t_dim = 8'd137; end
            14: begin t_e = 9'd253; t_w = 9'd357; t_h = 9'd268; t_sx = 17'd22028; t_sy = 17'd22008; t_dim = 8'd138; end
            15: begin t_e = 9'd255; t_w = 9'd359; t_h = 9'd269; t_sx = 17'd21906; t_sy = 17'd21926; t_dim = 8'd139; end
            16: begin t_e = 9'd256; t_w = 9'd360; t_h = 9'd270; t_sx = 17'd21845; t_sy = 17'd21845; t_dim = 8'd140; end
            17: begin t_e = 9'd256; t_w = 9'd360; t_h = 9'd270; t_sx = 17'd21845; t_sy = 17'd21845; t_dim = 8'd140; end
            18: begin t_e = 9'd256; t_w = 9'd360; t_h = 9'd270; t_sx = 17'd21845; t_sy = 17'd21845; t_dim = 8'd140; end
            default: begin t_e = 9'd0; t_w = 9'd120; t_h = 9'd90; t_sx = 17'd65536; t_sy = 17'd65536; t_dim = 8'd0; end
        endcase
    end
    // GEOM END
    reg fs_d1, fs_d2;
    reg zoom_on, img_ok, holding;
    reg [5:0] ready_q;                  // card_ready, frame-latched for the small cards
    reg [1:0] zcol;
    reg zrow;
    reg [11:0] x0, y0, x1, y1;          // image box [x0,x1) x [y0,y1)
    reg [16:0] stepx, stepy;
    reg signed [18:0] sx0, sy0;
    reg [7:0] dim;
    reg [15:0] cbase;
    reg signed [10:0] dxs, dys;
    reg [11:0] xs, ys;
    wire signed [20:0] px_off = dxs * $signed({1'b0, t_e}) + 21'sd128;
    wire signed [20:0] py_off = dys * $signed({1'b0, t_e}) + 21'sd128;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            fs_d1 <= 0; fs_d2 <= 0; zoom_on <= 0; img_ok <= 0; holding <= 0; zoom_panel <= 0; ready_q <= 0;
            zcol <= 0; zrow <= 0; xs <= GX; ys <= GY; dxs <= 0; dys <= 0;
            x0 <= 0; y0 <= 0; x1 <= 0; y1 <= 0; stepx <= 0; stepy <= 0; sx0 <= 0; sy0 <= 0; dim <= 0; cbase <= 0;
        end else begin
            fs_d1 <= frame_start; fs_d2 <= fs_d1;
            // the state above changes at frame_start; everything below is stable two clocks later,
            // long before the first active line
            zcol <= zoom_card == 3'd0 || zoom_card == 3'd3 ? 2'd0 : zoom_card == 3'd1 || zoom_card == 3'd4 ? 2'd1 : 2'd2;
            zrow <= zoom_card >= 3'd3;
            xs <= GX + zcol * GDX;
            ys <= GY + (zrow ? GDY : 0);
            dxs <= XC - $signed({1'b0, xs[9:0]});
            dys <= YC - $signed({1'b0, ys[9:0]});
            x0 <= xs + px_off[20:8];
            y0 <= ys + py_off[20:8];
            x1 <= xs + px_off[20:8] + t_w;
            y1 <= ys + py_off[20:8] + t_h;
            stepx <= t_sx; stepy <= t_sy; dim <= t_dim;
            sx0 <= $signed({2'b00, t_sx[16:1]}) - 19'sd32768;
            sy0 <= $signed({2'b00, t_sy[16:1]}) - 19'sd32768;
            cbase <= zoom_card * 14'd10800;
            if (fs_d2) begin
                ready_q <= card_ready;
                zoom_on <= st != IDLE;
                holding <= st == HOLD;
                img_ok <= card_ready[zoom_card] && !store_busy;
                zoom_panel <= st == HOLD && !(card_ready[zoom_card] && !store_busy);
            end
        end
    end

    // ================= line constants (horizontal blanking) =================
    wire [11:0] py = pixel_y;
    reg ly_img, ly_ring, line_fill;
    reg [11:0] oy;
    reg signed [27:0] sy;
    reg [6:0] r0, r1;
    reg [7:0] fy;
    reg [15:0] row_a, row_b;
    reg srow_ok, srow;
    reg [15:0] sline;                   // small cards: card row base + v*120
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            ly_img <= 0; ly_ring <= 0; line_fill <= 0; oy <= 0; sy <= 0; r0 <= 0; r1 <= 0; fy <= 0;
            row_a <= 0; row_b <= 0; srow_ok <= 0; srow <= 0; sline <= 0;
        end else begin
            if (video_x == 12'd0) begin
                ly_img <= py >= y0 && py < y1;
                ly_ring <= py + 12'd3 >= y0 && py < y1 + 12'd3;
                oy <= py - y0;
                srow_ok <= (py >= GY && py < GY + CH) || (py >= GY + GDY && py < GY + GDY + CH);
                srow <= py >= GY + GDY;
            end
            if (video_x == 12'd1) begin
                sy <= sy0 + $signed({1'b0, oy}) * $signed({1'b0, stepy});
                line_fill <= zoom_on && img_ok && !store_busy && ly_img;
                sline <= (srow ? 16'd32400 : 16'd0) + (py - (srow ? GY + GDY : GY)) * 16'd120;
            end
            if (video_x == 12'd2) begin
                r0 <= sy < 0 ? 7'd0 : sy[22:16];
                fy <= sy < 0 ? 8'd0 : sy[15:8];
            end
            if (video_x == 12'd3) begin
                r1 <= r0 >= CH - 1 ? CH - 1 : r0 + 1'b1;
            end
            if (video_x == 12'd4) begin
                row_a <= cbase + r0 * 16'd120;
                row_b <= cbase + r1 * 16'd120;
            end
        end
    end

    // ================= store reads: row fill (blanking) / small cards (active) =================
    wire fill_window = video_x >= 12'd8 && video_x < 12'd8 + CW;
    wire [6:0] fk = video_x - 12'd8;
    wire [11:0] p = video_x - H_BLANK + LA;          // pixel entering stage 0
    wire in_c0 = p >= GX && p < GX + CW;
    wire in_c1 = p >= GX + GDX && p < GX + GDX + CW;
    wire in_c2 = p >= GX + 2 * GDX && p < GX + 2 * GDX + CW;
    wire [1:0] c = in_c0 ? 2'd0 : in_c1 ? 2'd1 : 2'd2;
    wire [6:0] u = p - (in_c0 ? GX : in_c1 ? GX + GDX : GX + 2 * GDX);
    wire [2:0] sid = (srow ? 3'd3 : 3'd0) + c;
    wire in_cell = srow_ok && (in_c0 || in_c1 || in_c2);
    wire small_hit = SHOW_GRID != 0 && in_cell && ready_q[sid] && !(zoom_on && sid == zoom_card);
    wire hole_hit = SHOW_GRID != 0 && in_cell && zoom_on && sid == zoom_card;   // the zoomed card's cell is left empty
    reg [5:0] hv;                       // hole valid, stages 0..5
    reg [5:0] fv;                       // fill valid, stages 0..5
    reg [6:0] fk0, fk1, fk2, fk3, fk4, fk5;
    reg [5:0] sv;                       // small-card valid, stages 0..5
    reg [2:0] sid0, sid1, sid2;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            pix_ra <= 0; pix_rb <= 0; pal_ra <= 0; pal_rb <= 0; fv <= 0; sv <= 0; hv <= 0;
            fk0 <= 0; fk1 <= 0; fk2 <= 0; fk3 <= 0; fk4 <= 0; fk5 <= 0; sid0 <= 0; sid1 <= 0; sid2 <= 0;
        end else begin
            // stage 0: card RAM addresses
            if (fill_window) begin
                pix_ra <= row_a + fk;
                pix_rb <= row_b + fk;
            end else
                pix_rb <= sline + (c == 2'd0 ? 16'd0 : c == 2'd1 ? 16'd10800 : 16'd21600) + u;
            fv <= {fv[4:0], fill_window && line_fill};
            sv <= {sv[4:0], !fill_window && small_hit};
            hv <= {hv[4:0], !fill_window && hole_hit};
            fk0 <= fk; fk1 <= fk0; fk2 <= fk1; fk3 <= fk2; fk4 <= fk3; fk5 <= fk4;
            sid0 <= fill_window ? zoom_card : sid; sid1 <= sid0; sid2 <= sid1;
            // stage 3: palette addresses from the indices read two clocks earlier
            pal_ra <= {zoom_card, pix_qa};
            pal_rb <= {sid2, pix_qb};
        end
    end

    // row buffers: rows r0 (a) and r1 (b), two copies each for the j / j+1 reads
    reg [23:0] rb_a0 [0:127];
    reg [23:0] rb_a1 [0:127];
    reg [23:0] rb_b0 [0:127];
    reg [23:0] rb_b1 [0:127];
    always @(posedge clk) begin
        if (fv[5]) begin
            rb_a0[fk5] <= pal_qa; rb_a1[fk5] <= pal_qa;
            rb_b0[fk5] <= pal_qb; rb_b1[fk5] <= pal_qb;
        end
    end

    // ================= zoom pixel pipeline =================
    function [7:0] lerp;
        input [7:0] a, b, t;
        reg signed [17:0] v;
        begin
            v = $signed({2'b00, a, 8'd0}) + ($signed({1'b0, b}) - $signed({1'b0, a})) * $signed({1'b0, t}) + 18'sd128;
            lerp = v[15:8];
        end
    endfunction
    wire zx_img = p >= x0 && p < x1;
    wire zx_ring = p + 12'd3 >= x0 && p < x1 + 12'd3;
    reg [11:0] dx0;
    reg [5:0] zimg, zring;              // stage flags 0..5
    reg signed [27:0] sx1;
    reg [23:0] q00, q01, q10, q11;
    reg [7:0] fx2;
    reg [7:0] top_r, top_g, top_b, bot_r, bot_g, bot_b;
    reg [23:0] z4, z5;
    wire [6:0] j0 = sx1 < 0 ? 7'd0 : sx1[22:16];
    wire [6:0] j1 = j0 >= CW - 1 ? CW - 1 : j0 + 1'b1;
    wire [7:0] fx = sx1 < 0 ? 8'd0 : sx1[15:8];
    // stage 2: row-buffer reads (no reset, so the buffers map to RAM with a read register)
    always @(posedge clk) begin
        q00 <= rb_a0[j0]; q01 <= rb_a1[j1]; q10 <= rb_b0[j0]; q11 <= rb_b1[j1];
    end
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            dx0 <= 0; zimg <= 0; zring <= 0; sx1 <= 0; fx2 <= 0;
            top_r <= 0; top_g <= 0; top_b <= 0; bot_r <= 0; bot_g <= 0; bot_b <= 0; z4 <= 0; z5 <= 0;
        end else begin
            dx0 <= p - x0;                                                    // stage 0
            zimg <= {zimg[4:0], zx_img && ly_img};
            zring <= {zring[4:0], zx_ring && ly_ring && !(zx_img && ly_img)};
            sx1 <= sx0 + $signed({1'b0, dx0}) * $signed({1'b0, stepx});     // stage 1
            fx2 <= fx;                                                        // stage 2
            top_r <= lerp(q00[23:16], q01[23:16], fx2); bot_r <= lerp(q10[23:16], q11[23:16], fx2);   // stage 3
            top_g <= lerp(q00[15:8], q01[15:8], fx2);   bot_g <= lerp(q10[15:8], q11[15:8], fx2);
            top_b <= lerp(q00[7:0], q01[7:0], fx2);     bot_b <= lerp(q10[7:0], q11[7:0], fx2);
            z4 <= {lerp(top_r, bot_r, fy), lerp(top_g, bot_g, fy), lerp(top_b, bot_b, fy)};       // stage 4
            z5 <= z4;                                                                             // stage 5
        end
    end

    // ================= output =================
    function [7:0] darken;
        input [7:0] v, d;
        reg [16:0] m;
        begin m = v * (9'd256 - d); darken = m[15:8]; end
    endfunction
    localparam [23:0] PALE = 24'hf1f0ec;              // 10/24: clinic_screen cell colour
    wire [23:0] base = sv[5] ? pal_qb : hv[5] ? PALE : in_rgb;
    wire [11:0] keep_x = video_x - H_BLANK;             // the pixel shown now (in_rgb's pixel)
    wire keep = keep_x >= XC && keep_x < XC + 360 && pixel_y >= KEEP_Y0 && pixel_y < KEEP_Y1;
    always @* begin
        if (!de) out_rgb = in_rgb;
        else if (zoom_on && zring[5]) out_rgb = zoom_card == HELP_CARD[2:0] ? BORDER_HELP : BORDER;
        else if (zoom_on && zimg[5]) out_rgb = img_ok ? z5 : holding ? in_rgb : WHITE;
        else if (zoom_on && !keep) out_rgb = {darken(base[23:16], dim), darken(base[15:8], dim), darken(base[7:0], dim)};
        else out_rgb = base;
    end
endmodule
