`timescale 1ns/1ps
// 10/30 command ownership bench: a press that is still outstanding keeps its room when the room
// switch / mode changes. Hall = link_master (ETH byte streams), room = clinic_link, back to back.
//   1. room 2 (room = 1) presses "call next"; the hall's receive side is held off, so the command
//      stays outstanding and is re-sent;
//   2. the room input switches to room 1 (room = 0) while it is outstanding;
//   3. the hall's receive side is released.
// Expected: the hall runs exactly ONE call, for room 2 (key_room = 1); the room reports "carried
// out" (op_state 2), not "not delivered"; a later press uses the new room (room 1).
// The business core is modelled as "accept every key" (core_accepted = key_press, one clock later).
module tb_cmd_room;
    reg clk = 0, rst = 1;
    always #20 clk = ~clk;
    integer fc = 0;
    reg frame_start = 0;
    always @(posedge clk) begin
        fc <= fc == 599 ? 0 : fc + 1;
        frame_start <= fc == 599;
    end
    reg [1:0] room = 2'd1;
    reg hold_rx = 0;
    reg btn_call = 0;
    wire h_tx_valid, r_tx_valid;
    wire [7:0] h_tx_data, r_tx_data;
    wire [7:0] key_press;
    wire [1:0] key_room;
    reg [7:0] acc_q;
    always @(posedge clk) acc_q <= key_press;
    link_master #(.ETH(1), .LINK_TIMEOUT_CYCLES(100000)) u_hall(
        .clk(clk), .rst(rst), .frame_start(frame_start), .link_rx(1'b1), .link_tx(),
        .eth_tx_valid(h_tx_valid), .eth_tx_data(h_tx_data), .eth_tx_ready(1'b1),
        .eth_rx_valid(r_tx_valid && !hold_rx), .eth_rx_data(r_tx_data),
        .call_number(5'd3), .issued_number(5'd9), .waiting_count(5'd4),
        .help_state(2'd0), .help_room(2'd0), .last_room(2'd0),
        .room_numbers(20'd0), .room_records({4{12'h0FF}}),
        .core_accepted(acc_q), .core_invalid(8'd0), .core_duplicate(8'd0), .core_full(8'd0), .core_conflict(8'd0),
        .key_press(key_press), .key_room(key_room), .link_up(), .cmds_executed(), .cmds_repeated(), .cmds_bad());
    wire [1:0] op_code;
    wire [2:0] op_state;
    wire link_up, cmd_busy;
    clinic_link #(.ETH(1), .LINK_TIMEOUT_CYCLES(100000)) u_room(
        .clk(clk), .rst(rst), .frame_start(frame_start), .room(room),
        .link_rx(1'b1), .link_tx(),
        .eth_tx_valid(r_tx_valid), .eth_tx_data(r_tx_data), .eth_tx_ready(1'b1),
        .eth_rx_valid(h_tx_valid), .eth_rx_data(h_tx_data),
        .btn_call(btn_call), .btn_replay(1'b0), .btn_help_ack(1'b0),
        .call_number(), .my_number(), .issued_number(), .waiting_count(),
        .help_state(), .help_room(), .last_room(), .my_record(), .my_record_ok(),
        .link_up(link_up), .op_code(op_code), .op_state(op_state),
        .status_frames(), .presses_accepted(), .presses_ignored(), .cmd_frames(),
        .cmd_retries(), .cmd_failures(), .cmd_busy(cmd_busy));
    integer runs = 0, errors = 0;
    reg [1:0] last_room;
    always @(posedge clk) if (key_press[0]) begin runs = runs + 1; last_room = key_room; end
    task frames(input integer n); integer i; begin for (i = 0; i < n; i = i + 1) @(posedge frame_start); end endtask
    task press; begin @(negedge clk); btn_call = 1; @(negedge clk); btn_call = 0; end endtask
    initial begin
        repeat (5) @(negedge clk); rst = 0;
        frames(8);
        if (!link_up) begin $display("FAIL link not up"); errors = errors + 1; end
        // 1..3
        hold_rx = 1;
        press;
        frames(10);                               // re-sent a few times, never reaches the hall
        if (!cmd_busy || runs != 0) begin $display("FAIL command should be outstanding (busy %0d runs %0d)", cmd_busy, runs); errors = errors + 1; end
        @(negedge clk); room = 2'd0;              // switch to room 1 while outstanding
        frames(4);
        hold_rx = 0;
        frames(20);
        if (runs != 1) begin $display("FAIL hall ran the call %0d times (want 1)", runs); errors = errors + 1; end
        else if (last_room != 2'd1) begin $display("FAIL hall ran it for room %0d (want room index 1)", last_room); errors = errors + 1; end
        if (op_state != 3'd2) begin $display("FAIL room reports op_state %0d (want 2 carried out)", op_state); errors = errors + 1; end
        // a new press now belongs to the new room
        press;
        frames(20);
        if (runs != 2 || last_room != 2'd0) begin $display("FAIL second press: runs %0d room %0d (want 2, 0)", runs, last_room); errors = errors + 1; end
        if (op_state != 3'd2) begin $display("FAIL second press op_state %0d", op_state); errors = errors + 1; end
        if (errors == 0) $display("PASS CMD_ROOM runs=%0d", runs);
        else $display("FAIL CMD_ROOM errors=%0d", errors);
        $finish;
    end
    initial begin #400000000; $display("FAIL watchdog"); $finish; end
endmodule
