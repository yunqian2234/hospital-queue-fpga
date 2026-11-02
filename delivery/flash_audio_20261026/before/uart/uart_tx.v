`timescale 1ns/1ps
// UART 8N1 transmitter. Accepts a byte when ready; line idles high.
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
    reg [15:0] cnt;
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
            else begin bitn <= bitn + 1'b1; tx <= shift[bitn + 1'b1]; end
        end else cnt <= cnt + 1'b1;
    end
endmodule
