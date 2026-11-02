`timescale 1ns/1ps
// Board-to-board link: frame receiver (V7-2).
//
// Accepts  A5 <type> <seq> <len> <data0..data(len-1)> <crc8>  and reports a one-cycle
// `frame_valid` with the fields captured. Anything that does not match is counted, never
// acted on: wrong sync, bad length, bad CRC. After a bad CRC the parser goes back to
// hunting for the sync byte, so one corrupted frame cannot swallow the next one.
//
// `link_up` drops when no valid frame has arrived for LINK_TIMEOUT_CYCLES, which is how
// both boards detect an unplugged or dead cable. `rx_errors` counts framing errors from
// uart_rx (a broken byte, e.g. from a wrong baud rate or a glitch on the wire).
//
// BYTE_INPUT=1 (V8 Ethernet link): the bytes come from eth_mac_rx on in_valid/in_data
// instead of the serial pin, and no uart_rx is built; rx is then unused. The parser,
// counters and link timeout are the same in both modes.
module link_frame_rx #(
    parameter integer CLK_HZ = 25_000_000,
    parameter integer BAUD = 1_000_000,
    parameter integer MAX_LEN = 16,
    parameter integer LINK_TIMEOUT_CYCLES = 25_000_000,  // 1 s at 25 MHz
    parameter integer BYTE_INPUT = 0
)(
    input wire clk, rst,
    input wire rx,
    input wire in_valid,                // BYTE_INPUT=1 only
    input wire [7:0] in_data,
    output reg frame_valid,
    output reg [7:0] f_type,
    output reg [7:0] f_seq,
    output reg [4:0] f_len,
    output reg [MAX_LEN*8-1:0] f_data,
    output wire link_up,
    output reg [15:0] frames_ok,
    output reg [15:0] crc_errors,
    output reg [15:0] sync_errors,
    output reg [15:0] length_errors,
    output reg [15:0] rx_errors
);
    localparam [7:0] SYNC = 8'hA5;
    localparam [2:0] S_SYNC = 0, S_TYPE = 1, S_SEQ = 2, S_LEN = 3, S_DATA = 4, S_CRC = 5;

    wire byte_valid, frame_error;
    wire [7:0] byte_data;
    generate if (BYTE_INPUT != 0) begin : g_bytes
        assign byte_valid = in_valid;
        assign byte_data = in_data;
        assign frame_error = 1'b0;
    end else begin : g_uart
        uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_rx(
            .clk(clk), .rst(rst), .rx(rx), .byte_valid(byte_valid),
            .byte_data(byte_data), .frame_error(frame_error));
    end endgenerate

    reg [2:0] state;
    reg [7:0] type_q, seq_q, crc_q;
    reg [4:0] len_q, di;
    reg [MAX_LEN*8-1:0] data_q;
    reg [24:0] idle_timer;
    reg seen_any;

    wire [7:0] crc_next;
    link_crc8_update u_crc(.crc_in(crc_q), .data(byte_data), .crc_out(crc_next));
    wire [7:0] rx_len = byte_data[4:0];

    assign link_up = seen_any && idle_timer < LINK_TIMEOUT_CYCLES;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= S_SYNC; frame_valid <= 0; f_type <= 0; f_seq <= 0; f_len <= 0; f_data <= 0;
            type_q <= 0; seq_q <= 0; len_q <= 0; crc_q <= 0; di <= 0; data_q <= 0;
            frames_ok <= 0; crc_errors <= 0; sync_errors <= 0; length_errors <= 0; rx_errors <= 0;
            idle_timer <= 0; seen_any <= 0;
        end else begin
            frame_valid <= 0;
            // Idle counter: a valid frame reloads it; it saturates at the timeout value.
            if (frame_valid) idle_timer <= 0;
            else if (idle_timer < LINK_TIMEOUT_CYCLES) idle_timer <= idle_timer + 1'b1;

            if (frame_error) rx_errors <= rx_errors + 1'b1;
            if (byte_valid) begin
                case (state)
                    S_SYNC: begin
                        if (byte_data == SYNC) begin state <= S_TYPE; crc_q <= 8'h00; end
                        else sync_errors <= sync_errors + 1'b1;
                    end
                    S_TYPE: begin
                        type_q <= byte_data; crc_q <= crc_next; state <= S_SEQ;
                    end
                    S_SEQ: begin seq_q <= byte_data; crc_q <= crc_next; state <= S_LEN; end
                    S_LEN: begin
                        crc_q <= crc_next;
                        if (rx_len > MAX_LEN[4:0]) begin
                            length_errors <= length_errors + 1'b1;
                            state <= S_SYNC;
                        end else begin
                            len_q <= rx_len; di <= 0; state <= rx_len == 0 ? S_CRC : S_DATA;
                        end
                    end
                    S_DATA: begin
                        data_q[{di[3:0], 3'b000} +: 8] <= byte_data;
                        crc_q <= crc_next;
                        if (di + 1'b1 == len_q) state <= S_CRC;
                        else di <= di + 1'b1;
                    end
                    S_CRC: begin
                        state <= S_SYNC;
                        if (byte_data == crc_q) begin
                            frame_valid <= 1'b1;
                            f_type <= type_q; f_seq <= seq_q; f_len <= len_q; f_data <= data_q;
                            frames_ok <= frames_ok + 1'b1;
                        end else crc_errors <= crc_errors + 1'b1;
                    end
                    default: state <= S_SYNC;
                endcase
            end
            if (frame_valid) seen_any <= 1;
        end
    end
endmodule
