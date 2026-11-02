`timescale 1ns/1ps
// 10/26 UART trim equivalence: previous (…_old) and trimmed modules side by side, same random
// stimulus, every output compared on every clock. DIV comes from CLK_HZ/BAUD parameters.
//   uart_tx: random valid/data (also while busy), random resets
//   uart_rx + tjc_touch_rx: a random line built from real frames (5A cmd arg chk FF FF FF, also
//   bad checksums), other bytes, short glitches, broken stop bits, idle gaps longer and shorter
//   than the frame gap timeout, random resets
module tb_uart_equiv;
    parameter integer CLK_HZ = 1_000_000, BAUD = 9600, GAP = 5000, CYCLES = 2_000_000, SEED = 1;
    localparam integer DIV = (CLK_HZ + BAUD / 2) / BAUD;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;
    integer seed = SEED, n, errors = 0, i, cmds = 0, txb = 0, rxb = 0, ferr = 0;
    always @(posedge clk) begin
        if (cv_n) cmds = cmds + 1;
        if (valid && rdy_n) txb = txb + 1;
        if (n_rx.byte_valid) rxb = rxb + 1;
        if (n_rx.frame_error) ferr = ferr + 1;
    end
    // ---------------- tx ----------------
    reg valid = 0; reg [7:0] data = 0;
    wire rdy_n, rdy_o, tx_n, tx_o;
    uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) n_tx(.clk(clk), .rst(rst), .valid(valid), .data(data), .ready(rdy_n), .tx(tx_n));
    uart_tx_old #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) o_tx(.clk(clk), .rst(rst), .valid(valid), .data(data), .ready(rdy_o), .tx(tx_o));
    // ---------------- rx (through tjc_touch_rx) ----------------
    reg rx = 1;
    wire cv_n, cv_o; wire [6:0] c_n, c_o, a_n, a_o;
    wire [15:0] g_n, g_o, b_n, b_o, ot_n, ot_o, l_n, l_o;
    tjc_touch_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD), .GAP_CYCLES(GAP)) n_rx(.clk(clk), .rst(rst), .rx(rx),
        .cmd_valid(cv_n), .cmd(c_n), .arg(a_n), .good_frames(g_n), .bad_frames(b_n), .other_frames(ot_n), .line_errors(l_n));
    tjc_touch_rx_old #(.CLK_HZ(CLK_HZ), .BAUD(BAUD), .GAP_CYCLES(GAP)) o_rx(.clk(clk), .rst(rst), .rx(rx),
        .cmd_valid(cv_o), .cmd(c_o), .arg(a_o), .good_frames(g_o), .bad_frames(b_o), .other_frames(ot_o), .line_errors(l_o));
    // raw uart_rx outputs too (inside the touch receivers)
    wire [9:0] raw_n = {n_rx.byte_valid, n_rx.frame_error, n_rx.b};
    wire [9:0] raw_o = {o_rx.byte_valid, o_rx.frame_error, o_rx.b};
    always @(negedge clk) begin
        if ({rdy_n, tx_n} !== {rdy_o, tx_o}) begin errors = errors + 1; if (errors < 5) $display("TX differ t=%0t", $time); end
        if ({cv_n, c_n, a_n, g_n, b_n, ot_n, l_n, raw_n} !== {cv_o, c_o, a_o, g_o, b_o, ot_o, l_o, raw_o}) begin
            errors = errors + 1; if (errors < 5) $display("RX differ t=%0t", $time);
        end
    end
    // tx stimulus
    always @(posedge clk) begin
        valid <= ($random(seed) & 3) != 0;
        data <= $random(seed);
    end
    // rx line: a stream of characters with random timing defects
    task send(input [7:0] b, input integer stop_ok, input integer jitter);
        integer k;
        begin
            rx <= 0; repeat (DIV + jitter) @(posedge clk);
            for (k = 0; k < 8; k = k + 1) begin rx <= b[k]; repeat (DIV) @(posedge clk); end
            rx <= stop_ok ? 1'b1 : 1'b0; repeat (DIV) @(posedge clk);
            rx <= 1;
        end
    endtask
    reg [7:0] cmd, arg;
    initial begin
        repeat (5) @(posedge clk); rst <= 0;
        while ($time < CYCLES * 10) begin
            n = $random(seed) & 15;
            if (n < 8) begin                                   // a command frame
                cmd = $random(seed) & 8'h7f; arg = $random(seed) & 8'h7f;
                send(8'h5a, 1, 0); send(cmd, 1, 0); send(arg, 1, 0);
                send(n == 0 ? 8'h00 : 8'h5a ^ cmd ^ arg, 1, 0);
                send(8'hff, 1, 0); send(8'hff, 1, 0); send(8'hff, n != 1, 0);
            end else if (n < 10) send($random(seed), 1, ($random(seed) & 3));   // other byte
            else if (n == 10) begin rx <= 0; repeat (($random(seed) & 7) + 1) @(posedge clk); rx <= 1; end   // glitch
            else if (n == 11) send($random(seed), 0, 0);         // framing error
            else if (n == 12) repeat (GAP + ($random(seed) & 255)) @(posedge clk);   // past the gap timeout
            else if (n == 13 && ($random(seed) & 7) == 0) begin rst <= 1; repeat (3) @(posedge clk); rst <= 0; end
            else repeat ($random(seed) & 1023) @(posedge clk);
        end
        $display("%s uart equivalence DIV=%0d errors=%0d tx_bytes=%0d rx_bytes=%0d framing_errors=%0d commands=%0d",
                 errors == 0 ? "PASS" : "FAIL", DIV, errors, txb, rxb, ferr, cmds);
        $finish;
    end
endmodule
