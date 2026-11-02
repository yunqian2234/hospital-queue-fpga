`timescale 1ns/1ps
// 10/22 touch-pause regression for hospital_patient_ui.
// CLK_HZ=1000, IDLE_SECONDS=1 -> the idle pause lasts IDLE=1000 clocks.
//  T1 touch clicks (card, replay, ticket) never raise photo_pause; a card click still selects.
//  T2 a J1 navigation key (K5 = next card) still pauses for exactly the idle time.
//  T3 a touch click during a key pause neither extends nor shortens it.
module tb_patient_ui_pause;
    localparam integer IDLE = 1000;
    reg clk = 0, rst = 1, frame_start = 0;
    reg [7:0] key_press = 0, key_release = 0, key_pressed = 0, key_armed = 8'hff;
    reg touch_confirm = 0;
    reg [2:0] touch_kind = 0, touch_card = 0;
    wire [1:0] ui_page;
    wire [2:0] selection, preview_kind, preview_card;
    wire [4:0] preview_number, request_number;
    wire request_valid;
    wire [2:0] request_kind, request_card;
    wire photo_pause, home_long;
    wire [3:0] notice;
    integer errors = 0, pause_cycles, t;

    hospital_patient_ui #(.CLK_HZ(1000), .LONG_MS(1000), .IDLE_SECONDS(1)) dut(
        .clk(clk), .rst(rst), .frame_start(frame_start),
        .key_press(key_press), .key_release(key_release), .key_pressed(key_pressed), .key_armed(key_armed),
        .call_number(5'd3), .touch_confirm(touch_confirm), .touch_kind(touch_kind), .touch_card(touch_card),
        .ui_page(ui_page), .selection(selection), .preview_kind(preview_kind), .preview_card(preview_card),
        .preview_number(preview_number), .request_valid(request_valid), .request_kind(request_kind),
        .request_card(request_card), .request_number(request_number), .request_ready(1'b1),
        .request_done(1'b0), .request_accepted(1'b0), .request_result(3'd0),
        .photo_pause(photo_pause), .notice(notice), .home_long(home_long));

    always #5 clk = ~clk;

    task touch(input [2:0] kind, input [2:0] card);
        begin
            @(negedge clk); touch_confirm = 1; touch_kind = kind; touch_card = card;
            @(negedge clk); touch_confirm = 0;
        end
    endtask

    task check(input cond, input [8*64-1:0] what);
        begin
            if (!cond) begin errors = errors + 1; $display("FAIL: %0s", what); end
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        rst = 0;
        repeat (3) @(negedge clk);
        check(!photo_pause, "idle after reset");

        // T1: every touch kind the top can confirm (3 card, 2 replay, 6 ticket)
        touch(3, 3'd4);
        pause_cycles = 0;
        for (t = 0; t < 50; t = t + 1) begin @(negedge clk); if (photo_pause) pause_cycles = pause_cycles + 1; end
        check(pause_cycles == 0, "touch card click must not pause rotation");
        check(selection == 3'd4, "touch card click still updates selection");
        check(ui_page == 0, "touch click stays on HOME");
        touch(2, 0); touch(6, 0);
        pause_cycles = 0;
        for (t = 0; t < 50; t = t + 1) begin @(negedge clk); if (photo_pause) pause_cycles = pause_cycles + 1; end
        check(pause_cycles == 0, "touch replay/ticket must not pause rotation");

        // T2: J1 K5 (next card) opens SELECT -> paused; return to HOME via long K7
        @(negedge clk); key_press = 8'h10; @(negedge clk); key_press = 0;
        check(photo_pause && ui_page == 1, "J1 key opens SELECT and pauses");
        // long press K7 (index 6): press, hold LONG (1000 clk), page returns HOME
        @(negedge clk); key_press = 8'h40; key_pressed = 8'h40; @(negedge clk); key_press = 0;
        while (!home_long) @(negedge clk);
        @(negedge clk); key_pressed = 0; key_release = 8'h40; @(negedge clk); key_release = 0;
        check(ui_page == 0, "long K7 returns HOME");
        // idle countdown from the long-press event: measure remaining pause on HOME
        pause_cycles = 0;
        while (photo_pause && pause_cycles < 5 * IDLE) begin @(negedge clk); pause_cycles = pause_cycles + 1; end
        check(pause_cycles > IDLE - 20 && pause_cycles <= IDLE, "key pause lasts the idle time on HOME");

        // T3: K8 (ticket key) pauses for IDLE; a touch click half way must not change that
        @(negedge clk); key_press = 8'h80; @(negedge clk); key_press = 0;
        pause_cycles = 1;
        for (t = 0; t < IDLE / 2; t = t + 1) begin @(negedge clk); if (photo_pause) pause_cycles = pause_cycles + 1; end
        touch(3, 3'd1);
        pause_cycles = pause_cycles + 2;
        while (photo_pause && pause_cycles < 5 * IDLE) begin @(negedge clk); pause_cycles = pause_cycles + 1; end
        check(pause_cycles >= IDLE - 2 && pause_cycles <= IDLE + 2, "touch during key pause does not extend it");

        if (errors == 0) $display("PASS tb_patient_ui_pause");
        else $display("FAILED tb_patient_ui_pause errors=%0d", errors);
        $finish;
    end
    initial begin #2000000; $display("FAIL: timeout"); $finish; end
endmodule
