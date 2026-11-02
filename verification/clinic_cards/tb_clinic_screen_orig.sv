`timescale 1ns/1ps
// Full-frame bench for clinic_screen with the production video timing generator.
// Each frame's status comes from frames.txt; in the middle of the frame the bench drives
// "noise" values, so a missing frame latch shows up as a pixel mismatch. Every active pixel
// of every frame is dumped for the independent Python model in run_clinic_tests.py.
module tb;
    parameter integer MAX_FRAMES=36,ANIMATE=0;
    reg clk = 0, rst = 1;
    always #20 clk = ~clk;
    wire hs, vs, de;
    wire [11:0] video_x, video_y;
    video_timing_ctrl #(.H_ACT(640), .V_ACT(480), .ACTIVE_LAST(1)) timing(
        .pclk(clk), .rst_n(~rst), .hsync(hs), .vsync(vs), .de(de), .x(video_x), .y(video_y));
    wire [11:0] ax = video_x - 12'd160;
    wire [11:0] pixel_y = video_y - 12'd45;
    wire [23:0] in_rgb = {ax[7:0] ^ 8'h5a, pixel_y[7:0], ax[9:2] + pixel_y[8:1]};
    reg vs_q = 1;
    always @(posedge clk) vs_q <= vs;
    wire frame_start = vs_q && !vs;

    reg [4:0] call_number = 0, issued_number = 0, waiting_count = 0;
    reg [2:0] last_card = 0;
    reg last_card_valid = 0;
    reg [1:0] help_state = 0;
    reg link_up = 1;
    reg alarm_on = 0;
    reg [1:0] op_code = 0;
    reg [2:0] op_state = 0;
    wire out_de;
    wire [23:0] out_rgb;
    clinic_screen #(.ANIMATE(ANIMATE)) dut(
        .clk(clk), .rst(rst), .frame_start(frame_start), .in_de(de), .in_rgb(in_rgb),
        .video_x(video_x), .pixel_y(pixel_y), .call_number(call_number),
        .issued_number(issued_number), .waiting_count(waiting_count),
        .last_card(last_card), .last_card_valid(last_card_valid), .help_state(help_state),
        .link_up(link_up), .op_code(op_code), .op_state(op_state),
        .alarm_on(alarm_on), .out_de(out_de), .out_rgb(out_rgb));

    integer fd, vf, frames = 0, n, f;
    integer v_call, v_iss, v_wait, v_last, v_lvalid, v_help, v_up, v_alarm, v_op, v_ops;
    always @(posedge clk) if (!rst) begin
        if (out_de !== de) $fatal(1, "DE not passed through");
        if (!de && out_rgb !== in_rgb) $fatal(1, "blanking RGB changed");
        if (de && frames >= 1) $fwrite(fd, "%h\n", out_rgb);
    end
    task wait_line(input integer line);
        begin while (!(video_y == line && video_x == 0)) @(negedge clk); end
    endtask
    initial begin
        fd = $fopen("clinic_frames.hex", "w");
        vf = $fopen("frames.txt", "r");
        if (vf == 0) $fatal(1, "missing frames.txt");
        n = 0;
        repeat (4) @(negedge clk); rst = 0;
        f = $fscanf(vf, "%d %d %d %d %d %d %d %d %d %d\n", v_call, v_iss, v_wait, v_last, v_lvalid, v_help, v_up, v_alarm, v_op, v_ops);
        while (f == 10) begin
            call_number = v_call; issued_number = v_iss; waiting_count = v_wait;
            last_card = v_last; last_card_valid = v_lvalid; help_state = v_help;
            link_up = v_up; alarm_on = v_alarm; op_code = v_op; op_state = v_ops;
            @(negedge clk);
            while (!frame_start) @(negedge clk);
            frames = frames + 1;
            @(negedge clk);
            // noise in the middle of the frame must not reach the screen
            wait_line(100 + 45);
            call_number = 5'd20 - v_call[4:0]; issued_number = 5'd19 - v_iss[4:0];
            waiting_count = 5'd7 - v_wait[4:0]; last_card = 3'd5 - v_last[2:0];
            last_card_valid = !v_lvalid; help_state = 2'd2 - v_help[1:0];
            link_up = !v_up; alarm_on = !v_alarm; op_code = 2'd3 - v_op[1:0]; op_state = 3'd5 - v_ops[2:0];
            wait_line(400 + 45);
            f = $fscanf(vf, "%d %d %d %d %d %d %d %d %d %d\n", v_call, v_iss, v_wait, v_last, v_lvalid, v_help, v_up, v_alarm, v_op, v_ops);
        end
        while (!frame_start) @(negedge clk);
        frames = frames + 1;
        $fclose(fd);
        $display("PASS CLINIC_DUMP frames=%0d", frames - 1);
        $finish;
    end
    initial begin #((MAX_FRAMES+3)*16800000); $fatal(1, "watchdog"); end
endmodule


