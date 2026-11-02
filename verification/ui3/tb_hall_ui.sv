`timescale 1ns/1ps
// Quick look: the v3 hall screen over a photo (photo.hex, 640x480 RGB) for N frames; dumps the
// last frame to frame.hex.
module tb;
    parameter integer FRAMES = 3;
    reg clk = 0, rst = 1;
    always #20 clk = ~clk;
    wire hs, vs, de;
    wire [11:0] video_x, video_y;
    video_timing_ctrl #(.H_ACT(640), .V_ACT(480), .ACTIVE_LAST(1)) timing(
        .pclk(clk), .rst_n(~rst), .hsync(hs), .vsync(vs), .de(de), .x(video_x), .y(video_y));
    wire [11:0] ax = video_x - 12'd160;
    wire [11:0] py = video_y - 12'd45;
    reg [23:0] photo [0:640*480-1];
    initial $readmemh("photo.hex", photo);
    wire [23:0] in_rgb = de ? photo[py * 640 + ax] : 24'h0;
    reg vs_q = 1;
    always @(posedge clk) vs_q <= vs;
    wire frame_start = vs_q && !vs;
    wire out_de; wire [23:0] out_rgb;
    hospital_screen dut(.clk(clk), .rst(rst), .frame_start(frame_start), .in_de(de), .in_rgb(in_rgb),
        .video_x(video_x), .pixel_y(py), .call_number(5'd6), .issued_number(5'd20), .waiting_count(5'd14),
        .help_state(2'd2), .voice_status(3'd0),
        .brightness_idx(2'd0), .contrast_idx(2'd0), .volume_mode(1'b0), .music_level(4'd2), .voice_level(4'd10),
        .reject_invalid(8'd0), .reject_duplicate(8'd0), .reject_full(8'd0), .reject_conflict(8'd0),
        .history1(5'd5), .history2(5'd4), .history3(5'd3),
        .room_numbers({5'd0, 5'd0, 5'd5, 5'd6}), .last_room(2'd1), .help_room(2'd0), .call_needs(4'd0), .rooms_present(4'b0011),
        .phy_connected(1'b1), .clinic_online(1'b1), .media_ready(1'b1), .auto_enabled(1'b1), .media_error(4'd0),
        .out_de(out_de), .out_rgb(out_rgb));
    integer fd, frames = 0;
    always @(posedge clk) if (frame_start) frames <= frames + 1;
    always @(posedge clk) if (de && frames == FRAMES) $fwrite(fd, "%h\n", out_rgb);
    initial begin
        fd = $fopen("frame.hex", "w");
        repeat (4) @(negedge clk); rst = 0;
        wait (frames == FRAMES + 1);
        $fclose(fd); $display("DONE"); $finish;
    end
endmodule
