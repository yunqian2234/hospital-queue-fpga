`timescale 1ns/1ps
// 10/28 audio_bar_visualizer bench: a compact raster (640 active pixels, short blanking, 330 lines,
// vsync low for 2 lines before line 0), PCM taps at random clocks with a random loudness envelope,
// random show / enable changes between frames. Logged for run_bars.py (independent Python model):
//   P <clock> <sample>        a tap (pcm_tap_valid) on that clock
//   F <clock> <show> <enable> a frame start (vsync falling edge seen by the module) on that clock
//   E <clock> <enable>        enable has this new value from that clock on
//   D <frame> then 64 x 256 pixel words of the bar box (x 320..575, y 252..315) of that frame
module tb_bars;
    parameter integer FRAMES = 60, SEED = 3;
    localparam integer HT = 680, VT = 332;               // 640 + 40 blanking, 2 vsync lines + 330
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    integer hc = 0, vc = 0, clock = 0, seed = SEED, fd, frame = 0, i;
    wire vsync = !(vc < 2);                              // low on lines 0..1
    wire de = vc >= 2 && hc < 640;
    wire [9:0] px = de ? hc[9:0] : 10'd0;
    wire [11:0] ly = vc - 2;
    wire [23:0] rgb_in = {hc[7:0], ly[7:0], 8'h5a};
    reg show = 1, enable = 1, tap = 0;
    reg signed [15:0] sample = 0;
    wire [23:0] rgb_out;
    audio_bar_visualizer #(.WINDOW(600)) dut(.clk(clk), .rst_n(rst_n), .vsync(vsync), .de(de), .rgb_in(rgb_in),
        .pixel_x(px), .show(show), .enable(enable), .pcm_tap_valid(tap), .pcm_tap_left(sample), .rgb_out(rgb_out));
    integer env = 8000, dump;
    reg en_q = 1;
    always @(posedge clk) if (rst_n) begin
        // enable as the capture sees it on this clock (the module samples it at this edge)
        if (enable != en_q) $fdisplay(fd, "E %0d %0d", clock, enable);
        en_q <= enable;
        if (tap) $fdisplay(fd, "P %0d %0d", clock, sample);
        if (dut.frame_start) $fdisplay(fd, "F %0d %0d %0d", clock, show, enable);
        if (dump && de && hc >= 320 && hc < 576 && ly >= 252 && ly < 316) $fdisplay(fd, "%06h", rgb_out);
    end
    always @(posedge clk) begin
        clock <= clock + 1;
        hc <= hc == HT - 1 ? 0 : hc + 1;
        if (hc == HT - 1) vc <= vc == VT - 1 ? 0 : vc + 1;
    end
    // taps: about one per 256 clocks
    always @(negedge clk) begin
        tap = ($random(seed) & 255) == 0;
        // loudness changes about once per bar window (600 taps x ~256 clocks): silence, very quiet
        // (|s| < 512: the 1-px minimum), random, full scale
        if (($random(seed) & 32'h1ffff) == 0)
            case ($random(seed) & 7)
                0: env = 0; 1, 2: env = 300 + ($random(seed) & 200); 3: env = 40000;
                default: env = ($random(seed) & 32767) + 1;
            endcase
        sample = env == 0 ? 0 : env >= 32768 ? (($random(seed) & 1) ? 16'sh8000 : 16'sh7fff) : ($random(seed) % env);
    end
    initial begin
        fd = $fopen("bars.log", "w"); dump = 0;
        repeat (7) @(negedge clk); rst_n = 1;
        for (frame = 0; frame < FRAMES; frame = frame + 1) begin
            // wait for line 2 (vsync just rose): the frame's pixels follow
            while (!(vc == 2 && hc == 0)) @(negedge clk);
            dump = (frame % 3) == 2 || frame > FRAMES - 6 || frame == 21;
            if (dump) $fdisplay(fd, "D %0d", frame);
            while (!(vc == 0 && hc == 5)) @(negedge clk);    // in vsync: change controls
            dump = 0;
            // SW2: shown most of the time, hidden for 3 frames from frame 20 and now and then
            show = !((frame >= 19 && frame < 22) || ($random(seed) & 15) == 0);
            if (($random(seed) & 15) == 0) enable = !enable;
        end
        $fclose(fd);
        $display("PASS BARS_DUMP");
        $finish;
    end
endmodule
