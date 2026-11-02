`timescale 1ns/1ps
// FAT32 media bench: fat32_bmp_reader + sparse SD-card model, driven by a command file.
// Every output byte (pixels, background audio, voice clips) and every result is written
// to trace.txt; run_fat32_tests.py checks them against the Python card image.
// The SD model works at the sd_card_top sector interface (no SPI); it is a test stub.
module tb;
    parameter integer MAXS = 4096;
    parameter integer VOICE = 1;
    parameter integer OW = 16, OH = 8;          // reader output size (10/21 scaler)
    parameter integer MAXW = 1920, MAXH = 1080;  // largest accepted source
    reg clk=0, rst=1, sd_init_done=0;
    always #5 clk=~clk;

    // ---------------- sparse SD model ----------------
    reg [31:0] lba_tab [0:MAXS-1];
    reg [7:0] data_tab [0:MAXS*512-1];
    integer nsec=0;
    wire sd_read; wire [31:0] sd_addr;
    reg [7:0] sd_data=0; reg sd_valid=0, sd_end=0;
    reg [31:0] bad_lba=32'hffffffff;
    integer sector_reads=0, sd_busy=0;
    function integer find(input [31:0] lba);
        integer lo, hi, mid;
        begin
            find=-1; lo=0; hi=nsec-1;
            while (lo<=hi && find<0) begin
                mid=(lo+hi)/2;
                if (lba_tab[mid]==lba) find=mid;
                else if (lba_tab[mid]<lba) lo=mid+1;
                else hi=mid-1;
            end
        end
    endfunction
    task serve(input [31:0] lba);
        integer idx, i, count;
        begin
            sd_busy=1; sector_reads=sector_reads+1;
            idx=find(lba);
            count=(lba==bad_lba) ? 100 : 512;
            repeat($urandom_range(20,80)) @(posedge clk);
            for (i=0;i<count;i=i+1) begin
                sd_data<=(idx<0) ? 8'd0 : data_tab[idx*512+i]; sd_valid<=1;
                @(posedge clk); sd_valid<=0;
                repeat($urandom_range(0,3)) @(posedge clk);
            end
            sd_end<=1; @(posedge clk); sd_end<=0;
            sd_busy=0;
        end
    endtask
    always @(posedge clk) if (sd_read) begin
        if (sd_busy) $fatal(1,"protocol: sd_read while busy");
        fork serve(sd_addr); join_none
    end

    // ---------------- DUT ----------------
    reg scan_start=0, load_start=0, audio_enable=0, clip_start=0;
    reg [1:0] load_index=0; reg [4:0] clip_id=0;
    reg pixel_ready=0, write_ack=0;
    wire ready, scan_done, scan_failed, scan_found, load_done, load_failed, error_valid, write_req;
    // scan_failed is a one-cycle pulse that coincides with scan_done; latch it.
    reg scan_failed_seen=0;
    always @(posedge clk) if (scan_start) scan_failed_seen<=0; else if (scan_failed) scan_failed_seen<=1;
    wire [3:0] valid_mask, bmp_error, audio_error, clip_error;
    wire pixel_valid; wire [23:0] pixel_data;
    wire sd_reset_req;
    wire audio_begin, audio_byte_valid, audio_done, audio_failed, audio_reset;
    wire [7:0] audio_byte, clip_byte;
    wire voice_available, voice_reset, clip_busy, clip_done, clip_failed, clip_byte_valid;
    integer audio_level=0, clip_level=0;
    wire audio_sector_ready = audio_level <= 2048-512;
    wire audio_byte_ready = audio_level < 2048;
    wire clip_sector_ready = clip_level <= 4096-512;
    reg clip_byte_ready=0;
    fat32_bmp_reader #(.CLK_FREQ_HZ(100_000_000),.SD_READ_TIMEOUT_MS(1),.USE_PIXEL_READY(1),
                       .ENABLE_AUDIO(1),.ENABLE_VOICE(VOICE),.OUT_W(OW),.OUT_H(OH),.MAX_W(MAXW),.MAX_H(MAXH)) dut(
        .clk(clk),.rst(rst),.sd_init_done(sd_init_done),.scan_start(scan_start),.scan_pause(1'b0),
        .ready(ready),.scan_done(scan_done),.scan_failed(scan_failed),.scan_found(scan_found),
        .valid_mask(valid_mask),.load_start(load_start),.load_index(load_index),.load_abort(1'b0),
        .load_done(load_done),.load_failed(load_failed),.error_valid(error_valid),.bmp_error(bmp_error),
        .bmp_width(16'd16),.bmp_height(16'd8),.write_req(write_req),.write_ack(write_ack),
        .pixel_valid(pixel_valid),.pixel_data(pixel_data),.pixel_ready(pixel_ready),
        .sd_reset_req(sd_reset_req),.sd_read(sd_read),.sd_addr(sd_addr),
        .sd_data(sd_data),.sd_valid(sd_valid),.sd_end(sd_end),
        .audio_enable(audio_enable),.audio_sector_ready(audio_sector_ready),.audio_byte_ready(audio_byte_ready),
        .audio_begin(audio_begin),.audio_byte_valid(audio_byte_valid),.audio_byte(audio_byte),
        .audio_done(audio_done),.audio_failed(audio_failed),.audio_reset(audio_reset),.audio_error(audio_error),
        .voice_available(voice_available),.voice_reset(voice_reset),.clip_start(clip_start),.clip_id(clip_id),
        .clip_busy(clip_busy),.clip_done(clip_done),.clip_failed(clip_failed),.clip_error(clip_error),
        .clip_sector_ready(clip_sector_ready),.clip_byte_ready(clip_byte_ready),
        .clip_byte_valid(clip_byte_valid),.clip_byte(clip_byte));

    // ---------------- sinks with random back-pressure ----------------
    integer fd;
    reg audio_finished=0;
    always @(posedge clk) begin
        pixel_ready<=$urandom_range(0,1);
        clip_byte_ready<=$urandom_range(0,3)!=0;
        if (pixel_valid && pixel_ready) $fwrite(fd,"P %06x\n",pixel_data);
        if (audio_byte_valid && audio_byte_ready) $fwrite(fd,"A %02x\n",audio_byte);
        if (clip_byte_valid && clip_byte_ready) $fwrite(fd,"C %02x\n",clip_byte);
        if (audio_done) begin $fwrite(fd,"AUDIO done\n"); audio_finished<=1; end
        if (audio_failed) begin $fwrite(fd,"AUDIO failed\n"); audio_finished<=1; end
        if (rst) begin audio_level<=0; clip_level<=0; end
        else begin
            audio_level <= audio_level + ((audio_byte_valid===1'b1 && audio_byte_ready) ? 1 : 0)
                           - ((audio_level>0 && $urandom_range(0,2)==0) ? 1 : 0);
            clip_level <= clip_level + ((clip_byte_valid===1'b1 && clip_byte_ready) ? 1 : 0)
                          - ((clip_level>0 && $urandom_range(0,1)==0) ? 1 : 0);
        end
        if (!rst && (^{sd_read,dut.owner,dut.request,audio_byte_valid,clip_byte_valid,pixel_valid}===1'bx))
            $fatal(1,"X on DUT control outputs");
        if (clip_byte_valid && !voice_available) $fatal(1,"clip bytes without a voice bank");
    end

    // ---------------- command interpreter ----------------
    integer cfd, op, a, b, n, guard;
    reg load_busy, clip_wait;
    task start_load(input integer index);
        begin
            // as sd_card_bmp (PICK): a load starts only when the reader is ready (10/21: needed
            // after a rejected picture, while the file streamer drains the rest of that file)
            @(negedge clk); while (!ready) @(negedge clk);
            load_index=index; load_start=1; write_ack=1;
            @(negedge clk); load_start=0; load_busy=1;
        end
    endtask
    task start_clip(input integer id);
        begin
            @(negedge clk); clip_id=id; clip_start=1;
            @(negedge clk); clip_start=0; clip_wait=1;
        end
    endtask
    always @(posedge clk) begin
        if (load_busy && (load_done || load_failed)) begin
            $fwrite(fd,"LOAD %0d %0d %0d\n",load_index,load_done,load_failed ? bmp_error : 0);
            load_busy<=0; write_ack<=0;
        end
        if (clip_wait && (clip_done || clip_failed)) begin
            $fwrite(fd,"CLIP %0d %0d %0d\n",clip_id,clip_done,clip_error);
            clip_wait<=0;
        end
    end
    task wait_idle;
        begin
            guard=0;
            while (load_busy || clip_wait) begin
                @(posedge clk); guard=guard+1;
                if (guard>40000000) $fatal(1,"command watchdog");
            end
            @(posedge clk);
        end
    endtask
    string cmds;
    initial begin
        if (!$value$plusargs("SECTORS=%d",nsec)) $fatal(1,"missing SECTORS");
        if (!$value$plusargs("CMDS=%s",cmds)) $fatal(1,"missing CMDS");
        $readmemh("sd_lba.hex", lba_tab, 0, nsec-1);
        $readmemh("sd_data.hex", data_tab, 0, nsec*512-1);
        load_busy=0; clip_wait=0;
        fd=$fopen("trace.txt","w");
        cfd=$fopen(cmds,"r");
        repeat(5) @(negedge clk); rst=0; repeat(5) @(negedge clk); sd_init_done=1;
        repeat(5) @(negedge clk);
        while ($fscanf(cfd,"%d %d %d\n",op,a,b)==3) begin
            case (op)
                1: begin
                    @(negedge clk); scan_start=1; @(negedge clk); scan_start=0;
                    guard=0;
                    while (!scan_done) begin @(posedge clk); guard=guard+1; if (guard>4000000) $fatal(1,"scan watchdog"); end
                    @(negedge clk);
                    $fwrite(fd,"SCAN failed=%0d mask=%0d voice=%0d\n",scan_failed_seen,valid_mask,voice_available);
                end
                2: begin start_load(a); wait_idle; end
                3: audio_enable=1;
                4: begin start_clip(a); wait_idle; end
                5: begin fork start_clip(a); start_load(b); join wait_idle; end
                6: repeat(a) @(posedge clk);
                7: bad_lba=a;
                8: begin
                    guard=0;
                    while (!audio_finished) begin @(posedge clk); guard=guard+1; if (guard>40000000) $fatal(1,"audio watchdog"); end
                end
                default: $fatal(1,"bad command %0d",op);
            endcase
        end
        repeat(50) @(posedge clk);
        if (clip_busy || sd_busy) $fatal(1,"left busy");
        $fwrite(fd,"END reads=%0d\n",sector_reads);
        $fclose(fd);
        $display("PASS FAT32_TRACE reads=%0d",sector_reads);
        $finish;
    end
endmodule
