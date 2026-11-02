`timescale 1ns/1ps
// Ethernet FCS (CRC-32, IEEE 802.3), one nibble per call, LSB first.
//
// Reflected form: poly 0xEDB88320, register initialised to 0xFFFFFFFF. The transmitter
// sends ~crc low nibble first; a receiver that runs the whole frame including the FCS
// through this update ends with the fixed residue 0xDEBB20E3. Nibble order on RGMII at
// 100 Mbps is low nibble of each byte first, which is exactly the bit order this expects.
module eth_crc32_nibble(
    input wire [31:0] crc_in,
    input wire [3:0] data,
    output reg [31:0] crc_out
);
    integer i;
    always @* begin
        crc_out = crc_in;
        for (i = 0; i < 4; i = i + 1)
            crc_out = (crc_out[0] ^ data[i]) ? (crc_out >> 1) ^ 32'hEDB88320 : crc_out >> 1;
    end
endmodule
