`timescale 1ns/1ps
// Ethernet receiver, 100 Mbps RGMII (V8 Ethernet link).
//
// rxc domain (the PHY's receive clock): rx_dv/rxd are the nibbles sampled by
// eth_rgmii_io. A frame is accepted when
//   preamble (one or more 5) + D | >= 64 bytes | even nibble count | FCS residue OK |
//   EtherType 88B5 | payload starts with a well-formed link frame header (A5, len <= 16)
//   | the link frame (len + 5 bytes) fits in RX_BYTES and in the payload
// Its link frame bytes are stored in a small buffer while it arrives; the buffer is locked
// from the moment a good frame is published until the clk side has read it. A frame that
// starts while the buffer is locked is not stored (counted as dropped); with frames at
// most every few microseconds and a read that takes about a microsecond, that only
// happens under deliberate flooding.
//
// clk domain (video_clk): a publish toggle (two-flop synchronised) starts a replay of the
// stored bytes, one per clock, into link_frame_rx (BYTE_INPUT mode), which re-checks the
// link frame's own CRC-8 and does everything it did with the UART link. The buffer and
// its length are stable from before the toggle until the acknowledge toggle returns, so
// they cross without per-bit synchronisers (see the timing constraints).
//
// Event counts kept in the clk domain via toggles: good frames delivered, bad frames
// (FCS / alignment / runt, any EtherType), frames dropped because the buffer was busy.
// Frames for other EtherTypes with a good FCS (e.g. a PC's own traffic through a switch)
// are ignored and not counted as errors.
module eth_mac_rx #(
    parameter integer RX_BYTES = 24,            // largest link frame stored (16 data + 5)
    parameter integer MAX_LEN = 16
)(
    // rxc domain
    input wire rxc, rxc_rst,
    input wire rx_dv,
    input wire [3:0] rxd,
    // clk domain
    input wire clk, rst,
    output reg out_valid,
    output reg [7:0] out_data,
    output reg [15:0] frames_ok,
    output reg [15:0] frames_bad,
    output reg [15:0] frames_dropped
);
    localparam [1:0] S_IDLE = 0, S_PRE = 1, S_DATA = 2, S_DROP = 3;
    localparam [31:0] RESIDUE = 32'hDEBB20E3;

    // =============================== rxc domain ===============================
    reg [1:0] state;
    reg hi;
    reg [3:0] lo;
    reg [10:0] nbytes;                          // bytes so far, saturating
    reg [31:0] crc;
    reg type_hi_ok, type_ok, magic_ok, len_ok, store;
    reg [4:0] want;                             // link frame bytes (len + 5)
    reg [7:0] buffer [0:RX_BYTES-1];
    reg [4:0] pub_len;
    reg locked;
    reg pub_t, bad_t, drop_t;                   // event toggles to the clk domain
    reg ack_s0, ack_s1, ack_s2;                 // acknowledge from the clk domain
    reg ack_t;                                  // (clk domain, declared here for the sync)

    wire [31:0] crc_next;
    eth_crc32_nibble u_crc(.crc_in(crc), .data(rxd), .crc_out(crc_next));
    wire [7:0] byte_in = {rxd, lo};
    wire [10:0] pay_idx = nbytes - 11'd14;      // payload byte index when nbytes >= 14
    // Frame complete (rx_dv low) and everything checks out.
    wire frame_good = !hi && nbytes >= 11'd64 && crc == RESIDUE && type_ok && magic_ok &&
                      len_ok && {6'd0, want} <= nbytes - 11'd18;

    always @(posedge rxc or posedge rxc_rst) begin
        if (rxc_rst) begin
            state <= S_IDLE; hi <= 0; lo <= 0; nbytes <= 0; crc <= 32'hFFFFFFFF;
            type_hi_ok <= 0; type_ok <= 0; magic_ok <= 0; len_ok <= 0; store <= 0; want <= 0;
            pub_len <= 0; locked <= 0; pub_t <= 0; bad_t <= 0; drop_t <= 0;
            ack_s0 <= 0; ack_s1 <= 0; ack_s2 <= 0;
        end else begin
            ack_s0 <= ack_t; ack_s1 <= ack_s0; ack_s2 <= ack_s1;
            if (ack_s2 != ack_s1) locked <= 0;
            case (state)
                S_IDLE: if (rx_dv && rxd == 4'h5) state <= S_PRE;
                S_PRE: begin
                    if (!rx_dv) state <= S_IDLE;
                    else if (rxd == 4'hD) begin
                        state <= S_DATA; hi <= 0; nbytes <= 0; crc <= 32'hFFFFFFFF;
                        type_hi_ok <= 0; type_ok <= 0; magic_ok <= 0; len_ok <= 0; want <= 0;
                        // The buffer is only written if it is free when the frame starts.
                        store <= !locked || ack_s2 != ack_s1;
                    end else if (rxd != 4'h5) state <= S_DROP;
                end
                S_DATA: begin
                    if (!rx_dv) begin
                        state <= S_IDLE;
                        if (frame_good) begin
                            if (store) begin
                                locked <= 1'b1; pub_len <= want; pub_t <= ~pub_t;
                            end else drop_t <= ~drop_t;
                        end else if (!(hi == 0 && nbytes >= 11'd64 && crc == RESIDUE))
                            bad_t <= ~bad_t;        // damaged frame (any EtherType)
                    end else begin
                        crc <= crc_next;
                        hi <= ~hi;
                        if (!hi) lo <= rxd;
                        else begin
                            if (nbytes != 11'h7FF) nbytes <= nbytes + 1'b1;
                            if (nbytes == 11'd12) type_hi_ok <= byte_in == 8'h88;
                            if (nbytes == 11'd13) type_ok <= type_hi_ok && byte_in == 8'hB5;
                            if (nbytes == 11'd14) magic_ok <= byte_in == 8'hA5;
                            if (nbytes == 11'd17) begin
                                len_ok <= byte_in <= MAX_LEN && byte_in + 8'd5 <= RX_BYTES;
                                want <= byte_in[4:0] + 5'd5;
                            end
                            if (store && nbytes >= 11'd14 && pay_idx < RX_BYTES)
                                buffer[pay_idx[4:0]] <= byte_in;
                        end
                    end
                end
                default: if (!rx_dv) state <= S_IDLE;     // S_DROP: wait for the frame end
            endcase
        end
    end

    // =============================== clk domain ===============================
    reg pub_s0, pub_s1, pub_s2, bad_s0, bad_s1, bad_s2, drop_s0, drop_s1, drop_s2;
    reg replay;
    reg [4:0] idx, len_q;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            pub_s0 <= 0; pub_s1 <= 0; pub_s2 <= 0; bad_s0 <= 0; bad_s1 <= 0; bad_s2 <= 0;
            drop_s0 <= 0; drop_s1 <= 0; drop_s2 <= 0;
            replay <= 0; idx <= 0; len_q <= 0; ack_t <= 0;
            out_valid <= 0; out_data <= 0; frames_ok <= 0; frames_bad <= 0; frames_dropped <= 0;
        end else begin
            pub_s0 <= pub_t; pub_s1 <= pub_s0; pub_s2 <= pub_s1;
            bad_s0 <= bad_t; bad_s1 <= bad_s0; bad_s2 <= bad_s1;
            drop_s0 <= drop_t; drop_s1 <= drop_s0; drop_s2 <= drop_s1;
            if (bad_s2 != bad_s1) frames_bad <= frames_bad + 1'b1;
            if (drop_s2 != drop_s1) frames_dropped <= frames_dropped + 1'b1;
            out_valid <= 0;
            if (!replay) begin
                if (pub_s2 != pub_s1) begin
                    replay <= 1'b1; idx <= 0; len_q <= pub_len;
                    frames_ok <= frames_ok + 1'b1;
                end
            end else begin
                out_valid <= 1'b1; out_data <= buffer[idx];
                if (idx + 1'b1 == len_q) begin replay <= 0; ack_t <= ~ack_t; end
                else idx <= idx + 1'b1;
            end
        end
    end
endmodule
