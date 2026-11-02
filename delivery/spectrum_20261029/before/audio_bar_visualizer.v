`timescale 1ns/1ps
// 10/28 audio bar visualiser for the hall screen (replaces the line waveform on the photo).
//
// 16 bars, 12 px wide with a 4 px gap, in BAR_X..BAR_X+255 x BAR_Y..BAR_Y+63 (the right half of
// the old waveform box). A bar is the loudness envelope of the sound, not a spectrum: the PCM taps
// (pixel domain, pcm_tap_cdc, one per audio sample) are split into windows of WINDOW taps
// (4096 at 48 kHz: about 12 a second); the peak |sample| of a window becomes the newest bar.
// Bars run from the oldest (left) to the newest (right) and move with the music.
// Bar height = peak >> 1 (0..127 from the upper byte of |sample|), at least 1 px when sound is
// present, at most 61 px so the 2-px cap (1 px gap) always fits inside the 64-px box.
// Each bar has an amber peak cap (2 px, 1 px above the cap height) that jumps up with the bar and
// falls 1 px every CAP_FALL frames. Colours: bar teal 0E6E6E, cap amber F08C00 (hall UI palette).
//
// Frame rule (everything visible changes only here, so a frame never tears):
//   at a frame start, if enable is low the bars and caps are cleared and a waiting window is
//   dropped; otherwise, if a window completed since the last frame start, its value enters on the
//   right (only the newest one if several completed); then every cap rises to its bar or, on
//   every CAP_FALL-th frame, falls by 1. The frame shows the result; it is visible when show (SW2)
//   and enable were both 1 at the frame start.
// Implementation (hall board resources): bars live in a 16 x 6 LUT RAM addressed through a
// rotating pointer (slot of the oldest bar), caps in a 16 x 6 LUT RAM addressed by the column; the
// frame-start work runs one column per clock in the vertical blank (17 clocks) - no 16-way
// parallel logic, no frame copy.
module audio_bar_visualizer #(
    parameter integer BAR_X = 320, BAR_Y = 252, BARS = 16, BAR_W = 12, BAR_PITCH = 16, BAR_H = 64,
    parameter integer WINDOW = 4096,              // taps per bar
    parameter integer CAP_FALL = 3,               // frames per 1 px of cap fall
    parameter [23:0] BAR_COLOR = 24'h0e6e6e, CAP_COLOR = 24'hf08c00
)(
    input wire clk, rst_n, vsync, de,
    input wire [23:0] rgb_in,
    input wire [9:0] pixel_x,
    input wire show,                              // SW2 up
    input wire enable, pcm_tap_valid,
    input wire signed [15:0] pcm_tap_left,
    output wire [23:0] rgb_out
);
    localparam integer WB = $clog2(WINDOW);
    reg vs_q, de_q;
    wire frame_start = vs_q && !vsync;
    reg [8:0] line_y;
    // ---------------- capture: window peak -> one waiting bar value ----------------
    wire [15:0] mag = pcm_tap_left[15] ? (~pcm_tap_left + 16'd1) : pcm_tap_left;
    wire [6:0] mag7 = mag[15] ? 7'd127 : mag[14:8];     // 0..127
    reg [6:0] win_peak;
    reg [WB-1:0] win_n;
    wire [6:0] win_max = win_peak > mag7 ? win_peak : mag7;
    wire [5:0] half = win_max[6:1] | {5'd0, win_max != 0};      // 0..63, at least 1 with sound
    wire [5:0] new_bar = half > 6'd61 ? 6'd61 : half;           // <= 61: the cap always fits above
    reg pend;                                      // a window completed since the last frame start
    reg [5:0] pend_val;
    // ---------------- bar / cap store: 16 x 6 LUT RAMs, ptr = address of the oldest bar ----------
    reg [5:0] lv_mem [0:BARS-1];
    reg [5:0] cap_mem [0:BARS-1];
    reg [3:0] ptr;
    reg sweep, first, clr, fall_now, vis;
    reg [3:0] sk;
    reg [1:0] fall_n;
    wire [9:0] rx = pixel_x - BAR_X;              // x inside the box
    // position j (0 = left, oldest): bar in slot ptr + j, cap in slot j (caps stay with the column)
    wire [3:0] pos = sweep ? sk : rx[7:4];        // BAR_PITCH = 16
    wire [5:0] h = lv_mem[ptr + pos];
    wire [5:0] c = cap_mem[pos];
    always @(posedge clk) begin
        if (sweep && first && !clr && pend) lv_mem[ptr] <= pend_val;
        if (sweep && !first) begin
            if (clr) begin lv_mem[sk] <= 6'd0; cap_mem[sk] <= 6'd0; end
            else if (h >= c) cap_mem[sk] <= h;
            else if (fall_now) cap_mem[sk] <= c - 1'b1;
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vs_q <= 1; de_q <= 0; line_y <= 0;
            win_peak <= 0; win_n <= 0; pend <= 0; pend_val <= 0;
            ptr <= 0; sweep <= 0; first <= 0; clr <= 1; fall_now <= 0; fall_n <= 0; vis <= 0; sk <= 0;
        end else begin
            vs_q <= vsync; de_q <= de;
            if (!vsync) line_y <= 0;
            else if (de_q && !de) line_y <= line_y + 1'b1;
            // frame-start work, one step per clock in the vertical blank
            if (frame_start) begin
                sweep <= 1'b1; first <= 1'b1; sk <= 0; clr <= !enable; vis <= show && enable;
                fall_now <= fall_n == 0;
                fall_n <= fall_n == CAP_FALL - 1 ? 2'd0 : fall_n + 1'b1;
            end else if (sweep) begin
                if (first) begin
                    first <= 1'b0;
                    if (!clr && pend) ptr <= ptr + 1'b1;     // the newest replaced the oldest
                    pend <= 1'b0;
                end else begin
                    sk <= sk + 1'b1;
                    if (sk == BARS - 1) sweep <= 1'b0;
                end
            end
            // capture (after the sweep step, so a window completing on that clock stays waiting)
            if (!enable) begin
                win_peak <= 0; win_n <= 0; pend <= 0;
            end else if (pcm_tap_valid) begin
                if (win_n == WINDOW - 1) begin
                    pend <= 1'b1; pend_val <= new_bar;
                    win_peak <= 0; win_n <= 0;
                end else begin
                    if (mag7 > win_peak) win_peak <= mag7;
                    win_n <= win_n + 1'b1;
                end
            end
        end
    end
    // ---------------- drawing ----------------
    wire [8:0] ry = line_y - BAR_Y;
    wire in_box = vis && de && pixel_x >= BAR_X && pixel_x < BAR_X + BARS * BAR_PITCH &&
                  line_y >= BAR_Y && line_y < BAR_Y + BAR_H;
    wire in_bar_x = rx[3:0] < BAR_W;
    wire [5:0] up = BAR_H - 1 - ry[5:0];          // height above the bottom, 0..63
    wire bar_px = in_box && in_bar_x && up < h;
    wire cap_px = in_box && in_bar_x && c != 0 && (up == c + 1 || up == c + 2);
    assign rgb_out = cap_px ? CAP_COLOR : bar_px ? BAR_COLOR : rgb_in;
    // synthesis translate_off
    integer k;
    initial for (k = 0; k < BARS; k = k + 1) begin lv_mem[k] = 0; cap_mem[k] = 0; end
    initial if (BAR_PITCH != 16 || BARS != 16 || BAR_H != 64) $fatal(1, "bar geometry is fixed (16 x 16 px, 64 px high)");
    // synthesis translate_on
endmodule
