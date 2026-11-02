`timescale 1ns/1ps
// 10/23 clinic card loader bench: clinic_card_loader + clinic_card_store (behavioural RAM) +
// a sector-level SD model (sd_card_top interface, no SPI; test stub). The card image comes from
// run_card_tests.py (sd_lba.hex / sd_data.hex). Writes ready.txt and the store contents
// (pix.hex, pal.hex) once the loader reports done, for comparison with the Python BMP decode.
//   +SECTORS=n          number of stored sectors
//   +PRESENT_AT=c       clock at which the card is "inserted" (0 = from the start)
//   +BAD_LBA=l          that sector returns only 100 bytes (short read -> sector error)
//   +BAD_ONCE           ... only the first time it is read (a transient error)
//   +HANG_LBA=l         the first read of that sector never ends (adapter timeout -> SD reset)
module tb;
    parameter integer MAXS = 2048;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    reg [31:0] lba_tab [0:MAXS-1];
    reg [7:0] data_tab [0:MAXS*512-1];
    integer nsec = 0, present_at = 0, reads = 0, resets = 0, cycles = 0;
    reg [31:0] bad_lba = 32'hffffffff, hang_lba = 32'hffffffff;
    reg hang_armed = 1, bad_once = 0, bad_armed = 1;
    reg sd_init_done = 0, sd_valid = 0, sd_end = 0;
    reg [7:0] sd_data = 0;
    integer sd_busy = 0;
    wire sd_read, sd_reset_req;
    wire [31:0] sd_addr;
    event reset_ev;
    function integer find(input [31:0] lba);
        integer lo, hi, mid;
        begin
            find = -1; lo = 0; hi = nsec - 1;
            while (lo <= hi && find < 0) begin
                mid = (lo + hi) / 2;
                if (lba_tab[mid] == lba) find = mid;
                else if (lba_tab[mid] < lba) lo = mid + 1;
                else hi = mid - 1;
            end
        end
    endfunction
    task serve(input [31:0] lba);
        integer idx, i, count;
        begin
            sd_busy = 1; reads = reads + 1;
            if (lba == hang_lba && hang_armed) begin
                hang_armed = 0;
                @(reset_ev);                       // never answered; the SD reset ends it
            end else begin
                idx = find(lba);
                count = (lba == bad_lba && bad_armed) ? 100 : 512;
                if (lba == bad_lba && bad_once) bad_armed = 0;
                repeat ($urandom_range(20, 80)) @(posedge clk);
                for (i = 0; i < count && sd_init_done; i = i + 1) begin
                    sd_data <= (idx < 0) ? 8'd0 : data_tab[idx * 512 + i]; sd_valid <= 1;
                    @(posedge clk); sd_valid <= 0;
                    repeat ($urandom_range(0, 3)) @(posedge clk);
                end
                if (sd_init_done) begin sd_end <= 1; @(posedge clk); sd_end <= 0; end
            end
            sd_busy = 0;
        end
    endtask
    always @(posedge clk) if (sd_read) begin
        if (sd_busy) $fatal(1, "protocol: sd_read while busy");
        if (!sd_init_done) $fatal(1, "protocol: sd_read before init");
        fork serve(sd_addr); join_none
    end
    // card initialisation: 2000 clocks after insertion or after each reset request
    integer init_timer = 0;
    always @(posedge clk) begin
        cycles <= cycles + 1;
        if (sd_reset_req) begin
            resets <= resets + 1; sd_init_done <= 0; init_timer <= 0; -> reset_ev;
        end else if (!sd_init_done && cycles >= present_at) begin
            if (init_timer == 2000) sd_init_done <= 1; else init_timer <= init_timer + 1;
        end
    end

    wire [5:0] card_ready;
    wire busy;
    wire [3:0] status;
    wire pix_we, pal_we;
    wire [15:0] pix_waddr;
    wire [7:0] pix_wdata;
    wire [10:0] pal_waddr;
    wire [23:0] pal_wdata;
    clinic_card_loader #(.CLK_HZ(100_000), .INIT_WAIT_MS(3000), .RETRY_MS(3000), .SD_TIMEOUT_MS(100)) dut(
        .clk(clk), .rst(rst), .sd_init_done(sd_init_done), .sd_read(sd_read), .sd_addr(sd_addr),
        .sd_data(sd_data), .sd_valid(sd_valid), .sd_end(sd_end), .sd_reset_req(sd_reset_req),
        .card_ready(card_ready), .busy(busy), .status(status),
        .pix_we(pix_we), .pix_waddr(pix_waddr), .pix_wdata(pix_wdata),
        .pal_we(pal_we), .pal_waddr(pal_waddr), .pal_wdata(pal_wdata));
    clinic_card_store u_store(
        .clk(clk), .sel_loader(busy),
        .pix_we(pix_we), .pix_waddr(pix_waddr), .pix_wdata(pix_wdata),
        .pal_we(pal_we), .pal_waddr(pal_waddr), .pal_wdata(pal_wdata),
        .pix_ra(16'd0), .pix_rb(16'd0), .pix_qa(), .pix_qb(), .pal_ra(11'd0), .pal_rb(11'd0), .pal_qa(), .pal_qb());
    // writes only while the loader owns port A, and never X
    always @(posedge clk) if (!rst) begin
        if ((pix_we || pal_we) && !busy) $fatal(1, "store write while not busy");
        if (^{card_ready, busy, status, sd_read} === 1'bx) $fatal(1, "X on loader outputs");
    end

    integer fd, n;
    initial begin
        if (!$value$plusargs("SECTORS=%d", nsec)) $fatal(1, "SECTORS");
        n = $value$plusargs("PRESENT_AT=%d", present_at);
        n = $value$plusargs("BAD_LBA=%h", bad_lba);
        n = $value$plusargs("HANG_LBA=%h", hang_lba);
        bad_once = $test$plusargs("BAD_ONCE");
        $readmemh("sd_lba.hex", lba_tab, 0, nsec - 1);
        $readmemh("sd_data.hex", data_tab, 0, nsec * 512 - 1);
        repeat (5) @(negedge clk); rst = 0;
        n = 0;
        while (status != 3 && n < 20_000_000) begin @(posedge clk); n = n + 1; end
        if (status != 3) $fatal(1, "loader did not finish, status=%0d ready=%b", status, card_ready);
        repeat (20) @(posedge clk);
        $writememh("pix.hex", u_store.pix);
        $writememh("pal.hex", u_store.pal);
        fd = $fopen("ready.txt", "w");
        $fwrite(fd, "%0d %0d %0d %0d\n", card_ready, reads, resets, cycles);
        $fclose(fd);
        $display("PASS CARD_LOADER ready=%b reads=%0d resets=%0d cycles=%0d", card_ready, reads, resets, cycles);
        $finish;
    end
endmodule
