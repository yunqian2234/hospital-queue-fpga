`timescale 1ns/1ps
// Hall board side of the board-to-board link (V7-4; multi-room protocol 10/25).
//
// Sends the hall board's business state to the consulting rooms and turns their command
// frames into key presses (with the room) for the business core. Up to 4 rooms share the
// link (Ethernet broadcast; a dual-room clinic board runs two room endpoints).
//
// On every video frame one frame goes out, alternating:
// Status frame (hall -> rooms), type 0x01, 16 data bytes:
//   d0 call_number (latest call)   d1 issued_number   d2 waiting_count
//   d3 [1:0] help_state [3:2] help_room (who confirmed) [5:4] last_room (room of the latest call)
//   d4..d7    room 1..4 current patient (0 = none)
//   d8..d11   room 1..4: sequence number of its last command run
//   d12..d13  room r at bits 3r+2..3r of {d13,d12}: [1:0] result (0 being decided, 1 done,
//             2 not possible now, 3 busy), [2] valid (a command of that room has been received)
// Registration frame (hall -> rooms), type 0x04, 12 data bytes, room r at bytes 3r..3r+2:
//   ticket (the room's current patient) | {needs[3:0], symptom[3:0]} | {4'b0, level[3:0]}
//   (hospital_registration: record of that ticket, 12'h0FF = nothing registered)
//
// Command frame (room -> hall), type 0x02, 1 data byte: [1:0] 1 = call next (K1), 2 = replay
// (K2), 3 = confirm help (K3); [5:4] room 0..3 (= room 1..4); other bits 0.
// A room re-sends a command until a status frame acknowledges its sequence number in its own
// slot, so a command can arrive more than once with the same sequence number. Only a
// sequence number different from that room's last executed one runs; repeats are counted and
// dropped. The business core's own invalid/duplicate rules still decide what happens.
//
// ETH=1 (V8): the frames travel over Ethernet instead of the J2 UART wires. The link
// frame bytes then leave on eth_tx_* (to eth_link) and arrive on eth_rx_*; link_tx is
// held idle and link_rx is unused.
module link_master #(
    parameter integer CLK_HZ = 25_000_000,
    parameter integer BAUD = 1_000_000,
    parameter integer MAX_LEN = 16,
    parameter integer LINK_TIMEOUT_CYCLES = 25_000_000,
    parameter integer ETH = 0,
    parameter integer ROOMS = 4         // rooms this build serves (frame format is always 4 rooms)
)(
    input wire clk, rst, frame_start,
    input wire link_rx,
    output wire link_tx,
    // ETH=1 byte streams (eth_link src_* / out_*)
    output wire eth_tx_valid,
    output wire [7:0] eth_tx_data,
    input wire eth_tx_ready,
    input wire eth_rx_valid,
    input wire [7:0] eth_rx_data,
    // business state to report
    input wire [4:0] call_number, issued_number, waiting_count,
    input wire [1:0] help_state, help_room, last_room,
    input wire [19:0] room_numbers,     // {room4..room1} current patient
    input wire [47:0] room_records,     // {room4..room1} registration of that patient
    // business core verdict on the keys of the previous cycle (one-cycle pulses)
    input wire [7:0] core_accepted, core_invalid, core_duplicate, core_full, core_conflict,
    // doctor commands as staff key presses (one-cycle pulses: bit0 K1, bit1 K2, bit2 K3)
    output reg [7:0] key_press,
    output reg [1:0] key_room,
    output wire link_up,
    output reg [15:0] cmds_executed, cmds_repeated, cmds_bad
);
    localparam [7:0] T_STATUS = 8'h01, T_COMMAND = 8'h02, T_REG = 8'h04;

    // ---------------- outgoing status / registration ----------------
    reg [7:0] seq;
    reg phase;                          // 0 status, 1 registration
    reg [127:0] status, regs, payload;
    reg [7:0] last_seq [0:3];
    reg [3:0] seen;
    reg [1:0] result [0:3];
    integer r;
    always @* begin
        status = 0;
        status[8*0 +: 5] = call_number;
        status[8*1 +: 5] = issued_number;
        status[8*2 +: 5] = waiting_count;
        status[8*3 +: 6] = {last_room, help_room, help_state};
        for (r = 0; r < ROOMS; r = r + 1) begin
            status[8*(4+r) +: 5] = room_numbers[5*r +: 5];
            status[8*(8+r) +: 8] = last_seq[r];
            status[8*12 + 3*r +: 3] = {seen[r], result[r]};
        end
        regs = 0;
        for (r = 0; r < ROOMS; r = r + 1) begin
            regs[8*3*r +: 5] = room_numbers[5*r +: 5];
            regs[8*(3*r+1) +: 8] = room_records[12*r + 4 +: 8];
            regs[8*(3*r+2) +: 4] = room_records[12*r +: 4];
        end
        payload = phase ? regs : status;
    end
    wire tx_busy, tx_valid, tx_ready;
    wire [7:0] tx_data;
    link_frame_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD), .MAX_LEN(MAX_LEN)) u_tx(
        .clk(clk), .rst(rst), .send(frame_start && !tx_busy),
        .f_type(phase ? T_REG : T_STATUS), .f_seq(seq), .f_len(phase ? 5'd12 : 5'd16), .f_data(payload),
        .tx_ready(tx_ready), .tx_valid(tx_valid), .tx_data(tx_data),
        .busy(tx_busy), .frames_sent());
    assign eth_tx_valid = ETH != 0 && tx_valid;
    assign eth_tx_data = tx_data;
    generate if (ETH != 0) begin : g_eth_tx
        assign tx_ready = eth_tx_ready;
        assign link_tx = 1'b1;
    end else begin : g_uart_tx
        uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_uart(
            .clk(clk), .rst(rst), .valid(tx_valid), .data(tx_data), .ready(tx_ready), .tx(link_tx));
    end endgenerate

    // ---------------- incoming commands ----------------
    wire rx_valid;
    wire [7:0] rx_type, rx_seq;
    wire [4:0] rx_len;
    wire [127:0] rx_data;
    link_frame_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD), .MAX_LEN(MAX_LEN),
                    .LINK_TIMEOUT_CYCLES(LINK_TIMEOUT_CYCLES), .BYTE_INPUT(ETH)) u_rx(
        .clk(clk), .rst(rst), .rx(link_rx), .in_valid(eth_rx_valid), .in_data(eth_rx_data),
        .frame_valid(rx_valid),
        .f_type(rx_type), .f_seq(rx_seq), .f_len(rx_len), .f_data(rx_data),
        .link_up(link_up), .frames_ok(), .crc_errors(), .sync_errors(),
        .length_errors(), .rx_errors());
    wire [1:0] cmd_op = rx_data[1:0];
    wire [1:0] cmd_room = rx_data[5:4];

    // The core answers one cycle after the key pulse (its accepted/reject outputs are
    // registered), so the verdict for key_press is read on the following cycle.
    reg [7:0] judged;                   // key bit waiting for the core's verdict
    reg judge_wait;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            seq <= 0; phase <= 0; key_press <= 0; key_room <= 0; seen <= 0;
            for (r = 0; r < 4; r = r + 1) begin last_seq[r] <= 0; result[r] <= 0; end
            judged <= 0; judge_wait <= 0;
            cmds_executed <= 0; cmds_repeated <= 0; cmds_bad <= 0;
        end else begin
            key_press <= 0;
            if (key_press != 0) begin judged <= key_press; judge_wait <= 1'b1; end
            else if (judge_wait) begin
                judge_wait <= 1'b0;
                result[key_room] <= |(core_accepted & judged) ? 2'd1 :
                                    |((core_duplicate | core_full | core_conflict) & judged) ? 2'd3 : 2'd2;
            end
            if (frame_start && !tx_busy) begin seq <= seq + 1'b1; phase <= ~phase; end
            if (rx_valid && rx_type == T_COMMAND) begin
                if (rx_len != 5'd1 || cmd_op == 2'd0 || rx_data[7:6] != 2'd0 || rx_data[3:2] != 2'd0 ||
                    {1'b0, cmd_room} >= ROOMS)
                    cmds_bad <= cmds_bad + 1'b1;
                else if (seen[cmd_room] && rx_seq == last_seq[cmd_room])
                    cmds_repeated <= cmds_repeated + 1'b1;     // a retry of a command already run
                else begin
                    seen[cmd_room] <= 1'b1; last_seq[cmd_room] <= rx_seq; result[cmd_room] <= 2'd0;
                    cmds_executed <= cmds_executed + 1'b1;
                    key_press <= 8'b1 << (cmd_op - 2'd1);       // 1->K1, 2->K2, 3->K3
                    key_room <= cmd_room;
                end
            end
        end
    end
endmodule
