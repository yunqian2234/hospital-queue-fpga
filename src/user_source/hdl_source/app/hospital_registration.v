`timescale 1ns/1ps
// 10/25 check-in registration (ENT department): what the patient selected on the touch screen
// before "报到", bound to the ticket, and handed to the room that calls that ticket.
//
// Touch frames (tjc_touch_rx, 5A cmd arg chk FF FF FF), all optional, sent before cmd 3 (报到):
//   cmd 5 arg = needs bitmask [3:0]: b0 听力差，请书写  b1 说话困难  b2 头晕需搀扶  b3 需家属/手语翻译
//   cmd 6 arg = main symptom 0..9 (听力下降 耳鸣 耳痛或流脓 鼻塞流涕 鼻出血 咽痛 声音嘶哑
//               吞咽困难或异物感 头晕 其他); any other value = not given
//   cmd 7 arg = how unwell 0..10; any other value = not given
//   cmd 8     = clear (the screen sends it when the registration page opens)
// Record = {needs[3:0], symptom[3:0], level[3:0]}; NONE = 12'h0FF (no needs, nothing given).
// When the core accepts a ticket (ticket_taken, issued_number already updated) the pending
// record is stored for that ticket and cleared, so the next patient starts empty. When a room
// calls a ticket (call_taken, call_number / last_room already updated) that ticket's record is
// copied to the room. Tickets are 1..20 (5-bit table, 32 entries, distributed RAM).
module hospital_registration #(
    parameter integer ROOMS = 4         // rooms served; records of the others stay NONE
)(
    input wire clk, rst,
    input wire cmd_valid,
    input wire [6:0] cmd, arg,
    input wire ticket_taken,            // core accepted_keys[7]
    input wire [4:0] issued_number,
    input wire call_taken,              // core accepted_keys[0]
    input wire [4:0] call_number,
    input wire [1:0] last_room,
    output reg [11:0] pending,          // what the screen has selected so far
    output reg [47:0] room_records      // {room4, room3, room2, room1} records of their patients
);
    localparam [11:0] NONE = 12'h0FF;
    reg [11:0] table_mem [0:31];
    reg [11:0] rd_q;
    reg call_d;
    reg [1:0] room_d;
    integer i;
    initial for (i = 0; i < 32; i = i + 1) table_mem[i] = NONE;
    always @(posedge clk) begin
        if (ticket_taken) table_mem[issued_number] <= pending;
        rd_q <= table_mem[call_number];
    end
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            pending <= NONE; room_records <= {4{NONE}}; call_d <= 0; room_d <= 0;
        end else begin
            // read one clock after the call (rd_q holds table[call_number] of the updated number)
            call_d <= call_taken; room_d <= last_room;
            if (call_d && {1'b0, room_d} < ROOMS) room_records[{1'b0, room_d, 3'b000} + {2'b00, room_d, 2'b00} +: 12] <= rd_q;
            if (ticket_taken) pending <= NONE;
            else if (cmd_valid)
                case (cmd)
                    7'd5: pending[11:8] <= arg[3:0];
                    7'd6: pending[7:4] <= arg <= 7'd9 ? arg[3:0] : 4'hF;
                    7'd7: pending[3:0] <= arg <= 7'd10 ? arg[3:0] : 4'hF;
                    7'd8: pending <= NONE;
                    default: ;
                endcase
        end
    end
endmodule
