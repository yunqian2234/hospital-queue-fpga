`timescale 1ns/1ps
// 10/24 UI v3: small table ROM (item / string / glyph tables) with a one-clock synchronous
// read, in 9K BRAM via EG_LOGIC_BRAM and a MIF init file. TD maps small $readmemh ROMs to
// LUTs, which the hall board cannot afford; this keeps them in block RAM.
// Simulation: define UI_BEHAVIORAL_ROM (TD's BRAM model is encrypted) - same contents from
// the .hex twin.
module ui_table_rom #(
    parameter integer WIDTH = 12,
    parameter integer WORDS = 512,
    parameter integer AW = 9,
    parameter INIT = "table.mif",
    parameter HEX = "table.hex"
)(
    input wire clk,
    input wire [AW-1:0] addr,
    output wire [WIDTH-1:0] q
);
`ifdef UI_BEHAVIORAL_ROM
    reg [WIDTH-1:0] mem [0:WORDS-1];
    reg [WIDTH-1:0] q1;
    initial $readmemh(HEX, mem);
    always @(posedge clk) q1 <= mem[addr];
    assign q = q1;
`else
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(WIDTH), .DATA_WIDTH_B(WIDTH), .ADDR_WIDTH_A(AW), .ADDR_WIDTH_B(AW),
        .DATA_DEPTH_A(WORDS), .DATA_DEPTH_B(WORDS), .MODE("SP"),
        .REGMODE_A("NOREG"), .REGMODE_B("NOREG"), .WRITEMODE_A("NORMAL"), .WRITEMODE_B("NORMAL"),
        .RESETMODE("SYNC"), .IMPLEMENT("9K"), .INIT_FILE(INIT)
    ) u_rom(
        .dia({WIDTH{1'b0}}), .addra(addr), .cea(1'b1), .ocea(1'b0), .clka(clk), .wea(1'b0), .rsta(1'b0),
        .bea(1'b0), .doa(q),
        .dib({WIDTH{1'b0}}), .addrb({AW{1'b0}}), .ceb(1'b0), .oceb(1'b0), .clkb(1'b0), .web(1'b0), .rstb(1'b0),
        .beb(1'b0), .dob());
`endif
endmodule
