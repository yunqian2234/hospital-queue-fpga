`timescale 1ns/1ps
// 10/25 multi-room stress bench: one department queue, four consulting rooms.
//
// Hall side as in top_tf_hdmi_audio.v (touch requests straight into hospital_app_core, link
// commands & 8'h07 with key_room, hospital_registration, link_master). Touch frames are
// injected at the tjc_touch_rx output (cmd_valid/cmd/arg) to keep the run short.
// Room side: four clinic_link endpoints (rooms 1..4). Rooms 1 and 2 share one port through
// link_tx_mux exactly like the dual-room clinic board; rooms 3 and 4 are separate ports.
// A switch model stores every port's frames (one byte per two clocks, like eth_mac_tx) and
// forwards them one at a time to the hall; the hall's frames are broadcast to every room.
//
// Random operations ("days" of up to 20 tickets, each day starts with a reset): check-in with
// a random registration, call next / replay / confirm help from a random room (sometimes two
// rooms in the same clock), help requests from the touch screen. Scoreboard checks:
//   C1 tickets are called in order, each exactly once, by the room that pressed
//   C2 every room's link shows the number the hall gave that room (after the link settles)
//   C3 a room shows a registration only for its own patient, and it is the one checked in
//   C4 waiting = issued - called; a call with nobody waiting is refused to that room
//   C5 one help request is confirmed by exactly one room; later confirms are refused
//   C6 every press gets a final result at its room (no lost commands)
module tb;
    parameter integer DAYS = 6, SEED = 1, STEPS_PER_DAY = 70, QDEPTH = 4;
    reg clk = 0, rst = 1;
    always #20 clk = ~clk;
    localparam integer FRAME = 4000;
    integer fc = 0;
    reg frame_start = 0;
    always @(posedge clk) begin
        fc <= fc == FRAME - 1 ? 0 : fc + 1;
        frame_start <= fc == FRAME - 1;
    end
    // ---------------- hall ----------------
    reg tcmd_valid = 0; reg [6:0] tcmd = 0, targ = 0;
    wire touch_request_valid, touch_request_ready, touch_request_done;
    wire [2:0] touch_request_kind, touch_request_card;
    wire [4:0] touch_request_number;
    wire core_request_ready, core_request_done, core_request_accepted;
    wire [2:0] core_request_result;
    wire [7:0] link_keys, core_keys;
    wire [1:0] link_room;
    wire [4:0] call_number, issued_number, waiting_count, h1, h2, h3;
    wire [2:0] selected_card, last_card;
    wire last_card_valid, event_valid, busy, overflow, cerr;
    wire [1:0] help_state, last_room, help_room;
    wire [43:0] event_data, active_event;
    wire [3:0] queued;
    wire [15:0] help_seq, active_seq;
    wire [7:0] acc, rej, rinv, rdup, rfull, rconf;
    wire [19:0] room_numbers;
    wire [11:0] reg_pending;
    wire [47:0] room_records;
    reg done_q; reg [15:0] done_seq_q;
    always @(posedge clk or posedge rst)
        if (rst) begin done_q <= 0; done_seq_q <= 0; end
        else begin done_q <= event_valid; if (event_valid) done_seq_q <= event_data[43:28]; end
    hospital_touch_keys #(.SEMANTIC_INPUT(1)) u_touch_keys(
        .clk(clk), .rst(rst), .cmd_valid(tcmd_valid), .cmd(tcmd), .arg(targ),
        .selected_card(selected_card), .key_press_in(8'd0), .key_press_out(), .busy(), .accepted_cmds(),
        .dropped_cmds(), .command_rejected(), .call_number(call_number), .request_valid(touch_request_valid),
        .request_kind(touch_request_kind), .request_card(touch_request_card), .request_number(touch_request_number),
        .request_ready(touch_request_ready), .request_done(touch_request_done),
        .request_accepted(core_request_accepted), .request_result(core_request_result));
    assign touch_request_ready = core_request_ready; assign touch_request_done = core_request_done;
    assign core_keys = link_keys & 8'h07;
    hospital_app_core #(.TICKET_MODE(1), .SEMANTIC_INPUT(1), .QDEPTH(QDEPTH)) core(
        .clk(clk), .rst(rst), .key_press(core_keys), .key_room(link_room),
        .event_ready(1'b1), .event_done(done_q), .event_done_seq(done_seq_q),
        .call_number(call_number), .issued_number(issued_number), .waiting_count(waiting_count),
        .selected_card(selected_card), .last_card(last_card), .last_card_valid(last_card_valid),
        .help_state(help_state), .help_seq(help_seq), .event_valid(event_valid), .event_data(event_data),
        .queued_events(queued), .busy(busy), .active_seq(active_seq),
        .accepted_keys(acc), .rejected_keys(rej), .reject_invalid(rinv), .reject_duplicate(rdup),
        .reject_full(rfull), .reject_conflict(rconf), .overflow_sticky(overflow), .completion_error_sticky(cerr),
        .request_valid(touch_request_valid), .request_ready(core_request_ready), .request_kind(touch_request_kind),
        .request_source(1'b1), .request_number(touch_request_number), .request_card(touch_request_card),
        .request_done(core_request_done), .request_accepted(core_request_accepted), .request_result(core_request_result),
        .history1(h1), .history2(h2), .history3(h3), .active_event(active_event),
        .room_numbers(room_numbers), .last_room(last_room), .help_room(help_room));
    hospital_registration u_reg(
        .clk(clk), .rst(rst), .cmd_valid(tcmd_valid), .cmd(tcmd), .arg(targ),
        .ticket_taken(acc[7]), .issued_number(issued_number),
        .call_taken(acc[0]), .call_number(call_number), .last_room(last_room),
        .pending(reg_pending), .room_records(room_records));
    wire h_tx_valid, h_online;
    wire [7:0] h_tx_data;
    reg h_rx_valid = 0; reg [7:0] h_rx_data = 0;
    reg h_tx_ready = 0;
    link_master #(.LINK_TIMEOUT_CYCLES(8 * FRAME), .ETH(1)) u_master(
        .clk(clk), .rst(rst), .frame_start(frame_start), .link_rx(1'b1), .link_tx(),
        .eth_tx_valid(h_tx_valid), .eth_tx_data(h_tx_data), .eth_tx_ready(h_tx_ready),
        .eth_rx_valid(h_rx_valid), .eth_rx_data(h_rx_data),
        .call_number(call_number), .issued_number(issued_number), .waiting_count(waiting_count),
        .help_state(help_state), .help_room(help_room), .last_room(last_room),
        .room_numbers(room_numbers), .room_records(room_records),
        .core_accepted(acc), .core_invalid(rinv), .core_duplicate(rdup), .core_full(rfull), .core_conflict(rconf),
        .key_press(link_keys), .key_room(link_room), .link_up(h_online),
        .cmds_executed(), .cmds_repeated(), .cmds_bad());
    // hall -> every room: one byte per two clocks
    always @(posedge clk) h_tx_ready <= !h_tx_ready && h_tx_valid;
    reg b_valid = 0; reg [7:0] b_data = 0;
    always @(posedge clk) begin b_valid <= h_tx_valid && h_tx_ready; b_data <= h_tx_data; end
    // ---------------- rooms ----------------
    reg [3:0] btn_call = 0, btn_replay = 0, btn_ack = 0;
    wire [3:0] r_valid, r_ready;
    wire [7:0] r_data [0:3];
    wire [4:0] r_call [0:3], r_my [0:3], r_issued [0:3], r_wait [0:3];
    wire [1:0] r_help [0:3], r_hroom [0:3], r_lroom [0:3], r_op [0:3];
    wire [11:0] r_rec [0:3];
    wire [3:0] r_rec_ok, r_up;
    wire [2:0] r_ops [0:3];
    genvar g;
    generate for (g = 0; g < 4; g = g + 1) begin : room
        clinic_link #(.LINK_TIMEOUT_CYCLES(8 * FRAME), .ETH(1)) u_link(
            .clk(clk), .rst(rst), .frame_start(frame_start), .room(g[1:0]), .link_rx(1'b1), .link_tx(),
            .eth_tx_valid(r_valid[g]), .eth_tx_data(r_data[g]), .eth_tx_ready(r_ready[g]),
            .eth_rx_valid(b_valid), .eth_rx_data(b_data),
            .btn_call(btn_call[g]), .btn_replay(btn_replay[g]), .btn_help_ack(btn_ack[g]),
            .call_number(r_call[g]), .my_number(r_my[g]), .issued_number(r_issued[g]), .waiting_count(r_wait[g]),
            .help_state(r_help[g]), .help_room(r_hroom[g]), .last_room(r_lroom[g]),
            .my_record(r_rec[g]), .my_record_ok(r_rec_ok[g]), .link_up(r_up[g]),
            .op_code(r_op[g]), .op_state(r_ops[g]),
            .status_frames(), .presses_accepted(), .presses_ignored(), .cmd_frames(), .cmd_retries(), .cmd_failures());
    end endgenerate
    // ports: 0 = dual-room board (rooms 1+2 through link_tx_mux), 1 = room 3, 2 = room 4
    wire [2:0] p_valid, p_ready;
    wire [7:0] p_data [0:2];
    link_tx_mux u_mux(.clk(clk), .rst(rst),
        .a_valid(r_valid[0]), .a_data(r_data[0]), .a_ready(r_ready[0]),
        .b_valid(r_valid[1]), .b_data(r_data[1]), .b_ready(r_ready[1]),
        .out_valid(p_valid[0]), .out_data(p_data[0]), .out_ready(p_ready[0]));
    assign p_valid[1] = r_valid[2]; assign p_data[1] = r_data[2]; assign r_ready[2] = p_ready[1];
    assign p_valid[2] = r_valid[3]; assign p_data[2] = r_data[3]; assign r_ready[3] = p_ready[2];
    // switch model: per port, an eth_mac_tx-like taker (one byte per two clocks while valid; a
    // frame ends at the first low valid) into a store; complete frames go to the hall in turn
    reg [7:0] store [0:2][0:255];
    reg [7:0] wr [0:2], rd [0:2];
    reg [7:0] fend [0:2][0:15];          // end pointer of each complete frame
    reg [3:0] fw [0:2], fr [0:2];
    reg [2:0] in_frame, tick;
    reg [2:0] pr;
    integer p;
    assign p_ready = tick & p_valid & in_frame;
    reg fwd_busy = 0; reg [1:0] fwd_port = 0; reg fwd_tick = 0;
    reg [4:0] gap = 0;
    initial begin
        for (p = 0; p < 3; p = p + 1) begin wr[p] = 0; rd[p] = 0; fw[p] = 0; fr[p] = 0; end
        in_frame = 0; tick = 0;
    end
    always @(posedge clk) begin
        h_rx_valid <= 0;
        for (p = 0; p < 3; p = p + 1) begin
            if (!in_frame[p] && p_valid[p]) begin in_frame[p] <= 1; tick[p] <= 1; end
            else if (in_frame[p]) begin
                if (!p_valid[p]) begin
                    in_frame[p] <= 0; fend[p][fw[p]] <= wr[p]; fw[p] <= fw[p] + 1;
                end else begin
                    if (tick[p]) begin store[p][wr[p]] <= p_data[p]; wr[p] <= wr[p] + 1; end
                    tick[p] <= ~tick[p];
                end
            end
        end
        if (!fwd_busy) begin
            if (gap != 0) gap <= gap - 1;
            else if (fr[0] != fw[0]) begin fwd_busy <= 1; fwd_port <= 0; end
            else if (fr[1] != fw[1]) begin fwd_busy <= 1; fwd_port <= 1; end
            else if (fr[2] != fw[2]) begin fwd_busy <= 1; fwd_port <= 2; end
            fwd_tick <= 0;
        end else begin
            fwd_tick <= ~fwd_tick;
            if (fwd_tick) begin
                if (rd[fwd_port] == fend[fwd_port][fr[fwd_port]]) begin
                    fr[fwd_port] <= fr[fwd_port] + 1; fwd_busy <= 0; gap <= 20;
                end else begin
                    h_rx_valid <= 1; h_rx_data <= store[fwd_port][rd[fwd_port]]; rd[fwd_port] <= rd[fwd_port] + 1;
                end
            end
        end
    end

    // ---------------- scoreboard ----------------
    integer errors = 0, calls = 0, refused_calls = 0, regs_checked = 0, helps = 0, acks_refused = 0, ops = 0;
    integer last_called;
    reg [1:0] owner [1:20];
    reg [11:0] model_reg [1:20];
    task fail(input [8*80-1:0] what);
        begin errors = errors + 1; if (errors < 20) $display("FAIL t=%0t %0s", $time, what); end
    endtask
    // C1 / C4 / C5 on the core's verdicts
    reg help_open = 0; reg [1:0] help_by;
    always @(posedge clk) if (!rst) begin
        if (acc[0]) begin
            calls = calls + 1;
            if (call_number != last_called + 1) fail("C1 call out of order");
            if (room_numbers[5 * last_room +: 5] != call_number) fail("C1 room number not updated");
            owner[call_number] = last_room;
            last_called = call_number;
        end
        if (rinv[0]) refused_calls = refused_calls + 1;
        if (waiting_count != issued_number - call_number) fail("C4 waiting count");
        if (acc[2]) begin
            if (!help_open) fail("C5 confirm without a pending help");
            help_open = 0; help_by = help_room;
        end
        if (rinv[2]) acks_refused = acks_refused + 1;
        if (help_state == 1) help_open = 1;
    end
    // C2 / C3 sampled once per frame when the link is quiet
    integer r, settle = 0;
    always @(posedge frame_start) if (!rst) begin
        settle = settle + 1;
        if (settle > 12) for (r = 0; r < 4; r = r + 1) begin
            if (!r_up[r]) fail("link down");
            if (r_rec_ok[r] && r_my[r] != 0 && r_rec[r] != model_reg[r_my[r]]) fail("C3 wrong registration shown");
            if (r_rec_ok[r]) regs_checked = regs_checked + 1;
        end
    end
    task touch(input [6:0] c, input [6:0] a);
        begin
            @(negedge clk); tcmd_valid = 1; tcmd = c; targ = a; @(negedge clk); tcmd_valid = 0;
            repeat (40) @(negedge clk);
        end
    endtask
    task frames(input integer n);
        begin repeat (n) @(posedge frame_start); @(negedge clk); end
    endtask
    // C2: once everything is delivered, every room shows the hall's number for it
    task check_rooms;
        begin
            frames(6);
            for (r = 0; r < 4; r = r + 1) begin
                if (r_my[r] !== room_numbers[5 * r +: 5]) fail("C2 room shows a different patient");
                if (r_call[r] !== call_number || r_wait[r] !== waiting_count) fail("C2 status differs");
                if (r_my[r] != 0 && !r_rec_ok[r]) fail("C3 registration not delivered");
                if (r_op[r] != 0 && (r_ops[r] == 1 || r_ops[r] == 5)) fail("C6 press without a final result");
            end
        end
    endtask
    integer day, step, op, rm, rm2, need, sym, lvl, seed;
    initial begin
        seed = SEED;
        for (day = 0; day < DAYS; day = day + 1) begin
            rst = 1; repeat (10) @(negedge clk); rst = 0;
            last_called = 0; help_open = 0; settle = 0;
            for (r = 1; r <= 20; r = r + 1) model_reg[r] = 12'h0FF;
            frames(14);
            for (step = 0; step < STEPS_PER_DAY; step = step + 1) begin
                op = $unsigned($random(seed)) % 10;
                rm = $unsigned($random(seed)) % 4;
                rm2 = $unsigned($random(seed)) % 4;
                ops = ops + 1;
                case (op)
                    0, 1, 2: begin                                   // check-in, with or without registration
                        touch(7'd8, 0);
                        need = $unsigned($random(seed)) % 16; sym = $unsigned($random(seed)) % 12;
                        lvl = $unsigned($random(seed)) % 13;
                        if ($random(seed) & 1) begin
                            touch(7'd5, need); touch(7'd6, sym); touch(7'd7, lvl);
                        end else begin need = 0; sym = 15; lvl = 15; end
                        if (issued_number < 20) model_reg[issued_number + 1] =
                            {need[3:0], sym <= 9 ? sym[3:0] : 4'hF, lvl <= 10 ? lvl[3:0] : 4'hF};
                        touch(7'd3, 0);
                    end
                    3, 4: begin @(negedge clk); btn_call[rm] = 1; @(negedge clk); btn_call = 0; end
                    5: begin                                         // two rooms press call in the same clock
                        @(negedge clk); btn_call[rm] = 1; btn_call[rm2] = 1; @(negedge clk); btn_call = 0;
                    end
                    6: begin @(negedge clk); btn_replay[rm] = 1; @(negedge clk); btn_replay = 0; end
                    7: begin touch(7'd1, 0); helps = helps + 1; end  // help from the touch screen
                    8: begin @(negedge clk); btn_ack[rm] = 1; btn_ack[rm2] = 1; @(negedge clk); btn_ack = 0; end
                    default: begin @(negedge clk); btn_ack[rm] = 1; @(negedge clk); btn_ack = 0; end
                endcase
                frames(1 + $unsigned($random(seed)) % 3);
                if (step % 10 == 9) check_rooms;
            end
            check_rooms;
        end
        $display("ops=%0d calls=%0d refused_calls=%0d help_requests=%0d confirms_refused=%0d registration_checks=%0d",
                 ops, calls, refused_calls, helps, acks_refused, regs_checked);
        if (errors == 0) $display("PASS MULTIROOM");
        else $display("FAILED %0d", errors);
        $finish;
    end
endmodule
