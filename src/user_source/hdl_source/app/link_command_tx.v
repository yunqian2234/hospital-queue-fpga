`timescale 1ns/1ps
// Clinic -> hall command sender (V7-3; acknowledgement reworked 10/07 for the Ethernet link).
//
// A doctor's button press is latched here and sent as a numbered command frame
// (type 0x02, 1 data byte). The first attempt goes out immediately and the same frame is
// re-sent every RETRY_FRAMES frames until the hall board's status frame ACKNOWLEDGES THIS
// SEQUENCE NUMBER: the hall reports the sequence number of the last command it ran and
// whether the business core carried it out (status bytes d7/d8, V8 document). The hall
// board drops repeats of a sequence number, so re-sending is safe: one press = one action.
//
// (Up to 10/06 any status frame counted as the answer. The hall sends status every frame
// whether or not a command arrived, so a command frame lost on the cable was silently
// dropped and the button "did nothing". On the J2 wires no frame was ever lost, which is
// why this only showed up on the network cable.)
//
// After GIVEUP_FRAMES frames without the acknowledgement the press is reported as not
// delivered. While not sending, the sequence counter follows the number the hall last
// acknowledged, so after a reset of either board the next press never repeats the number
// the hall last ran (which it would drop as a repeat).
//
// Commands are only accepted while link_up is high; presses made while the cable is
// unplugged are refused (not delivered) and counted in presses_ignored.
// New presses while pending, or simultaneous doctor buttons, are refused as busy.
// The prior command continues retrying with its original seq; its late ACK does not
// overwrite the latest refused operation shown by the clinic screen.
//
// Heartbeat: with no command pending, an empty frame (type 0x03, no data) goes out every
// HEARTBEAT_FRAMES frames, so the hall board can tell the clinic board is alive even when
// the doctor presses nothing. It carries no command and is never executed.
//
// op_code / op_state describe the latest press for the clinic screen:
//   op_code  0 none, 1 call next, 2 replay, 3 confirm help
//   op_state 0 none, 1 sending, 2 carried out, 3 refused: not possible now (nobody
//            waiting / no call yet / no help request), 4 refused: busy (the same voice
//            announcement is still queued, or the queue is full), 5 not delivered
//            (no acknowledgement within GIVEUP_FRAMES)
module link_command_tx #(
    parameter integer MAX_LEN = 16,
    parameter integer RETRY_FRAMES = 3,       // ~50 ms at 60 Hz between attempts
    parameter integer GIVEUP_FRAMES = 120,    // ~2 s
    parameter integer HEARTBEAT_FRAMES = 15   // ~0.25 s at 60 Hz
)(
    input wire clk, rst, frame_start,
    input wire link_up,
    input wire btn_call, btn_replay, btn_help_ack,
    input wire [1:0] room,                    // 10/25: 0..3 = room 1..4, sent in data[5:4]
    input wire link_tx_ready,
    input wire status_ok,                     // hall board status frame accepted this cycle
    input wire ack_valid,                     // ... it carries a command acknowledgement
    input wire [7:0] ack_seq,                 // ... for this sequence number
    input wire [1:0] ack_result,              // ... 0 being decided, 1 done, 2 not possible, 3 busy
    output wire link_tx_valid,
    output wire [7:0] link_tx_data,
    output wire busy,
    output reg [1:0] op_code,
    output reg [2:0] op_state,
    output reg [15:0] presses_accepted, presses_ignored, retries, failures,
    output wire [15:0] frames_done            // counted by link_frame_tx
);
    localparam [7:0] T_COMMAND = 8'h02, T_HEARTBEAT = 8'h03;
    localparam [7:0] C_CALL = 8'd1, C_REPLAY = 8'd2, C_HELP_ACK = 8'd3;
    localparam [2:0] OP_NONE = 0, OP_SENDING = 1, OP_LOST = 5;

    reg [7:0] code, seq;
    reg [5:0] retry;
    reg [7:0] age;
    reg [4:0] beat;
    reg pending,report_pending;
    wire press=btn_call || btn_replay || btn_help_ack;
    wire single_press=({btn_call,btn_replay,btn_help_ack}==3'b100 ||
                       {btn_call,btn_replay,btn_help_ack}==3'b010 ||
                       {btn_call,btn_replay,btn_help_ack}==3'b001);
    wire beat_due = !pending && frame_start && beat == 0;
    wire tx_busy;
    reg [127:0] data;
    wire acked = status_ok && ack_valid && ack_seq == seq && ack_result != 2'd0;

    always @* begin
        data = 0;
        data[7:0] = {2'b00, room, 2'b00, code[1:0]};
    end

    assign busy = pending;

    link_frame_tx #(.MAX_LEN(MAX_LEN)) u_tx(
        .clk(clk), .rst(rst),
        .send(!tx_busy && ((pending && retry == 0) || beat_due)),          // retry 0 = send now
        .f_type(pending ? T_COMMAND : T_HEARTBEAT), .f_seq(seq),
        .f_len(pending ? 5'd1 : 5'd0), .f_data(data),
        .tx_ready(link_tx_ready), .tx_valid(link_tx_valid), .tx_data(link_tx_data),
        .busy(tx_busy), .frames_sent(frames_done));

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            code <= 0; seq <= 0; retry <= 0; age <= 0; pending <= 0; beat <= 0; report_pending<=1;
            op_code <= 0; op_state <= OP_NONE;
            presses_accepted <= 0; presses_ignored <= 0; retries <= 0; failures <= 0;
        end else begin
            if (frame_start) beat <= beat == 0 ? HEARTBEAT_FRAMES[4:0] - 5'd1 : beat - 1'b1;
            if (pending) begin
                if (acked) begin
                    // The hall ran exactly this command: stop re-sending.
                    pending <= 1'b0;
                    if(report_pending) op_state <= {1'b0, ack_result} + 3'd1;        // 1->2, 2->3, 3->4
                end else if (frame_start && age == GIVEUP_FRAMES - 1) begin
                    pending <= 1'b0; if(report_pending) op_state <= OP_LOST; failures <= failures + 1'b1;
                end else begin
                    if (frame_start) age <= age + 1'b1;
                    if (retry == 0 && !tx_busy) retry <= RETRY_FRAMES[5:0];       // just sent: wait
                    else if (frame_start && retry != 0) begin
                        retry <= retry - 1'b1;
                        if (retry == 6'd1) retries <= retries + 1'b1;              // re-send next cycle
                    end
                end
            end else if (status_ok && ack_valid) begin
                seq <= ack_seq;                 // follow the hall's numbering while idle
            end
            if(press) begin
                op_code <= btn_call ? 2'd1 : btn_replay ? 2'd2 : 2'd3;
                if(!link_up || pending || !single_press) begin
                    // Refuse the new input explicitly; never overwrite an unacknowledged command.
                    presses_ignored<=presses_ignored+1'b1;
                    op_state<=link_up ? 3'd4:OP_LOST;
                    report_pending<=0;
                end else begin
                    pending<=1;report_pending<=1;
                    code<=btn_call ? C_CALL:btn_replay ? C_REPLAY:C_HELP_ACK;
                    op_state<=OP_SENDING;seq<=seq+1'b1;retry<=0;age<=0;
                    presses_accepted<=presses_accepted+1'b1;
                end
            end
        end
    end
endmodule
