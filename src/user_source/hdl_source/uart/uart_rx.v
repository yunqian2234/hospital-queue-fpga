`timescale 1ns/1ps
// UART 8N1 receiver. Two-flop input synchroniser, start bit re-checked at mid-bit,
// data sampled at bit centres, stop bit must be high (else frame_error, byte dropped).
// After a framing error the receiver waits for the line to be idle (high) for one
// full character time before looking for the next start bit.
module uart_rx #(
    parameter integer CLK_HZ = 25_000_000,
    parameter integer BAUD = 9600
)(
    input wire clk, rst,
    input wire rx,
    output reg byte_valid,
    output reg [7:0] byte_data,
    output reg frame_error
);
    localparam integer DIV = (CLK_HZ + BAUD / 2) / BAUD;
    localparam integer HALF = DIV / 2;
    localparam [1:0] IDLE = 0, START = 1, DATA = 2, STOP = 3;
    reg s1, s2; /* synthesis keep */
    reg [1:0] state;
    // 10/26: counters sized for DIV (they never exceed DIV - 1 and 10 * DIV)
    localparam integer CW = DIV < 2 ? 1 : $clog2(DIV);
    localparam integer IW = $clog2(10 * DIV + 1);
    reg [CW-1:0] cnt;
    reg [2:0] bitn;
    reg [7:0] shift;
    reg [IW-1:0] idle_cnt;
    reg resync;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            s1 <= 1; s2 <= 1; state <= IDLE; cnt <= 0; bitn <= 0; shift <= 0;
            byte_valid <= 0; byte_data <= 0; frame_error <= 0; idle_cnt <= 0; resync <= 0;
        end else begin
            s1 <= rx; s2 <= s1;
            byte_valid <= 0; frame_error <= 0;
            case (state)
                IDLE: begin
                    if (resync) begin
                        if (!s2) idle_cnt <= 0;
                        else if (idle_cnt == 10 * DIV) resync <= 0;
                        else idle_cnt <= idle_cnt + 1'b1;
                    end else if (!s2) begin
                        state <= START; cnt <= 0;
                    end
                end
                START: begin
                    if (cnt == HALF - 1) begin
                        if (s2) state <= IDLE;              // glitch, not a start bit
                        else begin state <= DATA; cnt <= 0; bitn <= 0; end
                    end else cnt <= cnt + 1'b1;
                end
                DATA: begin
                    if (cnt == DIV - 1) begin
                        cnt <= 0; shift <= {s2, shift[7:1]};
                        if (bitn == 7) state <= STOP; else bitn <= bitn + 1'b1;
                    end else cnt <= cnt + 1'b1;
                end
                STOP: begin
                    if (cnt == DIV - 1) begin
                        state <= IDLE; cnt <= 0;
                        if (s2) begin byte_valid <= 1; byte_data <= shift; end
                        else begin frame_error <= 1; resync <= 1; idle_cnt <= 0; end
                    end else cnt <= cnt + 1'b1;
                end
            endcase
        end
    end
endmodule
