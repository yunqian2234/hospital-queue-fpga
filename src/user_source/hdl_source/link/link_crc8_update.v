`timescale 1ns/1ps
// CRC-8 (poly 0x07, init 0x00, no reflection, no final XOR) byte update, combinational.
// Shared by the board-to-board link transmitter and receiver so the two sides cannot
// drift apart. Check value: crc8("123456789") = 0xF4 (checked by run_link_tests.py).
module link_crc8_update(
    input wire [7:0] crc_in,
    input wire [7:0] data,
    output reg [7:0] crc_out
);
    integer i;
    reg [7:0] c;
    always @* begin
        c = crc_in ^ data;
        for (i = 0; i < 8; i = i + 1)
            c = c[7] ? ((c << 1) ^ 8'h07) : (c << 1);
        crc_out = c;
    end
endmodule
