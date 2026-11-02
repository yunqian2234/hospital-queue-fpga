`timescale 1ns/1ps
// 10/26 bmp_res_info unit bench: the SD side writes (commit) pictures 0..3 with the sizes in
// res_cases.txt ("index w h fw fh" per line, SD clock 50 MHz), the video side (25 MHz) reads
// every index after each write; reads are logged as "R index cells(hex)" and compared by
// run_res_info.py with an independent formatter. A commit right after another (before the
// conversion finished) must still give the second picture's values.
module tb_res_info;
    reg clk = 0, vclk = 0, rst = 1;
    always #10 clk = ~clk;
    always #20 vclk = ~vclk;
    reg commit = 0;
    reg [1:0] index = 0, rd_index = 0;
    reg [10:0] w = 0, h = 0, fw = 0, fh = 0;
    wire [59:0] cells;
    bmp_res_info dut(.clk(clk), .rst(rst), .commit(commit), .index(index), .src_w(w), .src_h(h),
        .fit_w(fw), .fit_h(fh), .rd_clk(vclk), .rd_index(rd_index), .cells(cells));
    integer fd, fo, n, i, k, r, back;
    integer a [0:4];
    task read_all;
        for (k = 0; k < 4; k = k + 1) begin
            @(negedge vclk); rd_index = k;
            @(negedge vclk);
            $fdisplay(fo, "R %0d %015h", k, cells);
        end
    endtask
    initial begin
        fd = $fopen("res_cases.txt", "r");
        fo = $fopen("res_out.txt", "w");
        repeat (4) @(negedge clk); rst = 0;
        n = $fscanf(fd, "%d %d %d %d %d %d\n", a[0], a[1], a[2], a[3], a[4], back);
        while (n == 6) begin
            @(negedge clk);
            index = a[0]; w = a[1]; h = a[2]; fw = a[3]; fh = a[4]; commit = 1;
            @(negedge clk); commit = 0;
            if (back) begin                      // a second commit 3 clocks later overrides
                repeat (2) @(negedge clk);
                n = $fscanf(fd, "%d %d %d %d %d %d\n", a[0], a[1], a[2], a[3], a[4], back);
                index = a[0]; w = a[1]; h = a[2]; fw = a[3]; fh = a[4]; commit = 1;
                @(negedge clk); commit = 0;
            end
            // the decoder / scaler may start the next load: the inputs change while converting
            w = 11'h7ff; h = 0; fw = 11'h555; fh = 11'h2aa;
            repeat (16) @(negedge clk);
            read_all;
            n = $fscanf(fd, "%d %d %d %d %d %d\n", a[0], a[1], a[2], a[3], a[4], back);
        end
        $fclose(fo);
        $display("PASS RES_INFO_DUMP");
        $finish;
    end
endmodule
