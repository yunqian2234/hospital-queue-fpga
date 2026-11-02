`timescale 1ns/1ps
// 10/24 UI v3: glyph pixel ROM, 8-bit words, two-clock read (registered address + output
// register), in block RAM via EG_LOGIC_BRAM with a MIF init file (BRAM = "32K" or "9K"). Simulation: define
// UI_BEHAVIORAL_ROM (TD's BRAM model is encrypted) - the same contents from the .hex twin.
module ui_glyph_rom #(
    parameter integer WORDS = 4096,
    parameter INIT = "glyph.mif",
    parameter HEX = "glyph.hex",
    parameter BRAM = "32K"
)(
    input wire clk,
    input wire [15:0] addr,
    output wire [7:0] q
);
    localparam integer AW = WORDS <= 4096 ? 12 : WORDS <= 8192 ? 13 : WORDS <= 16384 ? 14 : WORDS <= 32768 ? 15 : 16;
`ifdef UI_BEHAVIORAL_ROM
    reg [7:0] mem [0:WORDS-1];
    reg [7:0] q1, q2;
    initial $readmemh(HEX, mem);
    always @(posedge clk) begin q1 <= mem[addr[AW-1:0]]; q2 <= q1; end
    assign q = q2;
`else
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(8), .DATA_WIDTH_B(8), .ADDR_WIDTH_A(AW), .ADDR_WIDTH_B(AW),
        .DATA_DEPTH_A(WORDS), .DATA_DEPTH_B(WORDS), .MODE("SP"),
        .REGMODE_A("OUTREG"), .REGMODE_B("NOREG"), .WRITEMODE_A("NORMAL"), .WRITEMODE_B("NORMAL"),
        .RESETMODE("SYNC"), .IMPLEMENT(BRAM), .INIT_FILE(INIT)
    ) u_rom(
        .dia(8'd0), .addra(addr[AW-1:0]), .cea(1'b1), .ocea(1'b1), .clka(clk), .wea(1'b0), .rsta(1'b0),
        .bea(1'b0), .doa(q),
        .dib(8'd0), .addrb({AW{1'b0}}), .ceb(1'b0), .oceb(1'b0), .clkb(1'b0), .web(1'b0), .rstb(1'b0),
        .beb(1'b0), .dob());
`endif
endmodule
