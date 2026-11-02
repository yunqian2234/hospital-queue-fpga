`timescale 1ns/1ps
// UART 8N1 transmitter. Accepts a byte when ready; line idles high.
// 10/26 (hall board resources): the bit is taken from a shift register instead of an indexed
// 10:1 mux and the baud counter is just wide enough for DIV - same output, cycle for cycle
// (verification/touch_hmi/run_uart_equiv.py compares it with the previous version).
module uart_tx #(
    parameter integer CLK_HZ = 25_000_000,
    parameter integer BAUD = 9600
)(
    input wire clk, rst,
    input wire valid,
    input wire [7:0] data,
    output wire ready,
    output reg tx
);
    localparam integer DIV = (CLK_HZ + BAUD / 2) / BAUD;
    reg busy;
    localparam integer CW = DIV < 2 ? 1 : $clog2(DIV);
    reg [CW-1:0] cnt;
    reg [3:0] bitn;
    reg [9:0] shift;   // {stop, data[7:0], start}, LSB first
    assign ready = !busy && !rst;
    always @(posedge clk or posedge rst) begin
        if (rst) begin busy <= 0; cnt <= 0; bitn <= 0; shift <= 10'h3ff; tx <= 1; end
        else if (!busy) begin
            tx <= 1;
            if (valid) begin busy <= 1; shift <= {1'b1, data, 1'b0}; cnt <= 0; bitn <= 0; tx <= 0; end
        end else if (cnt == DIV - 1) begin
            cnt <= 0;
            if (bitn == 9) begin busy <= 0; tx <= 1; end
            else begin bitn <= bitn + 1'b1; tx <= shift[1]; shift <= {1'b1, shift[9:1]}; end
        end else cnt <= cnt + 1'b1;
    end
endmodule
