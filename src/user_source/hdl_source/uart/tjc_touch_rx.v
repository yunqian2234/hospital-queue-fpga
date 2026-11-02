`timescale 1ns/1ps
// TJC serial-screen touch link (video_clk domain).
// Screen -> FPGA: the HMI sends, from a button's release event,
//     printh 5A <cmd> <arg> <chk> FF FF FF        chk = 5A ^ cmd ^ arg
// with cmd, arg < 0x80 so that FF only appears in the terminator.
// Every other frame the screen emits (touch 0x65, startup 0x00/0x88, command
// results ...) also ends with FF FF FF and is simply discarded.
// A half frame is dropped after GAP_CYCLES without a byte, on a framing error,
// on overflow, and at reset. One accepted frame -> one cmd_valid pulse.
module tjc_touch_rx #(
    parameter integer CLK_HZ = 25_000_000,
    parameter integer BAUD = 9600,
    parameter integer GAP_CYCLES = 1_250_000      // 50 ms at 25 MHz
)(
    input wire clk, rst,
    input wire rx,
    output reg cmd_valid,
    output reg [6:0] cmd,
    output reg [6:0] arg,
    output reg [15:0] good_frames,
    output reg [15:0] bad_frames,               // checksum/shape errors on 5A frames
    output reg [15:0] other_frames,             // screen's own frames, ignored
    output reg [15:0] line_errors               // UART framing errors and gaps
);
    wire byte_valid, frame_error;
    wire [7:0] b;
    uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_rx(
        .clk(clk), .rst(rst), .rx(rx), .byte_valid(byte_valid), .byte_data(b), .frame_error(frame_error));

    reg [7:0] b0, b1, b2, b3;
    reg [3:0] n;          // bytes before the FF run, saturates at 15
    reg [1:0] ff_run;
    reg [$clog2(GAP_CYCLES)-1:0] gap;               // 10/26: never exceeds GAP_CYCLES - 1
    function [15:0] inc; input [15:0] v; inc = v == 16'hffff ? v : v + 1'b1; endfunction
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            b0 <= 0; b1 <= 0; b2 <= 0; b3 <= 0; n <= 0; ff_run <= 0; gap <= 0;
            cmd_valid <= 0; cmd <= 0; arg <= 0;
            good_frames <= 0; bad_frames <= 0; other_frames <= 0; line_errors <= 0;
        end else begin
            cmd_valid <= 0;
            if (frame_error) begin
                n <= 0; ff_run <= 0; gap <= 0; line_errors <= inc(line_errors);
            end else if (byte_valid) begin
                gap <= 0;
                if (b == 8'hff) begin
                    if (ff_run == 2'd2) begin
                        // terminator complete: decode what preceded it
                        ff_run <= 0; n <= 0;
                        if (n == 4 && b0 == 8'h5a) begin
                            if (!b1[7] && !b2[7] && b3 == (8'h5a ^ b1 ^ b2)) begin
                                cmd_valid <= 1; cmd <= b1[6:0]; arg <= b2[6:0];
                                good_frames <= inc(good_frames);
                            end else bad_frames <= inc(bad_frames);
                        end else other_frames <= inc(other_frames);
                    end else ff_run <= ff_run + 1'b1;
                end else begin
                    // an FF run shorter than three is payload (screen frames may carry FF)
                    if (ff_run != 0) n <= 4'd15;
                    else if (n != 4'd15) n <= n + 1'b1;
                    ff_run <= 0;
                    case (n)
                        4'd0: b0 <= b; 4'd1: b1 <= b; 4'd2: b2 <= b; 4'd3: b3 <= b;
                        default: ;
                    endcase
                end
            end else if (n != 0 || ff_run != 0) begin
                if (gap == GAP_CYCLES - 1) begin
                    n <= 0; ff_run <= 0; gap <= 0; line_errors <= inc(line_errors);
                end else gap <= gap + 1'b1;
            end
        end
    end
endmodule
