`timescale 1ns/1ps
// Clinic (consulting room) link endpoint (V7-3; multi-room protocol 10/25).
//
// One endpoint = one consulting room (room 0..3 = room 1..4). It receives the hall board's
// status and registration frames (layout in link_master.v), keeps the last good copy of the
// fields it shows, and sends the doctor's button presses as numbered command frames through
// link_command_tx (retried until the status frame acknowledges that sequence number in this
// room's slot). A dual-room clinic board runs two endpoints on one Ethernet port.
//
// 10/30: the room a command belongs to is frozen while that command is outstanding (cmd_room):
// switching single/dual mode or the room switch never changes the room in a re-sent frame or the
// status slot its acknowledgement is read from. The shown fields (my_number, my_record) follow the
// current room as before.
//
// ETH=1 (V8): frames go over Ethernet through eth_link (eth_tx_* / eth_rx_* byte streams)
// instead of the J2 UART wires; link_tx is then held idle and link_rx is unused.
module clinic_link #(
    parameter integer CLK_HZ = 25_000_000,
    parameter integer BAUD = 1_000_000,
    parameter integer LINK_TIMEOUT_CYCLES = 25_000_000,
    parameter integer RETRY_FRAMES = 3,
    parameter integer GIVEUP_FRAMES = 120,
    parameter integer ETH = 0
)(
    input wire clk, rst, frame_start,
    input wire [1:0] room,
    input wire link_rx,
    output wire link_tx,
    output wire eth_tx_valid,
    output wire [7:0] eth_tx_data,
    input wire eth_tx_ready,
    input wire eth_rx_valid,
    input wire [7:0] eth_rx_data,
    input wire btn_call, btn_replay, btn_help_ack,     // one-cycle pulses
    output reg [4:0] call_number,       // latest call (any room)
    output reg [4:0] my_number,         // this room's current patient (0 = none)
    output reg [4:0] issued_number, waiting_count,
    output reg [1:0] help_state, help_room, last_room,
    output reg [11:0] my_record,        // registration of my_number ({needs, symptom, level})
    output reg my_record_ok,            // my_record belongs to my_number
    output wire link_up,
    output wire [1:0] op_code,          // latest press: 1 call, 2 replay, 3 confirm help
    output wire [2:0] op_state,         // see link_command_tx
    output wire [15:0] status_frames, presses_accepted, presses_ignored, cmd_frames,
    output wire [15:0] cmd_retries, cmd_failures,
    output wire cmd_busy                // a command is outstanding (10/30)
);
    wire rx_valid;
    wire [7:0] rx_type, rx_seq;
    wire [4:0] rx_len;
    wire [127:0] rx_data;
    link_frame_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD), .LINK_TIMEOUT_CYCLES(LINK_TIMEOUT_CYCLES),
                    .BYTE_INPUT(ETH)) u_rx(
        .clk(clk), .rst(rst), .rx(link_rx), .in_valid(eth_rx_valid), .in_data(eth_rx_data),
        .frame_valid(rx_valid),
        .f_type(rx_type), .f_seq(rx_seq), .f_len(rx_len), .f_data(rx_data),
        .link_up(link_up), .frames_ok(status_frames), .crc_errors(), .sync_errors(),
        .length_errors(), .rx_errors());

    wire status_ok = rx_valid && rx_type == 8'h01 && rx_len == 5'd16;
    wire reg_ok = rx_valid && rx_type == 8'h04 && rx_len == 5'd12;
    wire [4:0] r_number = rx_data[8*(4+room) +: 5];
    reg [1:0] cmd_room;                 // room of the outstanding / next command
    wire [7:0] r_ack_seq = rx_data[8*(8+cmd_room) +: 8];
    wire [2:0] r_ack = rx_data[8*12 + 3*cmd_room +: 3];
    wire [4:0] g_ticket = rx_data[8*3*room +: 5];
    wire [11:0] g_record = {rx_data[8*(3*room+1) +: 8], rx_data[8*(3*room+2) +: 4]};
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            call_number <= 0; my_number <= 0; issued_number <= 0; waiting_count <= 0;
            help_state <= 0; help_room <= 0; last_room <= 0; my_record <= 12'h0FF; my_record_ok <= 0;
        end else begin
            if (status_ok) begin
                call_number <= rx_data[8*0 +: 5];
                issued_number <= rx_data[8*1 +: 5];
                waiting_count <= rx_data[8*2 +: 5];
                {last_room, help_room, help_state} <= rx_data[8*3 +: 6];
                my_number <= r_number;
                if (r_number != my_number) my_record_ok <= 1'b0;     // new patient: wait for the record
            end
            if (reg_ok && g_ticket == my_number && my_number != 0) begin
                my_record <= g_record; my_record_ok <= 1'b1;
            end
        end
    end

    wire tx_valid, tx_ready;
    // follows room while idle (a press takes the room of the clock before it), frozen while busy
    always @(posedge clk or posedge rst)
        if (rst) cmd_room <= 0;
        else if (!cmd_busy) cmd_room <= room;
    wire [7:0] tx_data;
    link_command_tx #(.RETRY_FRAMES(RETRY_FRAMES), .GIVEUP_FRAMES(GIVEUP_FRAMES)) u_commands(
        .clk(clk), .rst(rst), .frame_start(frame_start), .link_up(link_up),
        .btn_call(btn_call), .btn_replay(btn_replay), .btn_help_ack(btn_help_ack), .room(cmd_room),
        .link_tx_ready(tx_ready), .status_ok(status_ok),
        .ack_valid(r_ack[2]), .ack_seq(r_ack_seq), .ack_result(r_ack[1:0]),
        .link_tx_valid(tx_valid), .link_tx_data(tx_data), .busy(cmd_busy),
        .op_code(op_code), .op_state(op_state),
        .presses_accepted(presses_accepted), .presses_ignored(presses_ignored),
        .retries(cmd_retries), .failures(cmd_failures),
        .frames_done(cmd_frames));
    assign eth_tx_valid = ETH != 0 && tx_valid;
    assign eth_tx_data = tx_data;
    generate if (ETH != 0) begin : g_eth_tx
        assign tx_ready = eth_tx_ready;
        assign link_tx = 1'b1;
    end else begin : g_uart_tx
        uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_uart(
            .clk(clk), .rst(rst), .valid(tx_valid), .data(tx_data), .ready(tx_ready), .tx(link_tx));
    end endgenerate
endmodule
