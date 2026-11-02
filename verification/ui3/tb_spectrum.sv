`timescale 1ns/1ps
// 10/29 spectrum bars bench (audio_bar_visualizer.v): compact raster (640 active pixels, short
// blanking, 330 lines, vsync low for 2 lines before line 0); PCM taps about every 520 clocks like
// 48 kHz at the 25 MHz pixel clock, carrying two tones (log-random 40 Hz .. 16 kHz, changed now and
// then) at a random loudness (silence, very quiet, medium, full scale, clipped); random SW2 / enable.
// Logged for run_spectrum.py (bit-exact Python model):
//   P <clock> <sample>        the engine starts on a tap (its sample: pcm_tap_left, held until the next tap)
//   F <clock> <show> <enable> a frame start (vsync falling edge seen by the module)
//   E <clock> <enable>        enable has this new value from that clock on
//   T <clock>                 a tap was accepted (pcm_tap_valid with enable high)
//   L <clock>                 a tap was LOST (arrived while one was still waiting or being worked on)
//   D <frame> then 64 x 256 pixel words of the bar box (x 320..575, y 252..315) of that frame
module tb_spectrum;
    parameter integer FRAMES = 60, SEED = 3;
    localparam integer HT = 680, VT = 332;
    reg clk = 0, rst_n = 0;
    always #20 clk = ~clk;
    integer hc = 0, vc = 0, clock = 0, seed = SEED, fd, frame = 0;
    wire vsync = !(vc < 2);
    wire de = vc >= 2 && hc < 640;
    wire [9:0] px = de ? hc[9:0] : 10'd0;
    wire [11:0] ly = vc - 2;
    wire [23:0] rgb_in = {hc[7:0], ly[7:0], 8'h5a};
    reg show = 1, enable = 1, tap = 0;
    reg signed [15:0] sample = 0;
    wire [23:0] rgb_out;
    audio_bar_visualizer dut(.clk(clk), .rst_n(rst_n), .vsync(vsync), .de(de), .rgb_in(rgb_in),
        .pixel_x(px), .show(show), .enable(enable), .pcm_tap_valid(tap), .pcm_tap_left(sample), .rgb_out(rgb_out));
    integer dump = 0;
    reg en_q = 1;
    always @(posedge clk) if (rst_n) begin
        if (enable != en_q) $fdisplay(fd, "E %0d %0d", clock, enable);
        en_q <= enable;
        if (tap && enable) $fdisplay(fd, "T %0d", clock);
        if (tap && enable && (dut.tap_pend || dut.st != 0)) $fdisplay(fd, "L %0d", clock);
        if (dut.eng_start) $fdisplay(fd, "P %0d %0d", clock, sample);
        if (dut.frame_start) $fdisplay(fd, "F %0d %0d %0d", clock, show, enable);
        if (dump && de && hc >= 320 && hc < 576 && ly >= 252 && ly < 316) $fdisplay(fd, "%06h", rgb_out);
    end
    always @(posedge clk) begin
        clock <= clock + 1;
        hc <= hc == HT - 1 ? 0 : hc + 1;
        if (hc == HT - 1) vc <= vc == VT - 1 ? 0 : vc + 1;
    end
    // taps: every 516..523 clocks
    integer gap = 520, ntap = 0;
    real f1 = 440.0, f2 = 3000.0, amp = 8000.0, ph1 = 0.0, ph2 = 0.0, s;
    always @(negedge clk) begin
        tap = 0;
        gap = gap - 1;
        if (gap == 0) begin
            gap = 516 + ($random(seed) & 7);
            tap = 1;
            ntap = ntap + 1;
            if (($random(seed) & 2047) == 0) begin
                f1 = 40.0 * $pow(400.0, ($random(seed) & 1023) / 1023.0);
                f2 = 40.0 * $pow(400.0, ($random(seed) & 1023) / 1023.0);
                case ($random(seed) & 7)
                    0: amp = 0.0; 1: amp = 150.0; 2: amp = 60000.0;   // silence, very quiet, clipped
                    3: amp = 32767.0;
                    default: amp = 300.0 + ($random(seed) & 16383);
                endcase
            end
            ph1 = ph1 + 2.0 * 3.14159265358979 * f1 / 48000.0;
            ph2 = ph2 + 2.0 * 3.14159265358979 * f2 / 48000.0;
            if (ph1 > 6.283185307179586) ph1 = ph1 - 6.283185307179586;
            if (ph2 > 6.283185307179586) ph2 = ph2 - 6.283185307179586;
            s = amp * (0.6 * $sin(ph1) + 0.4 * $sin(ph2)) + (($random(seed) % 64));
            sample = s > 32767.0 ? 16'sh7fff : s < -32768.0 ? 16'sh8000 : $rtoi(s);
        end
    end
    initial begin
        fd = $fopen("spectrum.log", "w");
        repeat (7) @(negedge clk); rst_n = 1;
        for (frame = 0; frame < FRAMES; frame = frame + 1) begin
            while (!(vc == 2 && hc == 0)) @(negedge clk);
            dump = (frame % 3) == 2 || frame > FRAMES - 6 || frame == 21;
            if (dump) $fdisplay(fd, "D %0d", frame);
            while (!(vc == 0 && hc == 5)) @(negedge clk);
            dump = 0;
            show = !((frame >= 19 && frame < 22) || ($random(seed) & 15) == 0);
            // enable low for single frames now and then and for frames 30..31 (music stopped)
            enable = !(($random(seed) & 15) == 0 || frame == 30 || frame == 31);
        end
        $fclose(fd);
        $display("PASS SPECTRUM_DUMP taps %0d", ntap);
        $finish;
    end
endmodule
