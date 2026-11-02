`timescale 1ns/1ps
// 10/24 UI v3 hall screen regression bench: hospital_screen over a photo (photo.hex) with the
// production video timing generator. One line of frames.txt per video frame (state applied before
// that frame's start; "noise" values in the middle of the frame check that only frame-latched
// state is drawn):
//   call issued waiting r1 needs help lroom vstatus bri con volmode music voice
//   rej h1 h2 h3 r2 r3 r4 hroom present phy online ready auto err dump sset res rpic clo chi rep tgt
// (10/26 rep = 1: a one-clock replay_pulse before the frame start, like rej)
// (10/28 tgt = volume_target: 0 music / 1 voice, underlined while SW1 (volmode) is up)
// (10/25 multi-room: r1..r4 room current patient, needs = registration needs of the latest call,
// lroom / hroom = room of the latest call / that confirmed help, present = rooms listed)
// sset >= 0: the ticker scroll register is set to this value right after the frame start
// (bench only, so the wrap-around can be tested without hundreds of frames).
// rej != 0: a one-clock reject pulse before the frame start, on bit (rej-1) of reject_invalid
// (1..8), reject_duplicate (9..16), reject_full (17..24) or reject_conflict (25..32).
// 10/26: res = SW4 resolution line; rpic = picture on screen; {chi, clo} = its 60 digit-cell bits
// (in the board they come from a block RAM read with the frame-latched picture number, so they
// are frame-stable inputs and get no mid-frame noise here; res itself is latched by the screen).
// Frames with dump=1 are written to frames.hex.
module tb;
    parameter integer MAX_FRAMES = 100, ADJ = 6;
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
    wire [23:0] in_rgb = de ? photo[py * 640 + ax] : {video_x[7:0], video_y[7:0], 8'h5a};
    reg vs_q = 1;
    always @(posedge clk) vs_q <= vs;
    wire frame_start = vs_q && !vs;

    reg [4:0] call_number = 0, issued_number = 0, waiting_count = 0, h1 = 0, h2 = 0, h3 = 0;
    reg [4:0] r1 = 0, r2 = 0, r3 = 0, r4 = 0;
    reg [2:0] voice_status = 0;
    reg volume_mode = 0, phy = 0, online = 0, ready = 0, auto_en = 0;
    reg [1:0] help_state = 0, bri = 0, con = 0, lroom = 0, hroom = 0;
    reg [3:0] music = 2, voice = 10, err = 0, needs = 0, present = 4'b0011;
    reg [7:0] rinv = 0, rdup = 0, rfull = 0, rconf = 0;
    reg res_show = 0, replay = 0, vtarget = 0;
    reg [1:0] res_pic = 0;
    reg [59:0] res_cells = 0;
    wire out_de; wire [23:0] out_rgb;
    hospital_screen #(.ADJUST_FRAMES(ADJ), .PROMPT_FRAMES(ADJ)) dut(.clk(clk), .rst(rst), .frame_start(frame_start), .in_de(de), .in_rgb(in_rgb),
        .video_x(video_x), .pixel_y(py), .call_number(call_number), .issued_number(issued_number),
        .waiting_count(waiting_count), .help_state(help_state), .voice_status(voice_status),
        .brightness_idx(bri), .contrast_idx(con), .volume_mode(volume_mode), .volume_target(vtarget), .music_level(music), .voice_level(voice),
        .reject_invalid(rinv), .reject_duplicate(rdup), .reject_full(rfull), .reject_conflict(rconf),
        .history1(h1), .history2(h2), .history3(h3),
        .room_numbers({r4, r3, r2, r1}), .last_room(lroom), .help_room(hroom), .call_needs(needs),
        .replay_pulse(replay), .rooms_present(present),
        .phy_connected(phy), .clinic_online(online), .media_ready(ready), .auto_enabled(auto_en), .media_error(err),
        .res_show(res_show), .res_pic(res_pic), .res_cells(res_cells),
        .out_de(out_de), .out_rgb(out_rgb));

    integer fd, vf, f, frames = 0, dump_this = 0;
    integer v [0:34];
    always @(posedge clk) if (!rst) begin
        if (out_de !== de) $fatal(1, "DE not passed through");
        if (!de && out_rgb !== in_rgb) $fatal(1, "blanking RGB changed");
        if (de && ^out_rgb === 1'bx) $fatal(1, "X in picture, frame %0d x=%0d y=%0d", frames, ax, py);
        if (de && dump_this) $fwrite(fd, "%h\n", out_rgb);
    end
    task wait_line(input integer line);
        begin while (!(video_y == line && video_x == 0)) @(negedge clk); end
    endtask
    task read_line;
        begin
            f = $fscanf(vf, "%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d\n",
                        v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7], v[8], v[9], v[10], v[11], v[12], v[13], v[14],
                        v[15], v[16], v[17], v[18], v[19], v[20], v[21], v[22], v[23], v[24], v[25], v[26], v[27], v[28],
                        v[29], v[30], v[31], v[32], v[33], v[34]);
        end
    endtask
    task apply(input integer noise);
        begin
            if (!noise) begin
                call_number = v[0]; issued_number = v[1]; waiting_count = v[2]; r1 = v[3]; needs = v[4];
                help_state = v[5]; lroom = v[6]; voice_status = v[7]; bri = v[8]; con = v[9]; volume_mode = v[10];
                music = v[11]; voice = v[12]; h1 = v[14]; h2 = v[15]; h3 = v[16]; r2 = v[17]; r3 = v[18];
                r4 = v[19]; hroom = v[20]; present = v[21]; phy = v[22]; online = v[23]; ready = v[24];
                auto_en = v[25]; err = v[26];
                vtarget = v[34];
                res_show = v[29]; res_pic = v[30]; res_cells = {v[32][29:0], v[31][29:0]};
            end else begin
                call_number = 5'd17 - v[0]; issued_number = 5'd3 + v[1]; waiting_count = 5'd9 - v[2];
                r1 = 5'd15 - v[3]; needs = ~v[4]; help_state = 2'd2 - v[5]; lroom = 2'd3 - v[6];
                voice_status = 3'd6 - v[7]; h1 = 5'd19 - v[14]; present = ~v[21]; phy = !v[22]; online = !v[23];
                ready = !v[24]; err = 4'd12 - v[26]; hroom = 2'd3 - v[20]; r2 = 5'd11 - v[17];
                res_show = !v[29];
                // settings are not "noise": they are only compared at the frame start (adjust timer)
            end
        end
    endtask
    initial begin
        fd = $fopen("frames.hex", "w");
        vf = $fopen("frames.txt", "r");
        if (vf == 0) $fatal(1, "missing frames.txt");
        repeat (4) @(negedge clk); rst = 0;
        read_line;
        while (f == 35) begin
            apply(0);
            @(negedge clk);
            while (!(video_y == 2 && video_x == 0)) @(negedge clk);   // before the vsync falling edge
            if (v[13] != 0) begin
                case ((v[13] - 1) / 8)
                    0: rinv[(v[13] - 1) % 8] = 1'b1; 1: rdup[(v[13] - 1) % 8] = 1'b1;
                    2: rfull[(v[13] - 1) % 8] = 1'b1; default: rconf[(v[13] - 1) % 8] = 1'b1;
                endcase
                @(negedge clk); rinv = 0; rdup = 0; rfull = 0; rconf = 0;
            end
            if (v[33] != 0) begin replay = 1; @(negedge clk); replay = 0; end
            while (!frame_start) @(negedge clk);
            frames = frames + 1;
            @(negedge clk);
            if (v[28] >= 0) dut.scroll = v[28];
            wait_line(45);
            dump_this = v[27];
            wait_line(45 + 200);
            apply(1);
            wait_line(0);
            dump_this = 0;
            read_line;
        end
        $fclose(fd);
        $display("PASS HALL_SCREEN_DUMP frames=%0d", frames);
        $finish;
    end
    // 64-bit: (MAX_FRAMES + 3) * 16.8 ms overflows 32 bits above 252 frames (10/26)
    initial begin #((MAX_FRAMES + 64'd3) * 64'd16800000); $fatal(1, "watchdog"); end
endmodule
