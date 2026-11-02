`timescale 1ns/1ps
// Clinic board need-card sequencer (10/25 trigger, reworked 10/30: ALL needs, one after the other).
//
// When a room's newly called patient has check-in communication needs, clinic_card_view zooms the
// card of EVERY registered need in turn (bit order: 0 听力差 1 说话困难 2 头晕需搀扶 3 需翻译), each for
// the view's full hold time, with "需求 i/n" in the zoom title (idx / total).
//
// Event: a room's registration arrives one status / registration frame pair after its new patient
// (clinic_link drops record_ok for a new number and sets it again when the matching record
// arrives); the rising edge of record_ok is the event. Nothing registered (12'h0FF) or no needs:
// nothing. Room B only counts in dual-room mode.
//
// Snapshot: an event becomes a job {room, number, needs}; the room / number / idx / total outputs
// only change when the next card is issued, i.e. while the view is idle - a card on screen always
// shows the patient it was issued for, whatever arrives meanwhile.
// Jobs: one active job plus one waiting job per column (A, B). A new patient in a column replaces
// that column's waiting job (the older patient is no longer that room's patient). If the ACTIVE job
// belongs to that column, its remaining cards are dropped (the card on screen finishes). An event
// for the patient the active or waiting job already has is ignored (no repeat). After the active job,
// waiting A goes first, then B.
// Issue: with the view idle, the next card of the active job is issued (card + clicks + 1; the view
// zooms a changed click count). The card counts as shown when the view reports a natural end of its
// hold (zoom_full) for that card; if it was cut short (a help request zooms over it), it is shown
// again once - a second interruption skips it, so a sequence never repeats without end. If the view
// does not start within START_FRAMES (not armed yet), the card is issued again.
// Mode switch (dual or the room switch) or link down: all jobs are dropped (the card on screen
// finishes with its frozen title).
// All updates at frame_start; the view's outputs are its registered state (one frame behind).
module clinic_need_trigger #(
    parameter integer START_FRAMES = 6
)(
    input wire clk, rst, frame_start,
    input wire dual, link_up,
    input wire [1:0] room_a, room_b,
    input wire [4:0] a_number, b_number,
    input wire [11:0] a_record, b_record,
    input wire a_record_ok, b_record_ok,
    // clinic_card_view state
    input wire zoom_active, zoom_full,
    input wire [2:0] zoom_card,
    // to clinic_card_view / clinic_screen
    output reg [2:0] card,
    output reg valid,
    output reg [7:0] clicks,
    output reg [1:0] room,
    output reg [4:0] number,
    output reg [2:0] idx, total         // "需求 idx/total" of the card issued last
);
    function [1:0] first_need; input [3:0] n;
        begin first_need = n[0] ? 2'd0 : n[1] ? 2'd1 : n[2] ? 2'd2 : 2'd3; end
    endfunction
    function [2:0] count; input [3:0] n;
        begin count = n[0] + n[1] + n[2] + n[3]; end
    endfunction
    localparam [1:0] Q_IDLE = 0, Q_START = 1, Q_SHOW = 2;
    reg a_ok_q, b_ok_q;
    reg [2:0] mode_q;
    // active job
    reg act_v, act_side, act_stop, act_retry, act_done;
    reg [1:0] act_room, act_cur;
    reg [4:0] act_num;
    reg [3:0] act_rem;
    reg [2:0] act_idx, act_total;
    // waiting jobs
    reg pa_v, pb_v;
    reg [1:0] pa_room, pb_room;
    reg [4:0] pa_num, pb_num;
    reg [3:0] pa_needs, pb_needs;
    reg [1:0] q;
    reg [3:0] wait_n;
    wire a_new = a_record_ok && !a_ok_q && a_number != 0 && a_record != 12'h0FF && a_record[11:8] != 0;
    wire b_new = dual && b_record_ok && !b_ok_q && b_number != 0 && b_record != 12'h0FF && b_record[11:8] != 0;
    wire [2:0] mode = {dual, room_a};
    wire cancel = !link_up || mode != mode_q;
    wire a_dup = (act_v && !act_stop && act_side == 1'b0 && act_num == a_number) || (pa_v && pa_num == a_number);
    wire b_dup = (act_v && !act_stop && act_side == 1'b1 && act_num == b_number) || (pb_v && pb_num == b_number);
    wire act_more = act_v && !act_stop && act_rem != 0;
    // a waiting job becomes active this frame (see Q_IDLE)
    wire load_a = q == Q_IDLE && !zoom_active && !act_v && pa_v;
    wire load_b = q == Q_IDLE && !zoom_active && !act_v && !pa_v && pb_v;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            a_ok_q <= 0; b_ok_q <= 0; mode_q <= 0;
            act_v <= 0; act_side <= 0; act_stop <= 0; act_retry <= 0; act_done <= 0;
            act_room <= 0; act_cur <= 0; act_num <= 0; act_rem <= 0; act_idx <= 0; act_total <= 0;
            pa_v <= 0; pb_v <= 0; pa_room <= 0; pb_room <= 0; pa_num <= 0; pb_num <= 0; pa_needs <= 0; pb_needs <= 0;
            q <= Q_IDLE; wait_n <= 0;
            card <= 0; valid <= 0; clicks <= 0; room <= 0; number <= 0; idx <= 0; total <= 0;
        end else if (frame_start) begin
            a_ok_q <= a_record_ok; b_ok_q <= b_record_ok; mode_q <= mode;
            // ---- display handshake / issue ----
            case (q)
                Q_IDLE: if (!zoom_active) begin
                    if (act_more) begin
                        card <= {1'b0, first_need(act_rem)}; act_cur <= first_need(act_rem);
                        clicks <= clicks + 1'b1; valid <= 1'b1;
                        room <= act_room; number <= act_num; idx <= act_idx; total <= act_total;
                        act_done <= 1'b0; q <= Q_START; wait_n <= 0;
                    end else if (act_v) act_v <= 1'b0;                     // finished or dropped
                    else if (pa_v) begin
                        act_v <= 1; act_side <= 0; act_stop <= 0; act_retry <= 0; act_room <= pa_room;
                        act_num <= pa_num; act_rem <= pa_needs; act_idx <= 3'd1; act_total <= count(pa_needs);
                        pa_v <= 0;
                    end else if (pb_v) begin
                        act_v <= 1; act_side <= 1; act_stop <= 0; act_retry <= 0; act_room <= pb_room;
                        act_num <= pb_num; act_rem <= pb_needs; act_idx <= 3'd1; act_total <= count(pb_needs);
                        pb_v <= 0;
                    end
                end
                Q_START: begin
                    if (zoom_active) q <= Q_SHOW;
                    else if (wait_n == START_FRAMES - 1) q <= Q_IDLE;      // not started: issue again
                    else wait_n <= wait_n + 1'b1;
                end
                default: begin                                             // Q_SHOW
                    if (zoom_active) begin
                        if (zoom_full && zoom_card == {1'b0, act_cur}) act_done <= 1'b1;
                    end else begin
                        q <= Q_IDLE;
                        if (act_done || act_retry) begin                    // shown (or cut short twice)
                            act_rem[act_cur] <= 1'b0; act_idx <= act_idx + 1'b1; act_retry <= 1'b0;
                        end else act_retry <= 1'b1;                         // cut short: once more
                    end
                end
            endcase
            // ---- new patients (after the issue logic: they win over a same-frame cancel below) ----
            if (cancel) begin
                act_stop <= 1'b1;               // also a job loaded this frame
                pa_v <= 1'b0; pb_v <= 1'b0;
            end
            if (a_new && !a_dup && !cancel) begin
                if ((act_v && act_side == 1'b0) || load_a) act_stop <= 1'b1;
                pa_v <= 1'b1; pa_room <= room_a; pa_num <= a_number; pa_needs <= a_record[11:8];
            end
            if (b_new && !b_dup && !cancel) begin
                if ((act_v && act_side == 1'b1) || load_b) act_stop <= 1'b1;
                pb_v <= 1'b1; pb_room <= room_b; pb_num <= b_number; pb_needs <= b_record[11:8];
            end
        end
    end
endmodule
