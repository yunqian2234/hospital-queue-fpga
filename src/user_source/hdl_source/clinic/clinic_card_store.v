`timescale 1ns/1ps
// 10/23 诊室板卡片存储：6 张 120×90 的 8 位调色板索引 + 6 套 256 色调色板。
//   pix: 6*10800 = 64800 bytes in a 64K x 8 true dual-port RAM (all 16 BRAM32K blocks)
//   pal: 6*256 entries x 24 bit in a 2K x 24 true dual-port RAM (9K blocks)
// Port A: loader writes while sel_loader=1, otherwise the zoom row fill reads row r0.
// Port B: read only - the zoom row fill (horizontal blanking) or the small cards (active video).
// Both read ports have an output register: data for an address appears two clock edges later.
// Simulation: TD's BRAM model is encrypted; benches define CLINIC_CARD_BEHAVIORAL_RAM.
module clinic_card_store(
    input wire clk,
    input wire sel_loader,
    input wire pix_we, input wire [15:0] pix_waddr, input wire [7:0] pix_wdata,
    input wire pal_we, input wire [10:0] pal_waddr, input wire [23:0] pal_wdata,
    input wire [15:0] pix_ra, pix_rb, output wire [7:0] pix_qa, pix_qb,
    input wire [10:0] pal_ra, pal_rb, output wire [23:0] pal_qa, pal_qb
);
    wire [15:0] pix_addr_a = sel_loader ? pix_waddr : pix_ra;
    wire [10:0] pal_addr_a = sel_loader ? pal_waddr : pal_ra;
    wire pix_we_a = sel_loader && pix_we;
    wire pal_we_a = sel_loader && pal_we;
`ifdef CLINIC_CARD_BEHAVIORAL_RAM
    reg [7:0] pix [0:65535];
    reg [23:0] pal [0:2047];
    reg [7:0] pa1, pa2, pb1, pb2;
    reg [23:0] la1, la2, lb1, lb2;
    always @(posedge clk) begin
        if (pix_we_a) pix[pix_addr_a] <= pix_wdata;
        if (pal_we_a) pal[pal_addr_a] <= pal_wdata;
        pa1 <= pix[pix_addr_a]; pa2 <= pa1;
        pb1 <= pix[pix_rb]; pb2 <= pb1;
        la1 <= pal[pal_addr_a]; la2 <= la1;
        lb1 <= pal[pal_rb]; lb2 <= lb1;
    end
    assign pix_qa = pa2; assign pix_qb = pb2;
    assign pal_qa = la2; assign pal_qb = lb2;
`else
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(8), .DATA_WIDTH_B(8), .ADDR_WIDTH_A(16), .ADDR_WIDTH_B(16),
        .DATA_DEPTH_A(65536), .DATA_DEPTH_B(65536), .MODE("DP"),
        .REGMODE_A("OUTREG"), .REGMODE_B("OUTREG"), .WRITEMODE_A("NORMAL"), .WRITEMODE_B("NORMAL"),
        .RESETMODE("SYNC"), .IMPLEMENT("32K")
    ) u_pix(
        .dia(pix_wdata), .addra(pix_addr_a), .cea(1'b1), .ocea(1'b1), .clka(clk), .wea(pix_we_a), .rsta(1'b0),
        .bea(1'b0), .doa(pix_qa),
        .dib(8'd0), .addrb(pix_rb), .ceb(1'b1), .oceb(1'b1), .clkb(clk), .web(1'b0), .rstb(1'b0),
        .beb(1'b0), .dob(pix_qb));
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(24), .DATA_WIDTH_B(24), .ADDR_WIDTH_A(11), .ADDR_WIDTH_B(11),
        .DATA_DEPTH_A(2048), .DATA_DEPTH_B(2048), .MODE("DP"),
        .REGMODE_A("OUTREG"), .REGMODE_B("OUTREG"), .WRITEMODE_A("NORMAL"), .WRITEMODE_B("NORMAL"),
        .RESETMODE("SYNC"), .IMPLEMENT("9K")
    ) u_pal(
        .dia(pal_wdata), .addra(pal_addr_a), .cea(1'b1), .ocea(1'b1), .clka(clk), .wea(pal_we_a), .rsta(1'b0),
        .bea(1'b0), .doa(pal_qa),
        .dib(24'd0), .addrb(pal_rb), .ceb(1'b1), .oceb(1'b1), .clkb(clk), .web(1'b0), .rstb(1'b0),
        .beb(1'b0), .dob(pal_qb));
`endif
endmodule
