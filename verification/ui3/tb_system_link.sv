`timescale 1ns/1ps
// 10/24 two-board business bench (hall touch -> core -> status frames -> clinic, doctor -> hall).
//
// Hall side wired exactly like top_tf_hdmi_audio.v after the 10/24 change (run_system_tests.py
// checks those lines are in the top): touch UART (tjc_touch_rx 9600 8N1) -> hospital_touch_keys
// (SEMANTIC_INPUT) -> request port of hospital_app_core directly (no patient UI / request mux);
// clinic commands -> link_master key pulses & 8'h07 -> core keys; accepted/rejected vectors
// echoed to link_master; link_master card_accepted = accepted_keys[5] (status byte d9).
// The event consumer is the display-only one of the top (done one clock after the event).
// Clinic side: clinic_link (ETH byte streams wired back to back, like eth_link with no loss),
// frame-latched copies as in top_clinic, clinic_card_view (HOLD_FRAMES 4) for the zoom trigger.
// Frames are 40000 clocks; the link timeout is 8 frames.
module tb;
    reg clk = 0, rst = 1;
    always #20 clk = ~clk;
    localparam integer FRAME = 40000;
    integer fc = 0;
    reg frame_start = 0;
    always @(posedge clk) begin
        fc <= fc == FRAME - 1 ? 0 : fc + 1;
        frame_start <= fc == FRAME - 1;
    end
    // ---------------- hall ----------------
    reg tjc_rx = 1;
    wire touch_cmd_valid, touch_busy, touch_command_rejected;
    wire [6:0] touch_cmd, touch_arg;
    wire touch_request_valid, touch_request_ready, touch_request_done;
    wire [2:0] touch_request_kind, touch_request_card;
    wire [4:0] touch_request_number;
    wire core_request_valid, core_request_ready, core_request_done, core_request_accepted;
    wire [2:0] core_request_kind, core_request_card, core_request_result;
    wire [4:0] core_request_number;
    wire [7:0] hospital_link_keys, hospital_core_keys;
    wire [7:0] remote_accepted, remote_invalid, remote_duplicate, remote_full, remote_conflict;
    wire [4:0] call_number, issued_number, waiting_count, h1, h2, h3;
    wire [2:0] selected_card, last_card;
    wire last_card_valid;
    wire [1:0] help_state;
    wire event_valid, busy, overflow, cerr;
    wire [43:0] event_data, active_event;
    wire [3:0] queued;
    wire [15:0] help_seq, active_seq;
    wire [7:0] accepted_keys, rejected_keys, reject_invalid, reject_duplicate, reject_full, reject_conflict;
    reg done_q; reg [15:0] done_seq_q;
    always @(posedge clk or posedge rst)
        if (rst) begin done_q <= 0; done_seq_q <= 0; end
        else begin done_q <= event_valid; if (event_valid) done_seq_q <= event_data[43:28]; end
    tjc_touch_rx #(.CLK_HZ(25_000_000), .BAUD(9600)) u_touch_rx(
        .clk(clk), .rst(rst), .rx(tjc_rx), .cmd_valid(touch_cmd_valid), .cmd(touch_cmd), .arg(touch_arg),
        .good_frames(), .bad_frames(), .other_frames(), .line_errors());
    hospital_touch_keys #(.SEMANTIC_INPUT(1)) u_touch_keys(
        .clk(clk), .rst(rst), .cmd_valid(touch_cmd_valid), .cmd(touch_cmd), .arg(touch_arg),
        .selected_card(selected_card), .key_press_in(8'd0), .key_press_out(),
        .busy(touch_busy), .accepted_cmds(), .dropped_cmds(), .command_rejected(touch_command_rejected),
        .call_number(call_number), .request_valid(touch_request_valid),
        .request_kind(touch_request_kind), .request_card(touch_request_card), .request_number(touch_request_number),
        .request_ready(touch_request_ready), .request_done(touch_request_done),
        .request_accepted(core_request_accepted), .request_result(core_request_result));
    assign core_request_valid = touch_request_valid; assign core_request_kind = touch_request_kind;
    assign core_request_card = touch_request_card; assign core_request_number = touch_request_number;
    assign touch_request_ready = core_request_ready; assign touch_request_done = core_request_done;
    assign hospital_core_keys = hospital_link_keys & 8'h07;
    assign remote_accepted = accepted_keys; assign remote_invalid = reject_invalid;
    assign remote_duplicate = reject_duplicate; assign remote_full = reject_full; assign remote_conflict = reject_conflict;
    hospital_app_core #(.TICKET_MODE(1), .SEMANTIC_INPUT(1)) core(
        .clk(clk), .rst(rst), .key_press(hospital_core_keys),
        .event_ready(1'b1), .event_done(done_q), .event_done_seq(done_seq_q),
        .call_number(call_number), .issued_number(issued_number), .waiting_count(waiting_count),
        .selected_card(selected_card), .last_card(last_card), .last_card_valid(last_card_valid),
        .help_state(help_state), .help_seq(help_seq), .event_valid(event_valid), .event_data(event_data),
        .queued_events(queued), .busy(busy), .active_seq(active_seq),
        .accepted_keys(accepted_keys), .rejected_keys(rejected_keys),
        .reject_invalid(reject_invalid), .reject_duplicate(reject_duplicate),
        .reject_full(reject_full), .reject_conflict(reject_conflict),
        .overflow_sticky(overflow), .completion_error_sticky(cerr),
        .request_valid(core_request_valid), .request_ready(core_request_ready), .request_kind(core_request_kind),
        .request_source(1'b1), .request_number(core_request_number), .request_card(core_request_card),
        .request_done(core_request_done), .request_accepted(core_request_accepted), .request_result(core_request_result),
        .history1(h1), .history2(h2), .history3(h3), .active_event(active_event));
    wire m_tx_valid, c_tx_valid;
    wire [7:0] m_tx_data, c_tx_data;
    wire hall_online;
    link_master #(.CLK_HZ(25_000_000), .BAUD(1_000_000), .LINK_TIMEOUT_CYCLES(8 * FRAME), .ETH(1)) u_link_master(
        .clk(clk), .rst(rst), .frame_start(frame_start), .link_rx(1'b1), .link_tx(),
        .eth_tx_valid(m_tx_valid), .eth_tx_data(m_tx_data), .eth_tx_ready(1'b1),
        .eth_rx_valid(c_tx_valid), .eth_rx_data(c_tx_data),
        .call_number(call_number), .issued_number(issued_number), .waiting_count(waiting_count),
        .last_card(last_card), .last_card_valid(last_card_valid), .help_state(help_state),
        .voice_busy(1'b0), .voice_status(3'd0), .queued_events(queued), .busy(busy), .page(2'd0),
        .card_accepted(accepted_keys[5]),
        .core_accepted(remote_accepted), .core_invalid(remote_invalid), .core_duplicate(remote_duplicate),
        .core_full(remote_full), .core_conflict(remote_conflict),
        .key_press(hospital_link_keys), .link_up(hall_online), .cmds_executed(), .cmds_repeated(), .cmds_bad());
    // ---------------- clinic ----------------
    reg btn_call = 0, btn_replay = 0, btn_help_ack = 0;
    wire [4:0] c_call, c_issued, c_wait;
    wire [2:0] c_last;
    wire c_lvalid, c_link;
    wire [1:0] c_help, op_code;
    wire [2:0] op_state;
    wire [7:0] card_clicks;
    clinic_link #(.CLK_HZ(25_000_000), .BAUD(1_000_000), .LINK_TIMEOUT_CYCLES(8 * FRAME), .ETH(1)) u_clinic_link(
        .clk(clk), .rst(rst), .frame_start(frame_start), .link_rx(1'b1), .link_tx(),
        .eth_tx_valid(c_tx_valid), .eth_tx_data(c_tx_data), .eth_tx_ready(1'b1),
        .eth_rx_valid(m_tx_valid), .eth_rx_data(m_tx_data),
        .btn_call(btn_call), .btn_replay(btn_replay), .btn_help_ack(btn_help_ack),
        .call_number(c_call), .issued_number(c_issued), .waiting_count(c_wait),
        .last_card(c_last), .last_card_valid(c_lvalid), .help_state(c_help), .card_clicks(card_clicks),
        .link_up(c_link), .op_code(op_code), .op_state(op_state),
        .status_frames(), .presses_accepted(), .presses_ignored(), .cmd_frames(), .cmd_retries(), .cmd_failures());
    reg [2:0] last_q; reg lvalid_q, link_q; reg [1:0] help_q; reg [7:0] clicks_q;
    always @(posedge clk or posedge rst)
        if (rst) begin last_q <= 0; lvalid_q <= 0; link_q <= 0; help_q <= 0; clicks_q <= 0; end
        else if (frame_start) begin
            last_q <= c_last; lvalid_q <= c_lvalid; link_q <= c_link; help_q <= c_link ? c_help : 2'd0;
            clicks_q <= card_clicks;
        end
    wire [15:0] pra, prb; wire [10:0] pla, plb; wire [23:0] vrgb; wire zpanel, zactive; wire [2:0] zcard;
    clinic_card_view #(.HOLD_FRAMES(4)) view(
        .clk(clk), .rst(rst), .frame_start(frame_start), .video_x(12'd0), .pixel_y(12'd600), .de(1'b0),
        .in_rgb(24'd0), .out_rgb(vrgb), .link_up(link_q), .last_card(last_q), .last_card_valid(lvalid_q),
        .help_state(help_q), .card_clicks(clicks_q), .card_ready(6'h3f), .store_busy(1'b0),
        .pix_ra(pra), .pix_rb(prb), .pix_qa(8'd0), .pix_qb(8'd0), .pal_ra(pla), .pal_rb(plb),
        .pal_qa(24'd0), .pal_qb(24'd0), .zoom_panel(zpanel), .zoom_card(zcard), .zoom_active(zactive));

    // ---------------- stimulus helpers ----------------
    localparam integer BIT = 25_000_000 / 9600;
    task uart_byte(input [7:0] b);
        integer i;
        begin
            tjc_rx = 0; repeat (BIT) @(posedge clk);
            for (i = 0; i < 8; i = i + 1) begin tjc_rx = b[i]; repeat (BIT) @(posedge clk); end
            tjc_rx = 1; repeat (BIT) @(posedge clk);
        end
    endtask
    task touch(input [6:0] cmd, input [6:0] arg);
        begin
            uart_byte(8'h5a); uart_byte({1'b0, cmd}); uart_byte({1'b0, arg}); uart_byte(8'h5a ^ cmd ^ arg);
            uart_byte(8'hff); uart_byte(8'hff); uart_byte(8'hff);
            repeat (2000) @(posedge clk);
        end
    endtask
    task frames(input integer n);
        begin repeat (n) begin @(posedge frame_start); end @(posedge clk); end
    endtask
    task press(input integer which);
        begin
            @(negedge clk);
            if (which == 0) btn_call = 1; else if (which == 1) btn_replay = 1; else btn_help_ack = 1;
            @(negedge clk); btn_call = 0; btn_replay = 0; btn_help_ack = 0;
        end
    endtask
    integer errors = 0;
    task check(input cond, input [8*72-1:0] what);
        begin
            if (!cond) begin errors = errors + 1; $display("FAIL %0s", what); end
            else $display("ok   %0s", what);
        end
    endtask
    // zoom starts observed by the clinic view
    integer zoom_starts = 0;
    reg zactive_q = 0;
    always @(posedge clk) begin
        zactive_q <= zactive;
        if (zactive && !zactive_q) zoom_starts = zoom_starts + 1;
    end
    integer z0;
    localparam integer ZOOM_FRAMES = 18 + 4 + 17 + 2;
    initial begin
        repeat (10) @(negedge clk); rst = 0;
        frames(20);                               // the clinic heartbeat is every 15 frames
        check(hall_online && c_link, "link up on both boards");
        // tickets from the touch screen
        touch(7'd3, 7'd0); touch(7'd3, 7'd0); touch(7'd3, 7'd0);
        frames(3);
        check(issued_number == 3 && c_issued == 3 && c_wait == 3, "three touch tickets reach the clinic");
        // doctor calls the next patient
        press(0); frames(6);
        check(call_number == 1 && c_call == 1 && op_code == 1 && op_state == 2, "clinic call next executed");
        press(1); frames(6);
        check(op_code == 2 && op_state == 2, "clinic replay executed");
        // expression card 3 (index 2) from the touch screen
        z0 = zoom_starts;
        touch(7'd1, 7'd2); frames(4);
        check(last_card == 2 && last_card_valid && card_clicks == 1, "card click accepted, counter 1 at the clinic");
        check(zoom_starts == z0 + 1 && zcard == 2, "clinic zooms card 3");
        frames(ZOOM_FRAMES);
        check(!zactive, "zoom finished");
        // the same card again: zooms again (10/24 fix)
        touch(7'd1, 7'd2); frames(4);
        check(card_clicks == 2 && zoom_starts == z0 + 2 && zcard == 2, "same card again zooms again");
        // the same card while it is zoomed: counted, but the zoom is not restarted
        frames(10);
        touch(7'd1, 7'd2); frames(2);
        check(card_clicks == 3 && view.st != 0 && zoom_starts == 2, "same card during its zoom: counted, zoom not restarted");
        frames(ZOOM_FRAMES);
        // help card: help pending at the clinic, red zoom of card 0
        touch(7'd1, 7'd0); frames(4);
        check(help_state == 1 && c_help == 1 && card_clicks == 4 && zcard == 0 && zoom_starts == 3,
              "help request: clinic alert and zoom of card 1");
        press(2); frames(6);
        check(help_state == 2 && c_help == 2 && op_code == 3 && op_state == 2, "doctor confirms help");
        // confirm help again with nothing pending: not possible
        frames(ZOOM_FRAMES);
        press(2); frames(6);
        check(op_code == 3 && op_state == 3, "second confirm refused (nothing pending)");
        // call until the queue is empty, then one more: refused
        press(0); frames(6); press(0); frames(6);
        check(call_number == 3 && c_wait == 0, "all tickets called");
        press(0); frames(6);
        check(op_code == 1 && op_state == 3 && call_number == 3, "call with nobody waiting refused");
        // touch keys never reach the core as raw keys any more (no J1 / HDMI pages)
        check(hospital_core_keys[7:3] == 0, "core keys limited to K1..K3");
        if (errors == 0) $display("PASS SYSTEM_LINK");
        else $display("FAILED %0d checks", errors);
        $finish;
    end
    initial begin #(64'd40 * FRAME * 400); $display("FAILED watchdog"); $finish; end
endmodule
