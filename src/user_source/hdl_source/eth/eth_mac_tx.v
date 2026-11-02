`timescale 1ns/1ps
// Ethernet transmitter, 100 Mbps RGMII, one nibble per 25 MHz clock (V8 Ethernet link).
//
// Wraps one board-link frame (the byte stream of link_frame_tx) in an Ethernet II frame:
//   preamble 55x7, SFD D5 | dst FF:FF:FF:FF:FF:FF | src MAC_ADDR | EtherType 88B5 |
//   payload: the link frame bytes, zero-padded to 46 | FCS (CRC-32)
// 0x88B5 is the IEEE "local experimental" EtherType: nothing else on a LAN uses it, and a
// PC running Wireshark shows each frame with the link frame (A5 type seq len ...) at the
// start of the payload. The destination is broadcast so a switch delivers it everywhere.
//
// Byte source handshake (link_frame_tx): src_valid is high while a frame is pending and
// src_data is its current byte; src_ready accepts it. A frame ends at the first cycle
// src_valid is low after it started, so a link frame queued right after the previous one
// goes into the next Ethernet frame, never into the padding of this one. Link frames are
// at most 21 bytes, well under the 46-byte minimum payload.
//
// Nibble order is low nibble first; tx_en is high from the first preamble nibble to the
// last FCS nibble; at least IFG_NIBBLES idle nibbles (96 bit times = 24) separate frames.
module eth_mac_tx #(
    parameter [47:0] MAC_ADDR = 48'h02_00_00_00_00_01,
    parameter integer IFG_NIBBLES = 24
)(
    input wire clk, rst,
    input wire src_valid,
    input wire [7:0] src_data,
    output wire src_ready,
    output reg tx_en,
    output reg [3:0] txd,
    output reg [15:0] frames_sent
);
    localparam [2:0] S_IDLE = 0, S_PRE = 1, S_HDR = 2, S_PAY = 3, S_FCS = 4, S_GAP = 5;
    localparam [15:0] ETHERTYPE = 16'h88B5;
    localparam integer PAY_BYTES = 46;

    reg [2:0] state;
    reg [6:0] n;                // nibble index inside the current section
    reg hi;                     // 0: low nibble of the byte, 1: high nibble
    reg [7:0] cur;              // byte being sent (its high nibble goes out next)
    reg active;                 // the link frame is still supplying bytes
    reg [31:0] crc;

    wire [5:0] byte_no = n[6:1];
    // Header byte 0..13.
    reg [7:0] hdr_byte;
    always @* begin
        case (byte_no)
            6'd6:  hdr_byte = MAC_ADDR[47:40];
            6'd7:  hdr_byte = MAC_ADDR[39:32];
            6'd8:  hdr_byte = MAC_ADDR[31:24];
            6'd9:  hdr_byte = MAC_ADDR[23:16];
            6'd10: hdr_byte = MAC_ADDR[15:8];
            6'd11: hdr_byte = MAC_ADDR[7:0];
            6'd12: hdr_byte = ETHERTYPE[15:8];
            6'd13: hdr_byte = ETHERTYPE[7:0];
            default: hdr_byte = 8'hFF;              // 0..5 broadcast destination
        endcase
    end
    // A payload byte is taken from the source on its low-nibble cycle.
    wire take = state == S_PAY && !hi && active && src_valid;
    assign src_ready = take;
    wire [7:0] pay_byte = take ? src_data : 8'h00;

    // Nibble on the wire this cycle (registered into txd below).
    reg [3:0] nib;
    always @* begin
        case (state)
            S_PRE:   nib = n == 7'd15 ? 4'hD : 4'h5;
            S_HDR:   nib = hi ? cur[7:4] : hdr_byte[3:0];
            S_PAY:   nib = hi ? cur[7:4] : pay_byte[3:0];
            S_FCS:   nib = ~crc[3:0];
            default: nib = 4'h0;
        endcase
    end
    wire [31:0] crc_next;
    eth_crc32_nibble u_crc(.crc_in(crc), .data(nib), .crc_out(crc_next));

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= S_IDLE; n <= 0; hi <= 0; cur <= 0; active <= 0; crc <= 32'hFFFFFFFF;
            tx_en <= 0; txd <= 0; frames_sent <= 0;
        end else begin
            txd <= nib;
            tx_en <= state == S_PRE || state == S_HDR || state == S_PAY || state == S_FCS;
            // Once the source drops valid the link frame is complete.
            if (active && !src_valid && state == S_PAY) active <= 0;
            case (state)
                S_IDLE: if (src_valid) begin
                    state <= S_PRE; n <= 0; active <= 1'b1;
                end
                S_PRE: begin
                    if (n == 7'd15) begin state <= S_HDR; n <= 0; hi <= 0; crc <= 32'hFFFFFFFF; end
                    else n <= n + 1'b1;
                end
                S_HDR: begin
                    crc <= crc_next;
                    if (!hi) cur <= hdr_byte;
                    hi <= ~hi;
                    if (n == 7'd27) begin state <= S_PAY; n <= 0; end
                    else n <= n + 1'b1;
                end
                S_PAY: begin
                    crc <= crc_next;
                    if (!hi) begin
                        cur <= pay_byte;
                        if (!take) active <= 0;     // padding from here on
                    end
                    hi <= ~hi;
                    if (n == PAY_BYTES * 2 - 1) begin state <= S_FCS; n <= 0; end
                    else n <= n + 1'b1;
                end
                S_FCS: begin
                    crc <= {4'hF, crc[31:4]};       // shift the next FCS nibble down
                    if (n == 7'd7) begin
                        state <= S_GAP; n <= 0; frames_sent <= frames_sent + 1'b1;
                    end else n <= n + 1'b1;
                end
                S_GAP: begin
                    if (n == IFG_NIBBLES - 1) begin state <= S_IDLE; n <= 0; end
                    else n <= n + 1'b1;
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
