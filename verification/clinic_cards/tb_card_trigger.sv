`timescale 1ns/1ps
// 10/24 trigger bench: clinic_card_view's frame-rate state machine only (no picture).
// trigger.txt: one line per frame "last last_valid help link clicks"; after every frame start
// the state (st k zoom_card) is written to trigger_states.txt for run_trigger_tests.py.
module tb;
    reg clk = 0, rst = 1;
    always #20 clk = ~clk;
    reg frame_start = 0;
    reg [2:0] last_card = 0;
    reg last_card_valid = 0, link_up = 0;
    reg [1:0] help_state = 0;
    reg [7:0] card_clicks = 0;
    wire [15:0] pix_ra, pix_rb;
    wire [10:0] pal_ra, pal_rb;
    wire [23:0] out_rgb;
    wire zoom_panel, zoom_active;
    wire [2:0] zoom_card;
    clinic_card_view #(.HOLD_FRAMES(4)) view(
        .clk(clk), .rst(rst), .frame_start(frame_start), .video_x(12'd0), .pixel_y(12'd600),
        .de(1'b0), .in_rgb(24'd0), .out_rgb(out_rgb),
        .link_up(link_up), .last_card(last_card), .last_card_valid(last_card_valid), .help_state(help_state),
        .card_clicks(card_clicks), .card_ready(6'h3f), .store_busy(1'b0),
        .pix_ra(pix_ra), .pix_rb(pix_rb), .pix_qa(8'd0), .pix_qb(8'd0),
        .pal_ra(pal_ra), .pal_rb(pal_rb), .pal_qa(24'd0), .pal_qb(24'd0),
        .zoom_panel(zoom_panel), .zoom_card(zoom_card), .zoom_active(zoom_active));
    integer vf, sf, f, v_last, v_lv, v_help, v_up, v_clicks;
    initial begin
        vf = $fopen("trigger.txt", "r");
        sf = $fopen("trigger_states.txt", "w");
        repeat (4) @(negedge clk); rst = 0;
        f = $fscanf(vf, "%d %d %d %d %d\n", v_last, v_lv, v_help, v_up, v_clicks);
        while (f == 5) begin
            last_card = v_last; last_card_valid = v_lv; help_state = v_help; link_up = v_up; card_clicks = v_clicks;
            repeat (10) @(negedge clk);
            frame_start = 1; @(negedge clk); frame_start = 0;
            repeat (10) @(negedge clk);
            $fwrite(sf, "%0d %0d %0d\n", view.st, view.k, view.zoom_card);
            f = $fscanf(vf, "%d %d %d %d %d\n", v_last, v_lv, v_help, v_up, v_clicks);
        end
        $fclose(sf);
        $display("PASS TRIGGER_DUMP");
        $finish;
    end
endmodule
