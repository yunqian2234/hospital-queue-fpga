`timescale 1ns/1ps
// 10/22 diagnosis: feed a real BMP file byte by byte (as the FAT32 streamer does) through
// bmp_stream_decode + bmp_scaler at the hall board's real 640x480 output, with random
// back-pressure. Prints the decoder result and writes every output pixel to +OUT.
module tb_real_bmp;
    reg clk = 0, rst = 1, start = 0;
    always #5 clk = ~clk;
    reg [7:0] mem [0:8*1024*1024-1];
    integer size, fd, i, out_fd, npix = 0, cycles = 0;
    string in_name, out_name;
    reg fv = 0; reg [7:0] fdata = 0; reg fdone = 0;
    wire fready, busy, done, failed, write_req, dvalid, dready, ovalid, sdone, sfailed, sbusy;
    wire [3:0] err; wire [23:0] ddata, orgb; wire [10:0] w, h;
    reg oready = 0, cfg_sent = 0;
    bmp_stream_decode #(.USE_PIXEL_READY(1)) u_dec(
        .clk(clk), .rst(rst), .start(start), .abort(1'b0), .directory_size(size),
        .bmp_width(16'd640), .bmp_height(16'd480), .file_valid(fv), .file_data(fdata), .file_ready(fready),
        .file_done(fdone), .file_failed(1'b0), .busy(busy), .done(done), .failed(failed), .error_code(err),
        .write_req(write_req), .write_ack(1'b1), .pixel_valid(dvalid), .pixel_data(ddata), .pixel_ready(dready),
        .src_w(w), .src_h(h));
    always @(posedge clk) if (start) cfg_sent <= 0; else if (write_req) cfg_sent <= 1;
    bmp_scaler #(.OUT_W(640), .OUT_H(480)) u_sc(
        .clk(clk), .rst(rst), .start(start), .abort(failed), .cfg_valid(write_req && !cfg_sent),
        .src_w(w), .src_h(h), .in_valid(dvalid), .in_rgb(ddata), .in_ready(dready), .src_done(done),
        .out_valid(ovalid), .out_rgb(orgb), .out_ready(oready), .done(sdone), .failed(sfailed), .busy(sbusy),
        .fit_w(), .fit_h(), .box_k());
    always @(posedge clk) begin
        oready <= $urandom_range(0, 3) != 0;
        if (ovalid && oready) begin npix = npix + 1; $fwrite(out_fd, "%06x\n", orgb); end
    end
    initial begin
        if (!$value$plusargs("IN=%s", in_name)) $fatal(1, "IN");
        if (!$value$plusargs("OUT=%s", out_name)) $fatal(1, "OUT");
        fd = $fopen(in_name, "rb"); size = $fread(mem, fd); $fclose(fd);
        out_fd = $fopen(out_name, "w");
        $display("file %0s bytes %0d", in_name, size);
        repeat (5) @(negedge clk); rst = 0; repeat (5) @(negedge clk);
        start = 1; @(negedge clk); start = 0;
        for (i = 0; i < size; i = i + 1) begin
            fv = 1; fdata = mem[i];
            @(posedge clk); while (!fready) @(posedge clk);
            #1 fv = 0;
            if ($urandom_range(0, 1)) @(negedge clk);
            if (failed) i = size;
        end
        @(negedge clk); fdone = 1; @(negedge clk); fdone = 0;
        while (!sdone && !sfailed && !failed && cycles < 2000000) begin @(posedge clk); cycles = cycles + 1; end
        $display("RESULT w=%0d h=%0d dec_failed=%0d err=%0d scaler_done=%0d scaler_failed=%0d pixels=%0d busy=%0d",
                 w, h, failed, err, sdone, sfailed, npix, sbusy);
        $fclose(out_fd);
        $finish;
    end
endmodule
