`timescale 1ns/1ps
// 10/25 clinic screen bench (ENT multi-room): clinic_screen + clinic_card_view (SHOW_GRID 0,
// HELP_CARD 4, title strip) + clinic_card_store (behavioural RAM from pix.mem / pal.mem) with the
// production video timing. One line of frames.txt per video frame (applied before its start):
//   dual call issued waiting help hroom link alarm aroom an bn arec brec arok brok aop aops bop bops
//   zcard zvalid zclicks zroom znum zidx ztot dump   (10/30: zidx / ztot = "需求 i/n")
// (records in decimal). Frames with dump=1 go to frames.hex; the view state per frame goes to
// states.txt (st k zoom_card).  +READY=<6-bit mask> = cards with pictures.
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

    reg dual = 1, link = 1, alarm = 0, arok = 0, brok = 0, zvalid = 0;
    reg [4:0] call = 0, issued = 0, waiting = 0, an = 0, bn = 0, znum = 0;
    reg [1:0] help = 0, hroom = 0, aroom = 0, aop = 0, bop = 0, zroom = 0;
    reg [2:0] aops = 0, bops = 0, zcard = 0, zidx = 0, ztot = 0;
    reg [11:0] arec = 12'h0FF, brec = 12'h0FF;
    reg [7:0] zclicks = 0;
    reg [5:0] card_ready = 0;
    wire osd_de, zoom_panel, zoom_active;
    wire [2:0] zoom_card;
    wire [23:0] osd_rgb, out_rgb;
    wire [15:0] pix_ra, pix_rb;
    wire [7:0] pix_qa, pix_qb;
    wire [10:0] pal_ra, pal_rb;
    wire [23:0] pal_qa, pal_qb;
    clinic_screen dut(
        .clk(clk), .rst(rst), .frame_start(frame_start), .in_de(de), .in_rgb(in_rgb),
        .video_x(video_x), .pixel_y(pixel_y), .dual(dual), .call_number(call), .issued_number(issued),
        .waiting_count(waiting), .help_state(help), .help_room(hroom), .link_up(link), .alarm_on(alarm),
        .a_room(aroom), .b_room(2'd1), .a_number(an), .b_number(bn), .a_record(arec), .b_record(brec),
        .a_record_ok(arok), .b_record_ok(brok), .a_op(aop), .b_op(bop), .a_ops(aops), .b_ops(bops),
        .zoom_active(zoom_active), .zoom_panel(zoom_panel), .zoom_card(zoom_card),
        .zoom_help(zoom_card == 3'd4), .zoom_room(zroom), .zoom_number(znum),
        .zoom_idx(zidx), .zoom_total(ztot),
        .out_de(osd_de), .out_rgb(osd_rgb));
    clinic_card_view #(.HOLD_FRAMES(HOLD_FRAMES), .SHOW_GRID(0), .HELP_CARD(4), .KEEP_Y0(382), .KEEP_Y1(416)) view(
        .clk(clk), .rst(rst), .frame_start(frame_start), .video_x(video_x), .pixel_y(pixel_y),
        .de(osd_de), .in_rgb(osd_rgb), .out_rgb(out_rgb),
        .link_up(link), .last_card(zcard), .last_card_valid(zvalid), .help_state(help),
        .card_clicks(zclicks), .card_ready(card_ready), .store_busy(1'b0),
        .pix_ra(pix_ra), .pix_rb(pix_rb), .pix_qa(pix_qa), .pix_qb(pix_qb),
        .pal_ra(pal_ra), .pal_rb(pal_rb), .pal_qa(pal_qa), .pal_qb(pal_qb),
        .zoom_panel(zoom_panel), .zoom_card(zoom_card), .zoom_active(zoom_active));
    clinic_card_store store(
        .clk(clk), .sel_loader(1'b0), .pix_we(1'b0), .pix_waddr(16'd0), .pix_wdata(8'd0),
        .pal_we(1'b0), .pal_waddr(11'd0), .pal_wdata(24'd0),
        .pix_ra(pix_ra), .pix_rb(pix_rb), .pix_qa(pix_qa), .pix_qb(pix_qb),
        .pal_ra(pal_ra), .pal_rb(pal_rb), .pal_qa(pal_qa), .pal_qb(pal_qb));

    integer fd, vf, sf, frames = 0, f, dump_this = 0;
    integer v [0:26];
    always @(posedge clk) if (!rst) begin
        if (osd_de !== de) $fatal(1, "DE not passed through");
        if (de && ^out_rgb === 1'bx) $fatal(1, "X in picture, frame %0d x=%0d y=%0d", frames, ax, pixel_y);
        if (de && dump_this) $fwrite(fd, "%h\n", out_rgb);
    end
    task wait_line(input integer line);
        begin while (!(video_y == line && video_x == 0)) @(negedge clk); end
    endtask
    task read_line;
        f = $fscanf(vf, "%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d\n",
                    v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7], v[8], v[9], v[10], v[11], v[12],
                    v[13], v[14], v[15], v[16], v[17], v[18], v[19], v[20], v[21], v[22], v[23], v[24], v[25], v[26]);
    endtask
    task apply(input integer noise);
        begin
            if (!noise) begin
                dual = v[0]; call = v[1]; issued = v[2]; waiting = v[3]; help = v[4]; hroom = v[5]; link = v[6];
                alarm = v[7]; aroom = v[8]; an = v[9]; bn = v[10]; arec = v[11]; brec = v[12]; arok = v[13];
                brok = v[14]; aop = v[15]; aops = v[16]; bop = v[17]; bops = v[18]; zcard = v[19];
                zvalid = v[20]; zclicks = v[21]; zroom = v[22]; znum = v[23]; zidx = v[24]; ztot = v[25];
            end else begin
                // mid-frame noise on everything the screen latches (not the zoom trigger inputs)
                dual = !v[0]; call = 5'd17 - v[1]; issued = 5'd3 + v[2]; waiting = 5'd9 - v[3]; help = 2'd2 - v[4];
                hroom = 2'd3 - v[5]; link = !v[6]; alarm = !v[7]; aroom = 2'd3 - v[8]; an = 5'd19 - v[9];
                bn = 5'd18 - v[10]; arec = ~v[11]; brec = ~v[12]; arok = !v[13]; brok = !v[14];
                aop = 2'd3 - v[15]; aops = 3'd5 - v[16]; bop = 2'd3 - v[17]; bops = 3'd5 - v[18];
                zroom = 2'd3 - v[22]; znum = 5'd20 - v[23]; zidx = 3'd7 - v[24]; ztot = 3'd7 - v[25];
            end
        end
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
        read_line;
        while (f == 27) begin
            apply(0);
            @(negedge clk);
            while (!frame_start) @(negedge clk);
            frames = frames + 1;
            repeat (5) @(negedge clk);
            $fwrite(sf, "%0d %0d %0d\n", view.st, view.k, view.zoom_card);
            wait_line(45);
            dump_this = v[26];
            wait_line(100 + 45);
            apply(1);
            wait_line(0);
            dump_this = 0;
            read_line;
        end
        $fclose(fd); $fclose(sf);
        $display("PASS CLINIC_UI_DUMP frames=%0d", frames);
        $finish;
    end
    initial begin #((MAX_FRAMES + 3) * 16800000); $fatal(1, "watchdog"); end
endmodule
