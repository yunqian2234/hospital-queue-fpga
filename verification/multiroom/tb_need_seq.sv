`timescale 1ns/1ps
// 10/30 need-card sequence bench: clinic_need_trigger (sequencer) + the real clinic_card_view state
// machine (HOLD_FRAMES shortened to 20). One scenario per run (SCEN); every frame is logged and
// run_need_seq.py rebuilds the zoom episodes (card, room, number, idx/total, full hold) and compares
// them with the expected list, and checks the title snapshot never changes during an episode.
//   1 one room, needs 1011            -> cards 0,1,3 as 1/3 2/3 3/3
//   2 dual, A needs 0001 and B needs 1100 in the same frame -> A 0 (1/1), then B 2 (1/2), 3 (2/2)
//   3 dual, A needs 0111; B (0010) arrives during A's 2nd card -> A finishes, then B
//   4 A needs 1111; A's NEXT patient (0100) arrives during card 2/4 -> 2/4 finishes, the rest of the
//     old patient is dropped, the new patient's card follows
//   5 A needs 0011; a help request cuts card 1/2 short -> help card, 1/2 again (full), 2/2
//   6 as 5 but the help request cuts 1/2 short twice -> 1/2 skipped after the second time
//   7 A needs 0001; record_ok drops and rises again for the SAME patient during the zoom -> no repeat
//   8 A needs 0111; dual/single switch during 1/3 -> 1/3 finishes, nothing more
//   9 A needs 0111; link down for 3 frames during 1/3 -> 1/3 finishes, nothing more (also after it is up)
//  10 A needs 0011; reset during 1/2 -> after the reset the patient's cards start again from 1/2
//     (the view is not armed for the first frames: the first issue times out and is repeated)
//  11 nothing to show: needs 0000, nothing registered (0FF), room B in single-room mode -> no zoom;
//     then a patient with a need still zooms (1/1)
module tb_need_seq;
    parameter integer SCEN = 1;
    reg clk = 0, rst = 1;
    always #20 clk = ~clk;
    reg frame_start = 0;
    reg dual = 0, link_up = 1;
    reg [1:0] room_a = 0;
    reg [4:0] an = 0, bn = 0;
    reg [11:0] arec = 12'h0FF, brec = 12'h0FF;
    reg arok = 0, brok = 0;
    reg [1:0] help = 0;
    wire zoom_active, zoom_full, zoom_panel;
    wire [2:0] zoom_card;
    wire [2:0] card, idx, total;
    wire valid;
    wire [7:0] clicks;
    wire [1:0] room;
    wire [4:0] number;
    clinic_need_trigger dut(.clk(clk), .rst(rst), .frame_start(frame_start), .dual(dual), .link_up(link_up),
        .room_a(room_a), .room_b(2'd1), .a_number(an), .b_number(bn), .a_record(arec), .b_record(brec),
        .a_record_ok(arok), .b_record_ok(brok), .zoom_active(zoom_active), .zoom_full(zoom_full), .zoom_card(zoom_card),
        .card(card), .valid(valid), .clicks(clicks), .room(room), .number(number), .idx(idx), .total(total));
    clinic_card_view #(.H_BLANK(160), .HOLD_FRAMES(20), .SHOW_GRID(0), .HELP_CARD(4), .KEEP_Y0(382), .KEEP_Y1(416)) view(
        .clk(clk), .rst(rst), .frame_start(frame_start), .video_x(12'd0), .pixel_y(12'hfff), .de(1'b0),
        .in_rgb(24'd0), .out_rgb(), .link_up(link_up), .last_card(card), .last_card_valid(valid), .help_state(help),
        .card_clicks(clicks), .card_ready(6'd0), .store_busy(1'b0),
        .pix_ra(), .pix_rb(), .pix_qa(8'd0), .pix_qb(8'd0), .pal_ra(), .pal_rb(), .pal_qa(24'd0), .pal_qb(24'd0),
        .zoom_panel(zoom_panel), .zoom_card(zoom_card), .zoom_active(zoom_active), .zoom_full(zoom_full));
    integer fd, fno = 0;
    // one frame: pulse frame_start, then log the state both modules settled to
    task frame;
        begin
            @(negedge clk); frame_start = 1; @(negedge clk); frame_start = 0; @(negedge clk);
            $fdisplay(fd, "%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d", fno, view.st, view.k, zoom_card, zoom_full,
                      room, number, idx, total, rst);
            fno = fno + 1;
        end
    endtask
    task frames(input integer n); integer i; begin for (i = 0; i < n; i = i + 1) frame; end endtask
    // a new patient in column A / B: number changes (record_ok drops), the record arrives two frames later
    task patient_a(input [4:0] n, input [3:0] needs);
        begin an = n; arok = 0; frame; arec = {needs, 4'd2, 4'd5}; arok = 1; end
    endtask
    task patient_b(input [4:0] n, input [3:0] needs);
        begin bn = n; brok = 0; frame; brec = {needs, 4'd2, 4'd5}; brok = 1; end
    endtask
    // wait (at most 400 frames) until the view holds the card issued as idx i
    task until_hold(input [2:0] i);
        integer g;
        begin
            g = 0;
            while (!(view.st == 2 && idx == i && zoom_card != 3'd4) && g < 400) begin frame; g = g + 1; end
        end
    endtask
    task help_req; begin help = 1; frames(2); help = 2; end endtask
    initial begin
        fd = $fopen("seq.log", "w");
        repeat (3) @(negedge clk); rst = 0;
        frames(4);                                      // the view arms
        case (SCEN)
            1: begin patient_a(3, 4'b1011); frames(250); end
            2: begin dual = 1; frames(2); an = 4; bn = 5; arok = 0; brok = 0; frame;
                      arec = {4'b0001, 8'h25}; brec = {4'b1100, 8'h25}; arok = 1; brok = 1; frames(250); end
            3: begin dual = 1; frames(2); patient_a(6, 4'b0111); until_hold(2); patient_b(7, 4'b0010); frames(300); end
            4: begin patient_a(8, 4'b1111); until_hold(2); patient_a(9, 4'b0100); frames(250); end
            5: begin patient_a(10, 4'b0011); until_hold(1); frames(3); help_req; frames(300); end
            6: begin patient_a(11, 4'b0011); until_hold(1); frames(3); help_req; help = 0;
                      until_hold(1); frames(3); help_req; frames(300); end
            7: begin patient_a(12, 4'b0001); until_hold(1); arok = 0; frames(2); arok = 1; frames(200); end
            8: begin patient_a(13, 4'b0111); until_hold(1); dual = 1; frames(250); end
            9: begin patient_a(14, 4'b0111); until_hold(1); link_up = 0; frames(3); link_up = 1; frames(250); end
            10: begin patient_a(15, 4'b0011); until_hold(1); frames(3); @(negedge clk); rst = 1; frame; rst = 0; frames(300); end
            11: begin patient_a(16, 4'b0000); frames(30); an = 17; arok = 0; frame; arec = 12'h0FF; arok = 1; frames(30);
                      patient_b(18, 4'b1000); frames(30); patient_a(19, 4'b0100); frames(120); end
        endcase
        $fclose(fd);
        $display("PASS SEQ_DUMP scen=%0d frames=%0d", SCEN, fno);
        $finish;
    end
endmodule
