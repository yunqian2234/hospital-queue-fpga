`timescale 1ns/1ps
// Stage C voice dispatcher (video_clk domain). Standalone; NOT in the TD project yet.
// Takes one hospital_app_core event at a time, freezes it into a clip list, hands
// the list to the voice player through a two-phase toggle handshake, and retires
// the event only when the player answers with the same sequence number.
// Every outcome (played, skipped, no bank, read failure, timeout) retires the event
// so the business queue never stalls; the outcome is exported for the OSD.
//
// CDC contract: cmd_seq/cmd_count/cmd_clips change only in the same edge that flips
// cmd_toggle and then stay frozen until the matching response. The player must hold
// rsp_seq/rsp_status stable before flipping rsp_toggle. Both sides reset together.
module hospital_voice_dispatch #(
    parameter integer TIMEOUT_CYCLES = 500_000_000  // 20 s at 25 MHz
)(
    input  wire clk, rst,
    input  wire event_valid,
    input  wire [43:0] event_data,
    output wire event_ready,
    output reg  event_done,
    output reg  [15:0] event_done_seq,
    output reg  cmd_toggle,
    output reg  [15:0] cmd_seq,
    output reg  [2:0] cmd_count,
    output reg  [19:0] cmd_clips,   // clip i at [5*i +: 5], played in ascending i
    input  wire rsp_toggle,
    input  wire [15:0] rsp_seq,
    input  wire [2:0] rsp_status,
    output wire voice_busy,
    output reg  [2:0] last_status,
    output reg  [15:0] last_seq,
    output reg  degraded,
    output reg  protocol_error_sticky
);
    localparam [2:0] CALL=1, REPLAY=2, EXPRESSION=3, HELP=4, HELP_ACK=5;
    // Outcome codes shared with the player and the OSD.
    localparam [2:0] ST_OK=0, ST_SKIPPED=1, ST_NO_BANK=2, ST_READ_FAIL=3,
                     ST_TIMEOUT=4, ST_DEGRADED=5, ST_NONE=7;
    // Clip identifiers; must match 07_app_dev/tools/voice_bank.py CLIP_IDS.
    localparam [4:0] CLIP_CHIME=0, CLIP_PLEASE=1, CLIP_NUMBER_BASE=1,
                     CLIP_CALL_SUFFIX=22, CLIP_ROOM_BASE=23,   // 10/25: room r -> clip 23+r (to room r+1)
                     CLIP_HELP_ACK=30, CLIP_HELP_REQ=31;
    localparam [1:0] IDLE=0, WAIT=1, LOCAL_DONE=2;

    // {count[2:0], clip3, clip2, clip1, clip0}
    function [22:0] sentence;
        input [2:0] kind;
        input [4:0] number;
        input [2:0] card;
        begin
            sentence = 23'd0;
            case (kind)
                CALL, REPLAY:
                    if (number >= 5'd1 && number <= 5'd20)
                        // card field = room (0..3): chime, please, number, "to room X"
                        sentence = {3'd4, CLIP_ROOM_BASE + {3'd0, card[1:0]}, CLIP_NUMBER_BASE + number,
                                    CLIP_PLEASE, CLIP_CHIME};
                HELP:     sentence = {3'd2, 10'd0, CLIP_HELP_REQ, CLIP_CHIME};
                HELP_ACK: sentence = {3'd1, 15'd0, CLIP_HELP_ACK};
                default:  sentence = 23'd0;
            endcase
        end
    endfunction

    reg [1:0] state;
    reg [2:0] local_status;
    reg [31:0] timer;
    reg rsp_sync1, rsp_sync2, rsp_seen;
    wire rsp_edge = rsp_sync2 ^ rsp_seen;
    wire [22:0] mapped = sentence(event_data[27:25], event_data[23:19], event_data[18:16]);
    wire accept = event_valid && event_ready;

    assign event_ready = !rst && state == IDLE;
    assign voice_busy = state != IDLE;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= IDLE; local_status <= ST_NONE; timer <= 0;
            event_done <= 0; event_done_seq <= 0;
            cmd_toggle <= 0; cmd_seq <= 0; cmd_count <= 0; cmd_clips <= 0;
            rsp_sync1 <= 0; rsp_sync2 <= 0; rsp_seen <= 0;
            last_status <= ST_NONE; last_seq <= 0;
            degraded <= 0; protocol_error_sticky <= 0;
        end else begin
            event_done <= 0;
            rsp_sync1 <= rsp_toggle; rsp_sync2 <= rsp_sync1;
            if (rsp_edge) rsp_seen <= rsp_sync2;
            case (state)
                IDLE: begin
                    // A response without an outstanding command is only expected
                    // as the late answer to a command that already timed out.
                    if (rsp_edge && !degraded) protocol_error_sticky <= 1;
                    if (accept) begin
                        if (degraded) begin
                            local_status <= ST_DEGRADED; state <= LOCAL_DONE;
                        end else if (mapped[22:20] == 3'd0) begin
                            local_status <= ST_SKIPPED; state <= LOCAL_DONE;
                        end else begin
                            cmd_seq <= event_data[43:28];
                            cmd_count <= mapped[22:20];
                            cmd_clips <= mapped[19:0];
                            cmd_toggle <= ~cmd_toggle;
                            timer <= 0;
                            state <= WAIT;
                        end
                        event_done_seq <= event_data[43:28];
                    end
                end
                WAIT: begin
                    timer <= timer + 1'b1;
                    if (rsp_edge && rsp_seq == cmd_seq) begin
                        event_done <= 1;
                        last_seq <= cmd_seq;
                        if (rsp_status <= ST_READ_FAIL) last_status <= rsp_status;
                        else begin last_status <= ST_READ_FAIL; protocol_error_sticky <= 1; end
                        state <= IDLE;
                    end else begin
                        if (rsp_edge) protocol_error_sticky <= 1;
                        if (timer == TIMEOUT_CYCLES - 1) begin
                            event_done <= 1;
                            last_seq <= cmd_seq;
                            last_status <= ST_TIMEOUT;
                            degraded <= 1;
                            state <= IDLE;
                        end
                    end
                end
                LOCAL_DONE: begin
                    if (rsp_edge && !degraded) protocol_error_sticky <= 1;
                    event_done <= 1;
                    last_seq <= event_done_seq;
                    last_status <= local_status;
                    state <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
