`timescale 1ns/1ps
// RTL8211E management for a 100 Mbps link (V8 Ethernet link).
//
// The board's RTL8211E is a gigabit PHY whose reset and strap pins are not under FPGA
// control, so everything is set over MDIO after power-up:
//   1. wait POWERUP_CYCLES (the PHY's own power-on reset is an RC on the board);
//   2. find the PHY: read register 2 (PHY ID 1) at addresses 0..31 until one answers
//      0x001C (Realtek); nothing answering -> state F, rescan after RETRY_CYCLES;
//   3. register 9 = 0x0000   do not advertise 1000BASE-T (two of these PHYs on one cable
//                            would otherwise agree on gigabit, which this MAC does not run);
//      register 4 = 0x0181   advertise 100BASE-TX full and half duplex only;
//      register 0 = 0x1200   auto-negotiation on, restart it
//      (LOOPBACK=1 instead writes register 0 = 0x6100: PHY loopback, 100 Mbps, full duplex,
//       auto-negotiation off, for a one-board test without a cable);
//   4. every POLL_CYCLES read register 17 (PHYSR): bit 10 real-time link, bits 15:14 speed
//      (01 = 100 Mbps), bit 13 full duplex. A read of 0xFFFF means the PHY stopped answering:
//      go back to step 2.
//
// state (shown on the seven-segment display):
//   0 power-up wait   1 searching   2 configuring   3 no link (cable / partner / negotiating)
//   4 link up, 100 Mbps full duplex   5 link up at another speed/duplex (not usable)
//   6 PHY loopback test mode   F no PHY answered on MDIO
module eth_phy_ctrl #(
    parameter integer POWERUP_CYCLES = 5_000_000,   // 200 ms at 25 MHz
    parameter integer POLL_CYCLES = 1_250_000,      // 50 ms
    parameter integer RETRY_CYCLES = 25_000_000,    // 1 s
    parameter integer MDC_HALF = 10,
    parameter integer LOOPBACK = 0
)(
    input wire clk, rst,
    output wire mdc,
    output wire mdio_oe,
    output wire mdio_out,
    input wire mdio_in,
    output reg [3:0] state,
    output reg [4:0] phy_addr,
    output wire link_ok,                            // state 4 (or 6 in loopback mode)
    output reg [15:0] last_physr
);
    localparam [3:0] ST_WAIT = 4'h0, ST_SCAN = 4'h1, ST_CFG = 4'h2, ST_DOWN = 4'h3,
                     ST_UP = 4'h4, ST_ODD = 4'h5, ST_LOOP = 4'h6, ST_NONE = 4'hF;
    localparam [15:0] REALTEK_ID1 = 16'h001C;

    reg start, op_read;
    reg [4:0] reg_addr;
    reg [15:0] wdata;
    wire busy, done;
    wire [15:0] rdata;
    eth_mdio #(.HALF(MDC_HALF)) u_mdio(
        .clk(clk), .rst(rst), .start(start), .op_read(op_read), .phy_addr(phy_addr),
        .reg_addr(reg_addr), .wdata(wdata), .busy(busy), .done(done), .rdata(rdata),
        .mdc(mdc), .mdio_oe(mdio_oe), .mdio_out(mdio_out), .mdio_in(mdio_in));

    reg [24:0] timer;
    reg [1:0] step;                                 // configuration write 0..2
    reg waiting;                                    // an MDIO transaction is in flight
    assign link_ok = state == ST_UP || state == ST_LOOP;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= ST_WAIT; phy_addr <= 0; last_physr <= 0;
            start <= 0; op_read <= 0; reg_addr <= 0; wdata <= 0;
            timer <= 0; step <= 0; waiting <= 0;
        end else begin
            start <= 0;
            if (timer != 0) timer <= timer - 1'b1;
            if (waiting) begin
                if (done) begin
                    waiting <= 0;
                    case (state)
                        ST_SCAN: begin
                            if (rdata == REALTEK_ID1) begin state <= ST_CFG; step <= 0; end
                            else if (phy_addr == 5'd31) begin
                                state <= ST_NONE; phy_addr <= 0; timer <= RETRY_CYCLES[24:0];
                            end else phy_addr <= phy_addr + 1'b1;
                        end
                        ST_CFG: begin
                            if (step == 2'd2) begin
                                state <= LOOPBACK != 0 ? ST_LOOP : ST_DOWN; timer <= 0;
                            end else step <= step + 1'b1;
                        end
                        default: begin                  // PHYSR poll
                            last_physr <= rdata;
                            timer <= POLL_CYCLES[24:0];
                            if (rdata == 16'hFFFF) begin state <= ST_SCAN; phy_addr <= 0; end
                            else if (!rdata[10]) state <= ST_DOWN;
                            else if (rdata[15:14] == 2'b01 && rdata[13]) state <= ST_UP;
                            else state <= ST_ODD;
                        end
                    endcase
                end
            end else if (!busy && !start) begin
                case (state)
                    ST_WAIT: if (timer == 0) begin
                        // Reset loads the counter to 0, so the wait is armed on the first pass.
                        if (step == 2'd0) begin timer <= POWERUP_CYCLES[24:0]; step <= 2'd1; end
                        else begin state <= ST_SCAN; step <= 0; end
                    end
                    ST_NONE: if (timer == 0) state <= ST_SCAN;
                    ST_SCAN: begin
                        start <= 1'b1; waiting <= 1'b1; op_read <= 1'b1; reg_addr <= 5'd2;
                    end
                    ST_CFG: begin
                        start <= 1'b1; waiting <= 1'b1; op_read <= 1'b0;
                        case (step)
                            2'd0: begin reg_addr <= 5'd9; wdata <= 16'h0000; end
                            2'd1: begin reg_addr <= 5'd4; wdata <= 16'h0181; end
                            default: begin
                                reg_addr <= 5'd0; wdata <= LOOPBACK != 0 ? 16'h6100 : 16'h1200;
                            end
                        endcase
                    end
                    ST_LOOP: ;                          // nothing to poll in loopback mode
                    default: if (timer == 0) begin      // ST_DOWN / ST_UP / ST_ODD: poll
                        start <= 1'b1; waiting <= 1'b1; op_read <= 1'b1; reg_addr <= 5'd17;
                    end
                endcase
            end
        end
    end
endmodule
