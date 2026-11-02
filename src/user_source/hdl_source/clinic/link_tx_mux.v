`timescale 1ns/1ps
// 10/25 dual-room clinic board: two room link endpoints share one eth_link transmitter.
//
// Frame-granular arbitration: a source keeps the port from its first valid byte until its
// tx_valid drops (link_frame_tx holds valid for a whole frame). After a frame the port stays
// idle for one clock, so eth_mac_tx sees src_valid low and closes its Ethernet frame (it ends a
// frame at the first low src_valid) - two link frames never share one Ethernet frame. Ties go
// to the other source than the last owner, so neither room can starve the other.
module link_tx_mux (
    input wire clk, rst,
    input wire a_valid, input wire [7:0] a_data, output wire a_ready,
    input wire b_valid, input wire [7:0] b_data, output wire b_ready,
    output wire out_valid, output wire [7:0] out_data, input wire out_ready
);
    reg busy, owner, last;              // owner 0 = a, 1 = b
    wire cur_valid = owner ? b_valid : a_valid;
    always @(posedge clk or posedge rst) begin
        if (rst) begin busy <= 0; owner <= 0; last <= 1; end
        else if (busy) begin
            if (!cur_valid) begin busy <= 0; last <= owner; end      // frame done: one idle clock
        end else if (a_valid || b_valid) begin
            busy <= 1;
            owner <= a_valid && b_valid ? ~last : b_valid;
        end
    end
    assign out_valid = busy && cur_valid;
    assign out_data = owner ? b_data : a_data;
    assign a_ready = busy && !owner && out_ready;
    assign b_ready = busy && owner && out_ready;
endmodule
