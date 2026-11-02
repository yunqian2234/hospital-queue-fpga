`timescale 1ns/1ps
// V7-2 link self-test for a single board (no second board needed).
//
// Put one jumper from the link TX pin to the link RX pin on J2, compile with
// LOOPBACK_ENABLE=1, and the board drives its own link through the cable and checks what
// comes back. `disp` is 6 seven-segment digits (hex, active low, 0xff = blank):
//
//   E1 E2   frames sent         E3 E4   frames received with a good CRC
//   E5 E6   receive errors (bad CRC + wrong sync + bad length + UART framing)
//
// With the jumper in place, E3/E4 climbs alongside E1/E2 and E5/E6 stays 00. Pull the
// jumper out and E5/E6 starts climbing while E3/E4 freezes — the same link-loss detection
// the two-board build uses, shown without a second board.
module link_loopback_test #(
    parameter integer CLK_HZ = 25_000_000,
    parameter integer BAUD = 1_000_000,
    parameter integer PERIOD_FRAMES = 6,        // one frame every 6 video frames (~0.1 s)
    parameter integer LINK_TIMEOUT_CYCLES = 25_000_000,
    parameter integer MAX_LEN = 16
)(
    input wire clk, rst, frame_start,
    input wire enable,                          // 0: stop sending, hold the line idle
    input wire link_rx,
    output wire link_tx,
    output reg [47:0] disp,                     // {digit1..digit6}, see hex_digit below
    output reg link_up_led,
    // Raw counters, for the simulation bench and for a future on-screen readout.
    output wire [15:0] sent_count, ok_count, err_count
);
    reg [7:0] period, seq;
    wire [15:0] tx_frames;              // counted by the transmitter itself
    wire busy_tx, tx_valid, tx_ready;
    wire [7:0] tx_data;
    wire tx_line;

    wire rx_frame_valid, link_up;
    wire [7:0] r_type, r_seq;
    wire [4:0] r_len;
    wire [127:0] r_data;
    wire [15:0] frames_ok, crc_errors, sync_errors, length_errors, rx_errors;

    // Recognisable payload: d0..d14 = 0x11, 0x22, ... and d15 = the frame number.
    reg [127:0] data;
    always @* begin
        data = {8'hff, 8'hee, 8'hdd, 8'hcc, 8'hbb, 8'haa, 8'h99, 8'h88,
                8'h77, 8'h66, 8'h55, 8'h44, 8'h33, 8'h22, 8'h11, seq};
    end

    link_frame_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD), .MAX_LEN(MAX_LEN)) u_tx(
        .clk(clk), .rst(rst), .send(enable && frame_start && period == 0 && !busy_tx),
        .f_type(8'h7e), .f_seq(seq), .f_len(5'd16), .f_data(data),
        .tx_ready(tx_ready), .tx_valid(tx_valid), .tx_data(tx_data),
        .busy(busy_tx), .frames_sent(tx_frames));
    uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_uart(
        .clk(clk), .rst(rst), .valid(tx_valid), .data(tx_data),
        .ready(tx_ready), .tx(tx_line));
    assign link_tx = enable ? tx_line : 1'b1;   // idle high when the test is off

    link_frame_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD), .MAX_LEN(MAX_LEN),
                    .LINK_TIMEOUT_CYCLES(LINK_TIMEOUT_CYCLES)) u_rx(
        .clk(clk), .rst(rst), .rx(link_rx), .in_valid(1'b0), .in_data(8'd0),
        .frame_valid(rx_frame_valid),
        .f_type(r_type), .f_seq(r_seq), .f_len(r_len), .f_data(r_data),
        .link_up(link_up), .frames_ok(frames_ok), .crc_errors(crc_errors),
        .sync_errors(sync_errors), .length_errors(length_errors), .rx_errors(rx_errors));

    wire [15:0] errs = crc_errors + sync_errors + length_errors + rx_errors;
    assign sent_count = tx_frames;
    assign ok_count = frames_ok;
    assign err_count = errs;

    // Seven-segment patterns, active low, bit 7 = the decimal point (never lit here).
    function [7:0] hex_digit;
        input [3:0] v;
        begin
            case (v)
                4'h0: hex_digit = 8'hc0; 4'h1: hex_digit = 8'hf9; 4'h2: hex_digit = 8'ha4;
                4'h3: hex_digit = 8'hb0; 4'h4: hex_digit = 8'h99; 4'h5: hex_digit = 8'h92;
                4'h6: hex_digit = 8'h82; 4'h7: hex_digit = 8'hf8; 4'h8: hex_digit = 8'h80;
                4'h9: hex_digit = 8'h90; 4'ha: hex_digit = 8'h88; 4'hb: hex_digit = 8'h83;
                4'hc: hex_digit = 8'hc6; 4'hd: hex_digit = 8'ha1; 4'he: hex_digit = 8'h86;
                default: hex_digit = 8'h8e;
            endcase
        end
    endfunction

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            period <= 0; seq <= 0;
            disp <= 48'hffffff_ffff_ff; link_up_led <= 1'b0;
        end else begin
            if (frame_start) begin
                if (period == 0) begin
                    period <= PERIOD_FRAMES[7:0] - 8'd1;
                    // Only a frame that is actually queued counts: while the transmitter is
                    // still shifting the previous one out, the send request is ignored.
                    if (!busy_tx) seq <= seq + 1'b1;
                end else period <= period - 1'b1;
                disp <= {hex_digit(errs[3:0]),     hex_digit(errs[7:4]),
                         hex_digit(frames_ok[3:0]), hex_digit(frames_ok[7:4]),
                         hex_digit(tx_frames[3:0]), hex_digit(tx_frames[7:4])};
                link_up_led <= link_up;
            end
        end
    end
endmodule
