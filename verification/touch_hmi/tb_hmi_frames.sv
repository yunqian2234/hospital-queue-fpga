`timescale 1ns/1ps
// 10/25 touch-screen tutorial check: the bytes the HMI code of docs/TOUCH_HMI_TUTORIAL_20261025.md
// sends (stim.mem, written by run_hmi_frames.py) go at 9600 baud through the real uart_rx +
// tjc_touch_rx + hospital_registration. Every decoded frame is logged (F cmd arg); on 报到
// (cmd 3) the bench plays the core: ticket_taken with the next number, then a call of that
// number by room 1, and logs the pending record and room 1's record (T pending record).
// stim.mem words: 0x0bb = byte, 0x100 = 2 ms idle, 0x1ff = end.
module tb_hmi_frames;
    localparam integer CLK_HZ = 1_000_000, BAUD = 9600, DIV = (CLK_HZ + BAUD / 2) / BAUD;
    reg clk = 0, rst = 1, rx = 1;
    always #500 clk = ~clk;
    wire cmd_valid;
    wire [6:0] cmd, arg;
    wire [15:0] good, bad, other, lerr;
    tjc_touch_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD), .GAP_CYCLES(50_000)) u_rx(
        .clk(clk), .rst(rst), .rx(rx), .cmd_valid(cmd_valid), .cmd(cmd), .arg(arg),
        .good_frames(good), .bad_frames(bad), .other_frames(other), .line_errors(lerr));
    reg ticket_taken = 0, call_taken = 0;
    reg [4:0] issued = 0, call_no = 0;
    wire [11:0] pending;
    wire [47:0] room_records;
    hospital_registration #(.ROOMS(4)) u_reg(
        .clk(clk), .rst(rst), .cmd_valid(cmd_valid), .cmd(cmd), .arg(arg),
        .ticket_taken(ticket_taken), .issued_number(issued),
        .call_taken(call_taken), .call_number(call_no), .last_room(2'd0),
        .pending(pending), .room_records(room_records));

    integer fd, i, k;
    reg [11:0] pend_at;
    reg [8:0] stim [0:65535];
    // the core: ticket on 报到, then room 1 calls it (one record read later)
    always @(posedge clk) if (cmd_valid) begin
        $fdisplay(fd, "F %0d %0d", cmd, arg);
        if (cmd == 7'd3) fork begin
            // driven on the falling edge so the RTL samples them cleanly
            @(negedge clk); pend_at = pending; issued = issued + 1'b1; ticket_taken = 1;
            @(negedge clk); ticket_taken = 0;
            @(negedge clk); call_no = issued; call_taken = 1;
            @(negedge clk); call_taken = 0;
            repeat (3) @(negedge clk);
            $fdisplay(fd, "T %03x %03x %03x", pend_at, room_records[11:0], pending);
        end join_none
    end
    task send_byte(input [7:0] b);
        integer j;
        begin
            rx = 0; repeat (DIV) @(posedge clk);
            for (j = 0; j < 8; j = j + 1) begin rx = b[j]; repeat (DIV) @(posedge clk); end
            rx = 1; repeat (DIV) @(posedge clk);
        end
    endtask
    initial begin
        fd = $fopen("hmi_frames.log", "w");
        $readmemh("stim.mem", stim);
        repeat (20) @(posedge clk); rst = 0; repeat (20) @(posedge clk);
        for (i = 0; stim[i] != 9'h1ff; i = i + 1)
            if (stim[i] == 9'h100) repeat (2000) @(posedge clk);
            else send_byte(stim[i][7:0]);
        repeat (2000) @(posedge clk);
        $fdisplay(fd, "S %0d %0d %0d %0d", good, bad, other, lerr);
        $fclose(fd);
        $finish;
    end
endmodule
