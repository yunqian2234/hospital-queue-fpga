`timescale 1ns/1ps
// bmp_scaler bench: one source image per run (src.hex, meta.hex written by run_scale_tests.py).
// The source is streamed bottom-up, left to right as bmp_stream_decode delivers it, with random
// gaps; the sink applies random backpressure. Every output pixel is written to out.hex for the
// runner's independent model. +define+ABORT_FIRST: a first load is aborted part-way, then the
// image is loaded again from the start (the second load must be complete and correct).
module tb;
    parameter integer OUT_W = 640;
    parameter integer OUT_H = 480;
    parameter integer SEED = 1;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;                                // 100 MHz SD clock domain

    reg [31:0] meta [0:3];
    reg [23:0] src [0:2073599];
    integer W, H, NPIX;

    reg start = 0, abort = 0, cfg_valid = 0, in_valid = 0, src_done = 0, out_ready = 0;
    reg [10:0] src_w = 0, src_h = 0;
    reg [23:0] in_rgb = 0;
    wire in_ready, out_valid, done, failed, busy;
    wire [23:0] out_rgb;
    wire [10:0] fit_w, fit_h;
    wire [1:0] box_k;
    bmp_scaler #(.OUT_W(OUT_W), .OUT_H(OUT_H), .DONE_TIMEOUT(400000)) dut(
        .clk(clk), .rst(rst), .start(start), .abort(abort), .cfg_valid(cfg_valid),
        .src_w(src_w), .src_h(src_h), .in_valid(in_valid), .in_rgb(in_rgb), .in_ready(in_ready),
        .src_done(src_done), .out_valid(out_valid), .out_rgb(out_rgb), .out_ready(out_ready),
        .done(done), .failed(failed), .busy(busy), .fit_w(fit_w), .fit_h(fit_h), .box_k(box_k));

    integer fd, nout = 0, ndone = 0, seed, p, gap;
    reg capture = 0;
    always @(posedge clk) begin
        out_ready <= ($random(seed) & 3) != 0;          // ~75 % ready
        if (out_valid && out_ready && capture) begin
            $fwrite(fd, "%06h\n", out_rgb);
            nout = nout + 1;
        end
        if (done) ndone = ndone + 1;
        if (failed) $fatal(1, "scaler reported failed");
    end

    task load(input integer npix_to_send);
        begin
            @(negedge clk); start = 1; @(negedge clk); start = 0;
            repeat (3 + ($random(seed) & 7)) @(negedge clk);
            src_w = W; src_h = H; cfg_valid = 1; @(negedge clk); cfg_valid = 0;
            p = 0;
            while (p < npix_to_send) begin
                gap = $random(seed) & 3;
                repeat (gap) @(negedge clk);
                in_valid = 1; in_rgb = src[p];
                @(posedge clk); while (!in_ready) @(posedge clk);
                @(negedge clk); in_valid = 0; p = p + 1;
            end
        end
    endtask

    initial begin
        if (!$value$plusargs("SEED=%d", seed)) seed = SEED;
        $readmemh("meta.hex", meta);
        W = meta[0]; H = meta[1]; NPIX = W * H;
        $readmemh("src.hex", src);
        fd = $fopen("out.hex", "w");
        #50 rst = 0;
`ifdef ABORT_FIRST
        load(NPIX / 3);
        repeat (200) @(negedge clk);
        abort = 1; @(negedge clk); abort = 0;
        repeat (50) @(negedge clk);
        if (busy) $fatal(1, "still busy after abort");
`endif
        capture = 1;
        load(NPIX);
        repeat ($random(seed) & 15) @(negedge clk);
        src_done = 1; @(negedge clk); src_done = 0;
        while (ndone == 0) @(negedge clk);
        repeat (100) @(negedge clk);
        $fclose(fd);
        if (nout != OUT_W * OUT_H) $fatal(1, "%0d output pixels, expected %0d", nout, OUT_W * OUT_H);
        if (ndone != 1) $fatal(1, "done pulsed %0d times", ndone);
        if (busy) $fatal(1, "busy after done");
        $display("FIT %0d %0d %0d", fit_w, fit_h, box_k);
        $display("PASS SCALER %0dx%0d -> %0d outputs", W, H, nout);
        $finish;
    end
    initial begin #400_000_000; $fatal(1, "watchdog"); end
endmodule
