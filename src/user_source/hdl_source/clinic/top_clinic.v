`timescale 1ns/1ps
// Clinic board (slave) top level for the hospital terminal, V7-3.
//
// This board owns no business state: the hall board decides numbers, queues and help state;
// this board shows them and forwards the doctor's three buttons. It has no TF card, no
// SDRAM and no picture playback, so the picture is a static test pattern behind the status
// overlay, which is all the clinic screen needs.
//
//   board buttons (active low)   KEY2 (B2) = key1 = 叫下一位 (call next)
//                                KEY3 (B1) = key2 = 重播当前号 (replay)
//                                KEY4 (C1) = key3 = 确认求助 (confirm help)
//                                KEY1 (A2) = rst_n = reset
//   link, LINK_ETH=1 (V8)        board Ethernet port, network cable to the hall board
//   link, LINK_ETH=0 (V7)        J2 pin1/pin2 + GND: link_tx -> hall link_rx, link_rx <- hall link_tx
//   seven-segment display        E1 Ethernet PHY state (4 = 100 Mbps link up, see
//                                eth_phy_ctrl.v), E2 E3 good frames received (hex, wraps),
//                                E4 presses not delivered (hex digit, 10/07)
//                                E5 E6 damaged frames received (hex)
//   buzzer (H11, low = on)       beeps while a help request is pending (SW5 must be down)
//   HDMI out                     clinic_screen over the test pattern, then clinic_card_view
//   TF card (10/23, optional)    CARD1.BMP..CARD6.BMP (120x90, 256 colours) are read at power-up
//                                into on-chip RAM (clinic_card_loader/clinic_card_store) and shown
//                                as two rows of small cards; a card the patient touches on the hall
//                                screen zooms to the centre for 5 s. No card / a missing file: the
//                                card's words are shown instead. Pins as on the hall board.
//
// 10/25 ENT department, multi-room: this board is a DUAL-ROOM terminal for the demo (one board,
// two consulting rooms on one Ethernet port - exactly the frames two separate boards would send):
//   room A = board KEY2/3/4, room B = the external key module on J1 (OUT1 叫下一位, OUT2 重播,
//   OUT3 确认求助; J1-31/32/33, same wiring the hall board used before 10/24)
//   SW4 (C5) down = dual-room (rooms 1 and 2), up = single-room; single-room: SW3 (C6) down =
//   room 1, up = room 2 (column B of the screen then shows the queue; J1 keys are ignored)
// When a room calls a patient whose check-in registration lists communication needs, that need's
// card (CARD1..4.BMP: 听力差 / 说话困难 / 头晕需搀扶 / 需翻译) zooms with "X 诊室 NNN 号" below
// it; a help request from the hall zooms CARD5.BMP (请帮助我, red border).
//
// Everything runs in the video clock domain, the same domain the hall board uses for its
// link, so the two boards' link layers are identical apart from the data they carry.
module top_clinic #(
    parameter integer BLINK_FRAMES = 30,       // alert blink half period, ~0.5 s at 60 Hz
    parameter integer BUZZER_DIV = 12_500_000, // ~0.5 s per buzzer phase at 25 MHz
    parameter integer LINK_ETH = 1,            // V8: 1 = network cable, 0 = J2 wires (V7)
    parameter integer ETH_PHY_LOOPBACK = 0     // one-board self-test, no cable
)(
    input wire clk,
    input wire rst_n,
    input wire key1,            // doctor: call next number
    input wire key2,            // doctor: replay the current number
    input wire key3,            // doctor: confirm the help request
    input wire [2:0] room_b_keys_n, // 10/25: J1 OUT1..3 (room B: call next / replay / confirm help)
    input wire dual_sw,         // 10/25: SW4/C5, down = dual-room terminal
    input wire room_sw,         // 10/25: SW3/C6, single-room mode: down = room 1, up = room 2
    input wire link_rx,
    output wire link_tx,
    output wire eth_txc,
    output wire [3:0] eth_txd,
    output wire eth_tx_ctl,
    input wire eth_rxc,
    input wire [3:0] eth_rxd,
    input wire eth_rx_ctl,
    output wire eth_mdc,
    inout wire eth_mdio,
    output wire [5:0] seg_sel,
    output wire [7:0] seg_data,
    output wire buzzer,
    output wire HDMI_CLK_P,
    output wire HDMI_D2_P,
    output wire HDMI_D1_P,
    output wire HDMI_D0_P,
    output wire HDMI_DDC_SCL,
    inout  wire HDMI_DDC_SDA,
    // 10/23 TF card (SPI mode), same pins as the hall board
    output wire sd_ncs,
    output wire sd_dclk,
    output wire sd_mosi,
    input  wire sd_miso
);
    // ---------------- clocks and resets ----------------
    wire video_clk, hdmi_5x_clk, audio_mclk;
    wire video_pll_lock, audio_pll_lock;
    wire pll_rst, system_arst;
    wire rst_video, rst_audio;

    video_pll u_video_pll(
        .refclk(clk), .clk0_out(video_clk), .clk1_out(hdmi_5x_clk),
        .extlock(video_pll_lock), .reset(pll_rst));
    // Only the 12.288 MHz audio master clock is needed (no SDRAM/TF PLL on this board).
    PLL_HDMI_AUDIO u_audio_pll(
        .refclk(clk), .reset(pll_rst), .extlock(audio_pll_lock),
        .clk0_out(), .clk1_out(), .clk2_out(audio_mclk));
    clock_reset_ctrl u_clock_reset(
        .ref_clk(clk), .ext_rst_n(rst_n),
        .pll_locked({1'b1, video_pll_lock, audio_pll_lock}),
        .pll_rst(pll_rst), .system_arst(system_arst));
    reset_sync u_video_reset(.clk(video_clk), .arst(system_arst), .rst(rst_video));
    reset_sync u_audio_reset(.clk(audio_mclk), .arst(system_arst), .rst(rst_audio));

    // ---------------- video timing ----------------
    wire hs, vs, de;
    wire [11:0] video_x, video_y;
    video_timing_ctrl #(.H_ACT(640), .V_ACT(480), .ACTIVE_LAST(1)) u_timing(
        .pclk(video_clk), .rst_n(~rst_video), .hsync(hs), .vsync(vs), .de(de),
        .x(video_x), .y(video_y));
    reg vs_q;
    always @(posedge video_clk or posedge rst_video)
        if (rst_video) vs_q <= 1'b1; else vs_q <= vs;
    wire frame_start = vs_q && !vs;

    // Static background: a slow colour ramp, readable on any monitor, no frame buffer.
    wire [23:0] bg_rgb = {video_x[9:4], 2'b00, video_y[9:2], 2'b00, video_x[9:3] ^ video_y[9:3]};

    // ---------------- doctor's buttons ----------------
    // The same debouncer the hall board uses, in the video clock domain (the board's
    // reference clock is not needed anywhere else in this design).
    wire [3:0] btn_n = {1'b1, key3, key2, key1};
    wire [3:0] btn_pressed, btn_pulse, btn_release, btn_armed;
    hospital_key_frontend #(.KEY_COUNT(4)) u_keys(
        .clk(video_clk), .rst(rst_video), .key_n(btn_n), .pressed(btn_pressed),
        .press_pulse(btn_pulse), .release_pulse(btn_release), .armed(btn_armed));

    wire [2:0] bkey_pressed, bkey_pulse, bkey_release, bkey_armed;
    hospital_key_frontend #(.KEY_COUNT(3)) u_room_b_keys(
        .clk(video_clk), .rst(rst_video), .key_n(room_b_keys_n), .pressed(bkey_pressed),
        .press_pulse(bkey_pulse), .release_pulse(bkey_release), .armed(bkey_armed));
    reg [1:0] dual_sync, room_sync;
    always @(posedge video_clk or posedge rst_video)
        if (rst_video) begin dual_sync <= 0; room_sync <= 0; end
        else begin dual_sync <= {dual_sync[0], ~dual_sw}; room_sync <= {room_sync[0], room_sw}; end
    wire dual = dual_sync[1];
    wire [1:0] room_a = dual ? 2'd0 : {1'b0, room_sync[1]};
    wire [1:0] room_b = 2'd1;

    // ---------------- link ----------------
    // All wire-facing logic lives in clinic_link, which the two-board bench also runs.
    wire [4:0] call_number, issued_number, waiting_count, a_number, b_number;
    wire [1:0] help_state, help_room, last_room;
    wire [11:0] a_record, b_record;
    wire a_record_ok, b_record_ok, link_up, b_link_up;
    wire [1:0] op_code, b_op_code;
    wire [2:0] op_state, b_op_state;
    wire [15:0] cmd_failures, b_cmd_failures;
    wire b_cmd_busy;
    wire eth_tx_valid, eth_tx_ready, eth_rx_valid;
    wire [7:0] eth_tx_data, eth_rx_data;
    wire a_tx_valid, a_tx_ready, b_tx_valid, b_tx_ready;
    wire [7:0] a_tx_data, b_tx_data;
    wire [3:0] eth_phy_state;
    wire [15:0] eth_frames_ok, eth_frames_bad;
    generate if (LINK_ETH != 0) begin : g_eth
        eth_link #(.MAC_ADDR(48'h02_43_4c_49_4e_02), .LOOPBACK(ETH_PHY_LOOPBACK)) u_eth_link(
            .clk(video_clk), .rst(rst_video), .clk5(hdmi_5x_clk),
            .src_valid(eth_tx_valid), .src_data(eth_tx_data), .src_ready(eth_tx_ready),
            .out_valid(eth_rx_valid), .out_data(eth_rx_data),
            .eth_txc(eth_txc), .eth_txd(eth_txd), .eth_tx_ctl(eth_tx_ctl),
            .eth_rxc(eth_rxc), .eth_rxd(eth_rxd), .eth_rx_ctl(eth_rx_ctl),
            .eth_mdc(eth_mdc), .eth_mdio(eth_mdio),
            .phy_state(eth_phy_state), .phy_addr(), .phy_link_ok(),
            .frames_sent(), .frames_ok(eth_frames_ok), .frames_bad(eth_frames_bad),
            .frames_dropped());
    end else begin : g_no_eth
        assign eth_tx_ready = 1'b0; assign eth_rx_valid = 1'b0; assign eth_rx_data = 8'h00;
        assign eth_phy_state = 4'h0; assign eth_frames_ok = 16'h0000; assign eth_frames_bad = 16'h0000;
        assign eth_txc = 1'b0; assign eth_txd = 4'h0; assign eth_tx_ctl = 1'b0;
        assign eth_mdc = 1'b0; assign eth_mdio = 1'bz;
    end endgenerate
    // room A (board keys) and room B (J1 keys); one Ethernet port, frame-granular arbitration
    clinic_link #(.CLK_HZ(25_000_000), .BAUD(1_000_000), .LINK_TIMEOUT_CYCLES(25_000_000),
                  .RETRY_FRAMES(3), .GIVEUP_FRAMES(120), .ETH(LINK_ETH)) u_link(
        .clk(video_clk), .rst(rst_video), .frame_start(frame_start), .room(room_a),
        .link_rx(link_rx), .link_tx(link_tx),
        .eth_tx_valid(a_tx_valid), .eth_tx_data(a_tx_data), .eth_tx_ready(a_tx_ready),
        .eth_rx_valid(eth_rx_valid), .eth_rx_data(eth_rx_data),
        .btn_call(btn_pulse[0]), .btn_replay(btn_pulse[1]), .btn_help_ack(btn_pulse[2]),
        .call_number(call_number), .my_number(a_number), .issued_number(issued_number),
        .waiting_count(waiting_count), .help_state(help_state), .help_room(help_room), .last_room(last_room),
        .my_record(a_record), .my_record_ok(a_record_ok),
        .link_up(link_up), .op_code(op_code), .op_state(op_state),
        .status_frames(), .presses_accepted(), .presses_ignored(), .cmd_frames(),
        .cmd_retries(), .cmd_failures(cmd_failures));
    clinic_link #(.CLK_HZ(25_000_000), .BAUD(1_000_000), .LINK_TIMEOUT_CYCLES(25_000_000),
                  .RETRY_FRAMES(3), .GIVEUP_FRAMES(120), .ETH(1)) u_link_b(
        .clk(video_clk), .rst(rst_video), .frame_start(frame_start), .room(room_b),
        .link_rx(1'b1), .link_tx(),
        .eth_tx_valid(b_tx_valid), .eth_tx_data(b_tx_data), .eth_tx_ready(b_tx_ready),
        .eth_rx_valid(eth_rx_valid), .eth_rx_data(eth_rx_data),
        .btn_call(dual && bkey_pulse[0]), .btn_replay(dual && bkey_pulse[1]), .btn_help_ack(dual && bkey_pulse[2]),
        .call_number(), .my_number(b_number), .issued_number(), .waiting_count(),
        .help_state(), .help_room(), .last_room(),
        .my_record(b_record), .my_record_ok(b_record_ok),
        .link_up(b_link_up), .op_code(b_op_code), .op_state(b_op_state),
        .status_frames(), .presses_accepted(), .presses_ignored(), .cmd_frames(),
        .cmd_retries(), .cmd_failures(b_cmd_failures), .cmd_busy(b_cmd_busy));
    // single-room mode: room B's endpoint stays silent (no heartbeats either).
    // 10/30: the gate only CLOSES between frames (b_tx_valid low), so switching the mode never cuts
    // a frame short; it may OPEN at any time (while it was closed the mux cannot have started a room
    // B frame, so that frame still begins with its first byte). A room B command already outstanding
    // is still re-sent until it is acknowledged or given up (its result is not lost; room B's key
    // presses are blocked in single-room mode as before).
    reg b_en;
    always @(posedge video_clk or posedge rst_video)
        if (rst_video) b_en <= 1'b0;
        else if (!b_tx_valid || !b_en) b_en <= dual || b_cmd_busy;
    link_tx_mux u_tx_mux(.clk(video_clk), .rst(rst_video),
        .a_valid(a_tx_valid), .a_data(a_tx_data), .a_ready(a_tx_ready),
        .b_valid(b_en && b_tx_valid), .b_data(b_tx_data), .b_ready(b_tx_ready),
        .out_valid(eth_tx_valid), .out_data(eth_tx_data), .out_ready(eth_tx_ready));

    // Frame-latched copies so the picture never mixes two status frames, plus the alert
    // blink (driven locally so it keeps running even if the hall board stops sending).
    reg [1:0] help_q;
    reg link_q;
    reg [7:0] alarm_count;
    reg alarm_on;
    always @(posedge video_clk or posedge rst_video) begin
        if (rst_video) begin
            help_q <= 0; link_q <= 0; alarm_count <= 0; alarm_on <= 0;
        end else if (frame_start) begin
            // With the link down the help alert would be stale: show it only while linked.
            help_q <= link_up ? help_state : 2'd0; link_q <= link_up;
            if (!link_up || help_state != 2'd1) begin alarm_count <= 0; alarm_on <= 1'b0; end
            else if (alarm_count == BLINK_FRAMES - 1) begin alarm_count <= 0; alarm_on <= ~alarm_on; end
            else alarm_count <= alarm_count + 1'b1;
        end
    end

    // ---------------- 10/23 expression cards: TF card -> on-chip store ----------------
    // The SD stack runs in video_clk (25 MHz): SPI 390 kHz while initialising, then 6.25 MHz.
    wire sd_init_done, sd_sec_read, sd_sec_valid, sd_sec_end, sd_reset_req;
    wire [31:0] sd_sec_addr;
    wire [7:0] sd_sec_data;
    reg [5:0] sd_reset_count;
    always @(posedge video_clk or posedge rst_video)
        if (rst_video) sd_reset_count <= 0;
        else if (sd_reset_req) sd_reset_count <= 6'd32;
        else if (sd_reset_count != 0) sd_reset_count <= sd_reset_count - 1'b1;
    sd_card_top #(.SPI_LOW_SPEED_DIV(30), .SPI_HIGH_SPEED_DIV(0)) u_sd(
        .clk(video_clk), .rst(rst_video || sd_reset_count != 0),
        .SD_nCS(sd_ncs), .SD_DCLK(sd_dclk), .SD_MOSI(sd_mosi), .SD_MISO(sd_miso),
        .sd_init_done(sd_init_done), .sd_sec_read(sd_sec_read), .sd_sec_read_addr(sd_sec_addr),
        .sd_sec_read_data(sd_sec_data), .sd_sec_read_data_valid(sd_sec_valid), .sd_sec_read_end(sd_sec_end),
        .sd_sec_write(1'b0), .sd_sec_write_addr(32'd0), .sd_sec_write_data(8'd0),
        .sd_sec_write_data_req(), .sd_sec_write_end());
    wire [5:0] card_ready;
    wire card_loading;
    wire pix_we, pal_we;
    wire [15:0] pix_waddr, pix_ra, pix_rb;
    wire [7:0] pix_wdata, pix_qa, pix_qb;
    wire [10:0] pal_waddr, pal_ra, pal_rb;
    wire [23:0] pal_wdata, pal_qa, pal_qb;
    clinic_card_loader u_cards(
        .clk(video_clk), .rst(rst_video),
        .sd_init_done(sd_init_done), .sd_read(sd_sec_read), .sd_addr(sd_sec_addr),
        .sd_data(sd_sec_data), .sd_valid(sd_sec_valid), .sd_end(sd_sec_end), .sd_reset_req(sd_reset_req),
        .card_ready(card_ready), .busy(card_loading), .status(),
        .pix_we(pix_we), .pix_waddr(pix_waddr), .pix_wdata(pix_wdata),
        .pal_we(pal_we), .pal_waddr(pal_waddr), .pal_wdata(pal_wdata));
    clinic_card_store u_card_store(
        .clk(video_clk), .sel_loader(card_loading),
        .pix_we(pix_we), .pix_waddr(pix_waddr), .pix_wdata(pix_wdata),
        .pal_we(pal_we), .pal_waddr(pal_waddr), .pal_wdata(pal_wdata),
        .pix_ra(pix_ra), .pix_rb(pix_rb), .pix_qa(pix_qa), .pix_qb(pix_qb),
        .pal_ra(pal_ra), .pal_rb(pal_rb), .pal_qa(pal_qa), .pal_qb(pal_qb));

    // ---------------- need-card zoom sequencer (10/25; every need in turn 10/30) ----------------
    wire zoom_panel, zoom_active, zoom_full;
    wire [2:0] zoom_card;
    wire [2:0] zoom_req_card;
    wire zoom_valid;
    wire [7:0] zoom_clicks;
    wire [1:0] zoom_room;
    wire [4:0] zoom_number;
    wire [2:0] zoom_idx, zoom_total;
    clinic_need_trigger u_need_trigger(
        .clk(video_clk), .rst(rst_video), .frame_start(frame_start), .dual(dual), .link_up(link_q),
        .room_a(room_a), .room_b(room_b), .a_number(a_number), .b_number(b_number),
        .a_record(a_record), .b_record(b_record), .a_record_ok(a_record_ok), .b_record_ok(b_record_ok),
        .zoom_active(zoom_active), .zoom_full(zoom_full), .zoom_card(zoom_card),
        .card(zoom_req_card), .valid(zoom_valid), .clicks(zoom_clicks), .room(zoom_room), .number(zoom_number),
        .idx(zoom_idx), .total(zoom_total));

    // ---------------- clinic screen ----------------
    wire [23:0] osd_rgb, card_rgb;
    wire osd_de;
    clinic_screen #(.H_BLANK(160)) u_screen(
        .clk(video_clk), .rst(rst_video), .frame_start(frame_start),
        .in_de(de), .in_rgb(bg_rgb), .video_x(video_x), .pixel_y(video_y-12'd45), .dual(dual),
        .call_number(call_number), .issued_number(issued_number), .waiting_count(waiting_count),
        .help_state(help_q), .help_room(help_room), .link_up(link_q), .alarm_on(alarm_on),
        .a_room(room_a), .b_room(room_b), .a_number(a_number), .b_number(b_number),
        .a_record(a_record), .b_record(b_record), .a_record_ok(a_record_ok), .b_record_ok(b_record_ok),
        .a_op(op_code), .b_op(b_op_code), .a_ops(op_state), .b_ops(b_op_state),
        .zoom_active(zoom_active), .zoom_panel(zoom_panel), .zoom_card(zoom_card),
        .zoom_help(zoom_card == 3'd4), .zoom_room(zoom_room), .zoom_number(zoom_number),
        .zoom_idx(zoom_idx), .zoom_total(zoom_total),
        .out_de(osd_de), .out_rgb(osd_rgb));
    // pictures of the six cards and the zoom animation, on top of the screen
    clinic_card_view #(.H_BLANK(160), .SHOW_GRID(0), .HELP_CARD(4), .KEEP_Y0(382), .KEEP_Y1(416)) u_card_view(
        .clk(video_clk), .rst(rst_video), .frame_start(frame_start),
        .video_x(video_x), .pixel_y(video_y-12'd45), .de(osd_de), .in_rgb(osd_rgb), .out_rgb(card_rgb),
        .link_up(link_q), .last_card(zoom_req_card), .last_card_valid(zoom_valid), .help_state(help_q),
        .card_clicks(zoom_clicks), .card_ready(card_ready), .store_busy(card_loading),
        .pix_ra(pix_ra), .pix_rb(pix_rb), .pix_qa(pix_qa), .pix_qb(pix_qb),
        .pal_ra(pal_ra), .pal_rb(pal_rb), .pal_qa(pal_qa), .pal_qb(pal_qb),
        .zoom_panel(zoom_panel), .zoom_card(zoom_card), .zoom_active(zoom_active), .zoom_full(zoom_full));

    // ---------------- buzzer ----------------
    // H11 drives a transistor: low = sounding. Two beeps of ~0.5 s in a 2 s cycle while a
    // help request waits; silent otherwise. Board switch SW5 must be down (buzzer on).
    reg [23:0] buzz_count;
    reg [1:0] buzz_phase;
    always @(posedge video_clk or posedge rst_video) begin
        if (rst_video) begin buzz_count <= 0; buzz_phase <= 0; end
        else if (help_q != 2'd1) begin buzz_count <= 0; buzz_phase <= 0; end
        else if (buzz_count == BUZZER_DIV - 1) begin
            buzz_count <= 0;
            buzz_phase <= buzz_phase == 2'd3 ? 2'd0 : buzz_phase + 1'b1;
        end else buzz_count <= buzz_count + 1'b1;
    end
    assign buzzer = !(help_q == 2'd1 && (buzz_phase == 2'd0 || buzz_phase == 2'd2));

    // ---------------- seven-segment display ----------------
    // E1 PHY state, E2 E3 good frames, E4 undelivered presses, E5 E6 damaged frames;
    // blank with the J2 link.
    wire [6:0] seg_state, seg_ok_hi, seg_ok_lo, seg_bad_hi, seg_bad_lo, seg_fail;
    seg_decoder u_seg_fail(.bin_data(cmd_failures[3:0]), .seg_data(seg_fail));
    seg_decoder u_seg_state(.bin_data(eth_phy_state), .seg_data(seg_state));
    seg_decoder u_seg_ok_hi(.bin_data(eth_frames_ok[7:4]), .seg_data(seg_ok_hi));
    seg_decoder u_seg_ok_lo(.bin_data(eth_frames_ok[3:0]), .seg_data(seg_ok_lo));
    seg_decoder u_seg_bad_hi(.bin_data(eth_frames_bad[7:4]), .seg_data(seg_bad_hi));
    seg_decoder u_seg_bad_lo(.bin_data(eth_frames_bad[3:0]), .seg_data(seg_bad_lo));
    wire seg_on = LINK_ETH != 0;
    seg_scan #(.CLK_FREQ(25_000_000)) u_seg_scan(
        .clk(video_clk), .rst_n(~rst_video), .seg_sel(seg_sel), .seg_data(seg_data),
        .seg_data_0(seg_on ? {1'b1, seg_state} : 8'hff),
        .seg_data_1(seg_on ? {1'b1, seg_ok_hi} : 8'hff),
        .seg_data_2(seg_on ? {1'b1, seg_ok_lo} : 8'hff),
        .seg_data_3(seg_on ? {1'b1, seg_fail} : 8'hff),
        .seg_data_4(seg_on ? {1'b1, seg_bad_hi} : 8'hff),
        .seg_data_5(seg_on ? {1'b1, seg_bad_lo} : 8'hff));

    // ---------------- HDMI output ----------------
    wire axis_user, axis_valid, axis_last;
    wire [23:0] axis_data,axis_raw_data;
    wire axis_raw_user,axis_raw_valid,axis_raw_last,axis_ready,axis_input_fault,hdmi_video_locked;
    video_rgb_to_axis_640x480 u_to_axis(
        .I_clk(video_clk), .I_rst(rst_video), .I_vs(vs), .I_de(osd_de), .I_rgb(card_rgb),
        .O_video_user(axis_raw_user), .O_video_valid(axis_raw_valid), .O_video_last(axis_raw_last),
        .O_video_data(axis_raw_data));
    // Official HDMI input requires unchanged 640/800/525 raster cadence.
    // An elastic FIFO between these two synchronous rasters destroys line spacing.
    assign {axis_user,axis_valid,axis_last,axis_data}=
           {axis_raw_user,axis_raw_valid,axis_raw_last,axis_raw_data};
    hdmi_raster_monitor u_hdmi_input_monitor(.clk(video_clk),.rst(rst_video),
        .video_sof(axis_user && axis_valid),.video_valid(axis_valid),
        .video_ready(axis_ready),.video_locked(hdmi_video_locked),.fault(axis_input_fault));

    // Silent HDMI audio: the clinic board's own tone comes from the board buzzer, and an
    // HDMI stream without audio makes some monitors drop the picture.
    wire hdmi_audio_valid, hdmi_acr_valid;
    wire [23:0] hdmi_audio_left, hdmi_audio_right;
    wire [19:0] hdmi_acr_cts, hdmi_acr_n;
    media_hdmi_audio_bridge u_audio(
        .audio_clk(audio_mclk), .audio_rst(rst_audio),
        .pixel_clk(video_clk), .pixel_rst(rst_video),
        .pcm_valid(1'b0), .pcm_silence(1'b1), .pcm_left(16'sd0), .pcm_right(16'sd0),
        .source_gain(8'd255), .frame_gain(8'd255), .pcm_ready(), .sample_tick(),
        .i2s_bclk(), .i2s_lrck(), .i2s_dout(),
        .audio_valid(hdmi_audio_valid), .audio_left_data(hdmi_audio_left),
        .audio_right_data(hdmi_audio_right),
        .acr_valid(hdmi_acr_valid), .acr_cts(hdmi_acr_cts), .acr_n(hdmi_acr_n));

    wire edid_trig, edid_valid;
    wire [7:0] edid_data;
    startup_pulse #(.CNT_MAX(20'd100000)) u_startup_pulse(
        .I_clk(video_clk), .I_rst(rst_video), .O_pulse(edid_trig));

    wire [9:0] tmds_ch0, tmds_ch1, tmds_ch2, tmds_clk;
    hdmi_1_4b_transmitter_core_wrapper #(
        .DEVICE("EG"),
        .HTOTAL(800), .HSA(96), .HFP(16), .HBP(48), .HACTIVE(640),
        .VTOTAL(525), .VSA(2), .VFP(10), .VBP(33), .VACTIVE(480),
        .VIDEO_VIC(1), .VIDEO_TPG("Disable"), .VIDEO_FORMAT("RGB"),
        .AUDIO_SAMPLE_RATE("48K"), .IIC_SCL_DIV(250)
    ) u_hdmi_core(
        .I_pixel_clk(video_clk), .I_rst(rst_video),
        .I_edid_read_trig(edid_trig), .O_edid_read_valid(edid_valid), .O_edid_read_data(edid_data),
        .I_axis_s_user(axis_user), .I_axis_s_valid(axis_valid), .I_axis_s_last(axis_last),
        .I_axis_s_data(axis_data), .O_axis_s_ready(axis_ready),
        .I_audio_valid(hdmi_audio_valid), .I_audio_left_data(hdmi_audio_left),
        .I_audio_right_data(hdmi_audio_right), .I_acr_valid(hdmi_acr_valid),
        .I_acr_cts(hdmi_acr_cts), .I_acr_n(hdmi_acr_n),
        .O_video_locked(hdmi_video_locked), .O_ddc_scl(HDMI_DDC_SCL), .IO_ddc_sda(HDMI_DDC_SDA),
        .O_ch0_tmds_data(tmds_ch0), .O_ch1_tmds_data(tmds_ch1),
        .O_ch2_tmds_data(tmds_ch2), .O_clk_tmds_data(tmds_clk));
    hdmi_phy_wrapper #(.DEVICE("EG")) u_phy(
        .I_pixel_clk(video_clk), .I_serial_clk(hdmi_5x_clk), .I_rst(rst_video),
        .I_tmds_channel_0(tmds_ch0), .I_tmds_channel_1(tmds_ch1),
        .I_tmds_channel_2(tmds_ch2), .I_tmds_channel_clk(tmds_clk),
        .O_tmds_ch0_p(HDMI_D0_P), .O_tmds_ch1_p(HDMI_D1_P),
        .O_tmds_ch2_p(HDMI_D2_P), .O_tmds_clk_p(HDMI_CLK_P));
endmodule
