`timescale 1ns/1ps
// RGMII pins at 100 Mbps for the board's RTL8211E (V8 Ethernet link).
//
// At 100 Mbps RGMII runs a 25 MHz clock and carries one nibble per clock, the same nibble
// on both edges; the control line is EN/DV on the rising edge and EN^ER / DV^ER on the
// falling edge (equal when there is no error).
//
// Transmit. The PHY samples on BOTH edges of TXC: TX_EN and the nibble on the rising edge,
// TX_EN ^ TX_ER (and the nibble again) on the falling edge. So TXD/TX_CTL must be steady
// around both edges, also when the PHY's TXDLY strap delays its TXC by 2 ns.
// Up to 10/07 TXC was the 25 MHz clock inverted and the data changed on its rising edge,
// i.e. exactly at the TXC falling edge: at the end of each frame the PHY could read TX_EN
// already low on that edge = TX_ER, and send the frame with an error symbol. Whether it did
// depended on sub-nanosecond delays: some frames on the first build, nearly all after the
// 10/07 change (clinic "link down", damaged-frame counter running).
// Now everything is driven from clk5 (125 MHz, same PLL as clk, rising edges aligned),
// through IO DDR registers (4 ns resolution). With cycle k = the clk5 period starting
// k*8 ns after a clk rising edge (0..4):
//   TXD/TX_CTL change at the start of cycle 3 (24 ns) and hold for 40 ns;
//   TXC rises at the start of cycle 4 (32 ns), falls 20 ns later (52 ns).
// Data is steady from 8 ns before each rising edge to 12 ns after each falling edge
// (10 ns / 10 ns with the 2 ns TXDLY). TD times the clk -> clk5 crossing (8 ns budget).
//
// Receive: RXC comes from the PHY on a global clock pin (T14, GCLKIOT_3). Each input is
// captured by a plain flip-flop on the RXC falling edge. The data changes at the rising
// edge (or 2 ns before RXC if the PHY's RXDLY strap is set), so the falling edge is about
// 18..20 ns away from any transition either way. An IDDR is deliberately not used: at
// 100 Mbps only one edge is needed, and the IDDR's unused rising-edge register would be
// timed against the data transition (a -5 ns hold "violation" on a path nothing reads).
module eth_rgmii_io(
    // transmit side, clk domain
    input wire clk,
    input wire clk5,                    // 125 MHz, same PLL as clk (HDMI serial clock)
    input wire tx_en,
    input wire [3:0] txd,
    output wire rgmii_txc,
    output wire [3:0] rgmii_txd,
    output wire rgmii_tx_ctl,
    // receive side
    input wire rgmii_rxc,
    input wire [3:0] rgmii_rxd,
    input wire rgmii_rx_ctl,
    output wire rxc,                    // receive clock for the MAC
    output wire rx_dv,                  // rxc domain
    output wire [3:0] rxd
);
    // clk: a toggle marks every rising edge
    reg tog = 1'b0;
    always @(posedge clk) tog <= ~tog;
    // clk5: find cycle 1 (t1 has just taken the new toggle), capture the nibble at the start
    // of cycle 2, keep a cycle counter for the TXC pattern.
    reg t1 = 1'b0, t2 = 1'b0;
    reg [2:0] ph = 3'd0;                // number of the clk5 cycle now running
    reg en_c = 1'b0;
    reg [3:0] txd_c = 4'd0;
    always @(posedge clk5) begin
        t1 <= tog; t2 <= t1;
        if (t1 ^ t2) begin              // this edge starts cycle 2
            ph <= 3'd2;
            en_c <= tx_en;              // MAC output, steady from ~0 ns to 40 ns
            txd_c <= txd;
        end else ph <= ph == 3'd4 ? 3'd0 : ph + 3'd1;
    end
    // An ODDR takes d0/d1 on a clk5 rising edge and shows d0 in that cycle's high half, d1
    // in its low half. The values set up during cycle p appear in cycle p+1:
    //   cycle 4: TXC 1,1   cycle 0: 1,1   cycle 1: 1,0   cycle 2: 0,0   cycle 3: 0,0
    wire txc_d0 = ph == 3'd3 || ph == 3'd4 || ph == 3'd0;
    wire txc_d1 = ph == 3'd3 || ph == 3'd4;
    EG_LOGIC_ODDR u_txc(.q(rgmii_txc), .clk(clk5), .d1(txc_d1), .d0(txc_d0), .rst(1'b0));
    // txd_c/en_c (loaded at the start of cycle 2) reach the pins at the start of cycle 3.
    // TX_CTL the same on both halves: TX_EN, and TX_EN ^ TX_ER = TX_EN (no error).
    EG_LOGIC_ODDR u_txctl(.q(rgmii_tx_ctl), .clk(clk5), .d1(en_c), .d0(en_c), .rst(1'b0));
    genvar i;
    generate for (i = 0; i < 4; i = i + 1) begin : g_txd
        EG_LOGIC_ODDR u_txd(.q(rgmii_txd[i]), .clk(clk5), .d1(txd_c[i]), .d0(txd_c[i]), .rst(1'b0));
    end endgenerate

    assign rxc = rgmii_rxc;
    reg rx_ctl_n;
    reg [3:0] rxd_n;
    always @(negedge rgmii_rxc) begin
        rx_ctl_n <= rgmii_rx_ctl;
        rxd_n <= rgmii_rxd;
    end
    assign rx_dv = rx_ctl_n;
    assign rxd = rxd_n;
endmodule
