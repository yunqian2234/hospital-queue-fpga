`timescale 1ns/1ps
// Board-to-board link: frame transmitter (V7-2).
//
// Frame on the wire:  A5 <type> <seq> <len> <data0..data(len-1)> <crc8>
//   crc8 covers type, seq, len and data (not the A5 sync byte), poly 0x07.
//   len <= MAX_LEN; data byte i is data[8*i +: 8].
//
// A frame is queued by pulsing `send` with the frame fields stable; they are copied into
// internal registers on that cycle, so the caller may change them right afterwards.
// `busy` is high until the CRC byte has been accepted by uart_tx. Byte index `bi`:
//   0 = A5, 1 = type, 2 = seq, 3 = len, 4..4+len-1 = data, 4+len = crc
// Output bytes are selected combinationally, so no RAM or shift register is inferred.
module link_frame_tx #(
    parameter integer CLK_HZ = 25_000_000,
    parameter integer BAUD = 1_000_000,
    parameter integer MAX_LEN = 16
)(
    input wire clk, rst,
    input wire send,
    input wire [7:0] f_type,
    input wire [7:0] f_seq,
    input wire [4:0] f_len,             // 0..MAX_LEN
    input wire [MAX_LEN*8-1:0] f_data,
    input wire tx_ready,
    output wire tx_valid,
    output wire [7:0] tx_data,
    output reg busy,
    output reg [15:0] frames_sent
);
    localparam [7:0] SYNC = 8'hA5;
    reg [7:0] type_q, seq_q, crc_q;
    reg [4:0] len_q, bi;
    reg [MAX_LEN*8-1:0] data_q;

    wire [4:0] last = len_q + 5'd4;     // index of the CRC byte
    wire [4:0] didx = bi - 5'd4;        // payload index while 4 <= bi < last
    wire tx_accept = tx_valid && tx_ready;

    reg [7:0] byte_out;
    always @* begin
        if (bi == 5'd0)      byte_out = SYNC;
        else if (bi == 5'd1) byte_out = type_q;
        else if (bi == 5'd2) byte_out = seq_q;
        else if (bi == 5'd3) byte_out = {3'b0, len_q};
        else if (bi == last) byte_out = crc_q;
        else                 byte_out = data_q[{didx, 3'b000} +: 8];
    end
    assign tx_valid = busy;
    assign tx_data = byte_out;

    // CRC of the bytes sent so far, excluding the sync byte.
    wire [7:0] crc_next;
    link_crc8_update u_crc(.crc_in(crc_q), .data(byte_out), .crc_out(crc_next));

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            busy <= 0; bi <= 0; type_q <= 0; seq_q <= 0; len_q <= 0; crc_q <= 0;
            data_q <= 0; frames_sent <= 0;
        end else if (!busy) begin
            if (send) begin
                busy <= 1'b1; bi <= 0;
                type_q <= f_type; seq_q <= f_seq; len_q <= f_len; data_q <= f_data;
                crc_q <= 8'h00;
            end
        end else if (tx_accept) begin
            if (bi == last) begin busy <= 0; frames_sent <= frames_sent + 1'b1; end
            // bi 0 is the sync byte, which the CRC deliberately does not cover, so the
            // register is left at its init value for that byte (matches link_frame_rx).
            else begin
                if (bi != 5'd0) crc_q <= crc_next;
                bi <= bi + 1'b1;
            end
        end
    end
endmodule
