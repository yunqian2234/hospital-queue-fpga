`timescale 1ns/1ps
// Board-to-board link over the boards' Ethernet ports (V8): the transport under the V7
// link frames, replacing the J2 UART wires.
//
// Byte interfaces (clk = 25 MHz video clock) match what link_frame_tx produces and what
// link_frame_rx (BYTE_INPUT=1) consumes, so the link layer above (sequence numbers,
// CRC-8, retries, heartbeat, link timeout) is the same code the UART link ran:
//   src_*  one link frame -> one Ethernet frame (eth_mac_tx)
//   out_*  the link frame of each good Ethernet frame, replayed byte by byte (eth_mac_rx)
// The PHY is configured and watched by eth_phy_ctrl; see there for the status codes.
module eth_link #(
    parameter [47:0] MAC_ADDR = 48'h02_00_00_00_00_01,
    parameter integer RX_BYTES = 24,
    parameter integer LOOPBACK = 0,                 // PHY loopback self-test (one board)
    parameter integer POWERUP_CYCLES = 5_000_000,
    parameter integer POLL_CYCLES = 1_250_000,
    parameter integer RETRY_CYCLES = 25_000_000,
    parameter integer MDC_HALF = 10
)(
    input wire clk, rst,
    input wire clk5,                                // 125 MHz from the same PLL as clk (RGMII TX)
    input wire src_valid,
    input wire [7:0] src_data,
    output wire src_ready,
    output wire out_valid,
    output wire [7:0] out_data,
    // board pins
    output wire eth_txc,
    output wire [3:0] eth_txd,
    output wire eth_tx_ctl,
    input wire eth_rxc,
    input wire [3:0] eth_rxd,
    input wire eth_rx_ctl,
    output wire eth_mdc,
    inout wire eth_mdio,
    // status (clk domain)
    output wire [3:0] phy_state,
    output wire [4:0] phy_addr,
    output wire phy_link_ok,
    output wire [15:0] frames_sent, frames_ok, frames_bad, frames_dropped
);
    wire tx_en;
    wire [3:0] txd;
    wire rxc, rx_dv;
    wire [3:0] rxd;
    eth_rgmii_io u_io(
        .clk(clk), .clk5(clk5), .tx_en(tx_en), .txd(txd),
        .rgmii_txc(eth_txc), .rgmii_txd(eth_txd), .rgmii_tx_ctl(eth_tx_ctl),
        .rgmii_rxc(eth_rxc), .rgmii_rxd(eth_rxd), .rgmii_rx_ctl(eth_rx_ctl),
        .rxc(rxc), .rx_dv(rx_dv), .rxd(rxd));

    eth_mac_tx #(.MAC_ADDR(MAC_ADDR)) u_tx(
        .clk(clk), .rst(rst), .src_valid(src_valid), .src_data(src_data), .src_ready(src_ready),
        .tx_en(tx_en), .txd(txd), .frames_sent(frames_sent));

    // Receive-clock reset: asserted with rst, released two RXC edges later. RXC only runs
    // while the PHY supplies it, which is all the receive side needs.
    reg rxc_rst0, rxc_rst;
    always @(posedge rxc or posedge rst)
        if (rst) begin rxc_rst0 <= 1'b1; rxc_rst <= 1'b1; end
        else begin rxc_rst0 <= 1'b0; rxc_rst <= rxc_rst0; end

    eth_mac_rx #(.RX_BYTES(RX_BYTES)) u_rx(
        .rxc(rxc), .rxc_rst(rxc_rst), .rx_dv(rx_dv), .rxd(rxd),
        .clk(clk), .rst(rst), .out_valid(out_valid), .out_data(out_data),
        .frames_ok(frames_ok), .frames_bad(frames_bad), .frames_dropped(frames_dropped));

    wire mdio_oe, mdio_out;
    assign eth_mdio = mdio_oe ? mdio_out : 1'bz;
    eth_phy_ctrl #(.POWERUP_CYCLES(POWERUP_CYCLES), .POLL_CYCLES(POLL_CYCLES),
                   .RETRY_CYCLES(RETRY_CYCLES), .MDC_HALF(MDC_HALF), .LOOPBACK(LOOPBACK)) u_phy(
        .clk(clk), .rst(rst), .mdc(eth_mdc), .mdio_oe(mdio_oe), .mdio_out(mdio_out),
        .mdio_in(eth_mdio), .state(phy_state), .phy_addr(phy_addr), .link_ok(phy_link_ok),
        .last_physr());
endmodule
