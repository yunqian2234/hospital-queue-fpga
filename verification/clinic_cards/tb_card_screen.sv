`timescale 1ns/1ps
// 10/23 full-frame bench: clinic_screen + clinic_card_view + clinic_card_store (behavioural RAM,
// preloaded from pix.mem / pal.mem) with the production video timing generator. One line of
// frames.txt per video frame: call issued waiting last last_valid help link alarm op op_state dump.
// Status inputs change before each frame start and get "noise" in the middle of the frame (both
// layers must only use frame-latched values). Frames with dump=1 are written to frames.hex.
//   +READY=<6-bit mask>  cards whose pictures are loaded
module tb;
    parameter integer MAX_FRAMES = 100, HOLD_FRAMES = 4;
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
    reg link_up = 1, alarm_on = 0;
    reg [1:0] op_code = 0;
    reg [2:0] op_state = 0;
    reg [5:0] card_ready = 0;
    wire osd_de, zoom_panel, zoom_active;
    wire [2:0] zoom_card;
    wire [23:0] osd_rgb, out_rgb;
    wire [15:0] pix_ra, pix_rb;
    wire [7:0] pix_qa, pix_qb;
    wire [10:0] pal_ra, pal_rb;
    wire [23:0] pal_qa, pal_qb;
    clinic_screen #(.ANIMATE(0)) dut(
        .clk(clk), .rst(rst), .frame_start(frame_start), .in_de(de), .in_rgb(in_rgb),
        .video_x(video_x), .pixel_y(pixel_y), .call_number(call_number),
        .issued_number(issued_number), .waiting_count(waiting_count),
        .last_card(last_card), .last_card_valid(last_card_valid), .help_state(help_state),
        .link_up(link_up), .op_code(op_code), .op_state(op_state), .alarm_on(alarm_on),
        .zoom_panel(zoom_panel), .zoom_card(zoom_card), .out_de(osd_de), .out_rgb(osd_rgb));
    clinic_card_view #(.HOLD_FRAMES(HOLD_FRAMES)) view(
        .clk(clk), .rst(rst), .frame_start(frame_start), .video_x(video_x), .pixel_y(pixel_y),
        .de(osd_de), .in_rgb(osd_rgb), .out_rgb(out_rgb),
        .link_up(link_up), .last_card(last_card), .last_card_valid(last_card_valid), .help_state(help_state),
        .card_clicks(8'd0), .card_ready(card_ready), .store_busy(1'b0),
        .pix_ra(pix_ra), .pix_rb(pix_rb), .pix_qa(pix_qa), .pix_qb(pix_qb),
        .pal_ra(pal_ra), .pal_rb(pal_rb), .pal_qa(pal_qa), .pal_qb(pal_qb),
        .zoom_panel(zoom_panel), .zoom_card(zoom_card), .zoom_active(zoom_active));
    clinic_card_store store(
        .clk(clk), .sel_loader(1'b0), .pix_we(1'b0), .pix_waddr(16'd0), .pix_wdata(8'd0),
        .pal_we(1'b0), .pal_waddr(11'd0), .pal_wdata(24'd0),
        .pix_ra(pix_ra), .pix_rb(pix_rb), .pix_qa(pix_qa), .pix_qb(pix_qb),
        .pal_ra(pal_ra), .pal_rb(pal_rb), .pal_qa(pal_qa), .pal_qb(pal_qb));

    integer fd, vf, sf, frames = 0, f, dump_this = 0;
    integer v_call, v_iss, v_wait, v_last, v_lvalid, v_help, v_up, v_alarm, v_op, v_ops, v_dump;
    always @(posedge clk) if (!rst) begin
        if (osd_de !== de) $fatal(1, "DE not passed through");
        if (!de && out_rgb !== in_rgb) $fatal(1, "blanking RGB changed");
        if (de && ^out_rgb === 1'bx) $fatal(1, "X in picture, frame %0d x=%0d y=%0d", frames, ax, pixel_y);
        if (de && dump_this) $fwrite(fd, "%h\n", out_rgb);
    end
    task wait_line(input integer line);
        begin while (!(video_y == line && video_x == 0)) @(negedge clk); end
    endtask
    initial begin
        $readmemh("pix.mem", store.pix);
        $readmemh("pal.mem", store.pal);
        if (!$value$plusargs("READY=%b", card_ready)) $fatal(1, "READY");
        fd = $fopen("frames.hex", "w");
        sf = $fopen("states.txt", "w");
        vf = $fopen("frames.txt", "r");
        if (vf == 0) $fatal(1, "missing frames.txt");
        repeat (4) @(negedge clk); rst = 0;
        f = $fscanf(vf, "%d %d %d %d %d %d %d %d %d %d %d\n", v_call, v_iss, v_wait, v_last, v_lvalid, v_help,
                    v_up, v_alarm, v_op, v_ops, v_dump);
        while (f == 11) begin
            call_number = v_call; issued_number = v_iss; waiting_count = v_wait;
            last_card = v_last; last_card_valid = v_lvalid; help_state = v_help;
            link_up = v_up; alarm_on = v_alarm; op_code = v_op; op_state = v_ops;
            @(negedge clk);
            while (!frame_start) @(negedge clk);
            frames = frames + 1;
            @(negedge clk);
            // the frame now being displayed: state for the Python model cross-check
            repeat (4) @(negedge clk);
            $fwrite(sf, "%0d %0d %0d %0d %0d\n", view.st, view.k, view.zoom_card, view.zoom_on, view.img_ok);
            wait_line(45);
            dump_this = v_dump;
            wait_line(100 + 45);
            call_number = 5'd20 - v_call[4:0]; issued_number = 5'd19 - v_iss[4:0];
            waiting_count = 5'd7 - v_wait[4:0]; last_card = 3'd5 - v_last[2:0];
            last_card_valid = !v_lvalid; help_state = 2'd2 - v_help[1:0];
            link_up = !v_up; alarm_on = !v_alarm; op_code = 2'd3 - v_op[1:0]; op_state = 3'd5 - v_ops[2:0];
            wait_line(0);                  // after the last active line (y 524) of this frame
            dump_this = 0;
            f = $fscanf(vf, "%d %d %d %d %d %d %d %d %d %d %d\n", v_call, v_iss, v_wait, v_last, v_lvalid, v_help,
                        v_up, v_alarm, v_op, v_ops, v_dump);
        end
        $fclose(fd); $fclose(sf);
        $display("PASS CARD_SCREEN_DUMP frames=%0d", frames);
        $finish;
    end
    initial begin #((MAX_FRAMES + 3) * 16800000); $fatal(1, "watchdog"); end
endmodule
