`timescale 1ns/1ps
// MDIO management master (IEEE 802.3 clause 22): one register read or write per `start`.
//
// Frame, MSB first, one bit per MDC period:
//   32 x '1' preamble | 01 start | op (10 read, 01 write) | phy addr[4:0] | reg addr[4:0]
//   | turnaround (write: 10, read: released) | data[15:0] (read: driven by the PHY)
// MDC = clk / (2*HALF). The master changes MDIO while MDC is low (setup and hold of half a
// period around the rising edge the PHY samples on). On a read the PHY drives each bit
// after an MDC rising edge (at most 300 ns later for the RTL8211E); the master samples it
// just before the next rising edge, almost a full period later. MDIO is released (high
// through the board pull-up) whenever no write is in progress; reading 0xFFFF therefore
// means "no PHY answered at this address".
module eth_mdio #(
    parameter integer HALF = 10                 // 25 MHz / 20 = 1.25 MHz MDC
)(
    input wire clk, rst,
    input wire start,
    input wire op_read,                         // 1 read, 0 write
    input wire [4:0] phy_addr, reg_addr,
    input wire [15:0] wdata,
    output reg busy,
    output reg done,                            // one-cycle pulse; rdata valid with it
    output reg [15:0] rdata,
    output reg mdc,
    output reg mdio_oe,
    output reg mdio_out,
    input wire mdio_in
);
    reg [31:0] frame;                           // everything after the preamble
    reg [6:0] bit_no;                           // 0..63; 0..31 is the preamble
    reg [7:0] phase;                            // 0..2*HALF-1 within a bit
    reg rd;
    reg in_s0, in_s1;                           // MDIO input synchroniser

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            busy <= 0; done <= 0; rdata <= 0; mdc <= 0; mdio_oe <= 0; mdio_out <= 1'b1;
            frame <= 0; bit_no <= 0; phase <= 0; rd <= 0; in_s0 <= 1'b1; in_s1 <= 1'b1;
        end else begin
            in_s0 <= mdio_in; in_s1 <= in_s0;
            done <= 0;
            if (!busy) begin
                mdc <= 0; mdio_oe <= 0; mdio_out <= 1'b1;
                if (start) begin
                    busy <= 1'b1; rd <= op_read; bit_no <= 0; phase <= 0;
                    frame <= {2'b01, op_read ? 2'b10 : 2'b01, phy_addr, reg_addr,
                              op_read ? 2'b11 : 2'b10, op_read ? 16'hFFFF : wdata};
                end
            end else begin
                if (phase == 0) begin
                    // MDC falls here; present the next bit. A read releases the line from
                    // the first turnaround bit (46) to the end; the PHY drives the second
                    // turnaround bit (0) and the data.
                    mdc <= 0;
                    mdio_out <= !bit_no[5] | frame[~bit_no[4:0]];   // bit 32 = frame[31]
                    mdio_oe <= !(rd && bit_no >= 7'd46);
                end
                if (phase == HALF - 1 && rd && bit_no >= 7'd48)
                    rdata <= {rdata[14:0], in_s1};
                if (phase == HALF) mdc <= 1'b1;
                if (phase == 2*HALF - 1) begin
                    phase <= 0;
                    if (bit_no == 7'd63) begin
                        busy <= 0; done <= 1'b1; mdc <= 0; mdio_oe <= 0;
                    end else bit_no <= bit_no + 1'b1;
                end else phase <= phase + 1'b1;
            end
        end
    end
endmodule
