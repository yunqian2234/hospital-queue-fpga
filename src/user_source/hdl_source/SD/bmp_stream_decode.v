// 第6课：把 BMP 内容校验与物理地址解耦；继承第4课严格校验和像素完整性检查。
// 扩展要求3（10/21）：宽高取自文件头，接受 MIN_W×MIN_H ～ MAX_W×MAX_H（官方要求不低于 640×480，
// 本设计最大 1920×1080）的 24 位无压缩自下而上 BMP；src_w/src_h 随 write_req 一起有效，
// 交给 bmp_scaler 缩放到显示分辨率。bmp_width/bmp_height 端口保留但不再使用。
module bmp_stream_decode #(
    parameter integer CLK_FREQ_HZ=100_000_000,
    parameter integer TIMEOUT_MS=1000,
    parameter [31:0] MAX_BMP_BYTES=32'd16_777_216,
    parameter integer USE_PIXEL_READY=0,
    parameter integer MIN_W=640, MIN_H=480, MAX_W=1920, MAX_H=1080
)(
    input clk, rst, start, abort,
    input [31:0] directory_size,
    input [15:0] bmp_width, bmp_height,
    input file_valid, input [7:0] file_data, output file_ready,
    input file_done, file_failed,
    output busy, output reg done, failed, output reg [3:0] error_code,
    output reg write_req, input write_ack,
    output reg pixel_valid, output reg [23:0] pixel_data, input pixel_ready,
    output [10:0] src_w, src_h                   // valid from write_req to the end of the load
);
localparam IDLE=0, HEADER=1, CHECK1=2, CHECK2=3, CHECK3=4, WAIT_ACK=5, DATA=6, FINISH=7, CHECK0=8, FINISH0=9;
assign src_w=width[10:0];
assign src_h=height[10:0];
localparam [63:0] LIMIT=(64'd1*CLK_FREQ_HZ/1000)*TIMEOUT_MS;
reg [3:0] state;
reg [31:0] offset, file_len, pixel_offset, dib_size, width, height, compression, size_latched;
reg [15:0] planes, bit_count;
reg [7:0] magic0, magic1;
reg [33:0] required_end, dib_end;
reg [31:0] timer;
// 10/21: sizes are at most MAX_W x MAX_H (<= 2047 x 2047): a row is < 8 KB (13 bits), a picture
// has < 2^22 pixels. Narrow counters keep the per-byte compares small (the hall board is full).
reg [12:0] row_bytes, row_stride, byte_in_row;
reg [21:0] expected_pixels, pixel_count;
reg [1:0] component;
reg header_ok, stream_finished;
// 10/05 时序：看门狗比较寄存一拍。超时阈值为 1 秒量级，晚一拍报错无影响，但宽比较
// 不再与所有状态寄存器的使能串在同一拍。
reg timed_out;
// 10/05 时序：像素窗口判断（offset 是否落在 [pixel_offset, required_end)）提前一拍算成标志。
// offset 只在 take 时加 1，故“下一字节的 offset”= take ? offset+1 : offset，可在本拍算出。
reg in_window;
// 10/22 时序：两种情况（本拍取/不取字节）的比较结果各算一份，take 只做最后一级选择，
// 不再经过 32 位加法后再做比较。
wire win_hold = {2'b0,offset}>={2'b0,pixel_offset} && {2'b0,offset}<required_end;
wire win_next = {2'b0,offset}+34'd1>={2'b0,pixel_offset} && {2'b0,offset}+34'd1<required_end;
// 10/22 时序：结束检查的两个比较（32 位偏移==文件长度、像素数==期望值）寄存一拍。
// DATA 之后先经过 FINISH0 一拍，FINISH 中偏移与像素数都已不再变化，标志有效。
reg end_offset_ok, end_pixels_ok;
assign busy=(state!=IDLE);
// 第8课：像素输出保持至接收，暂停文件字节流；扇区已缓存，不暂停物理 SPI。
wire pixel_accept=(USE_PIXEL_READY==0) || pixel_ready;
assign file_ready=(state==HEADER || (state==DATA && (!pixel_valid || pixel_accept))) && !abort;
wire take=file_valid && file_ready;
// HEADER only visits offsets 0..33. All 32-bit fields start at 2 modulo 4.
// Decode six offset bits and a two-bit lane, avoiding a 32-bit variable byte mux.
wire [1:0] header_lane=offset[1:0]-2'd2;
task fail;
    input [3:0] code;
    begin failed<=1; error_code<=code; write_req<=0; state<=IDLE; end
endtask
always @(posedge clk or posedge rst) begin
    if(rst) begin
        state<=IDLE; done<=0; failed<=0; error_code<=0; write_req<=0; pixel_valid<=0; pixel_data<=0;
        offset<=0; file_len<=0; pixel_offset<=0; dib_size<=0; width<=0; height<=0; compression<=0;
        size_latched<=0; planes<=0; bit_count<=0; magic0<=0; magic1<=0;
        required_end<=0; dib_end<=0; row_bytes<=0; row_stride<=0; expected_pixels<=0;
        pixel_count<=0; byte_in_row<=0; component<=0; timer<=0; header_ok<=0; stream_finished<=0;
        timed_out<=0; in_window<=0; end_offset_ok<=0; end_pixels_ok<=0;
    end else begin
        timed_out<={32'd0,timer}>=LIMIT;
        in_window<=take ? win_next : win_hold;
        end_offset_ok<=offset==size_latched;
        end_pixels_ok<=pixel_count==expected_pixels;
        done<=0; failed<=0;
        if(pixel_accept) pixel_valid<=0;
        if(state==IDLE || take || (state==WAIT_ACK && write_ack) || file_done) timer<=0;
        else timer<=timer+1'b1;
        if(file_done) stream_finished<=1;
        if(abort) begin state<=IDLE; write_req<=0; pixel_valid<=0;end
        else if(state!=IDLE && file_failed) fail(4'd8);
        else if(state!=IDLE && timed_out) begin timer<=0; fail(state==WAIT_ACK ? 4'd4:4'd2); end
        else begin
            if(take) offset<=offset+1'b1;
            case(state)
                IDLE: if(start) begin
                    state<=HEADER; offset<=0; pixel_count<=0; byte_in_row<=0; component<=0;
                    size_latched<=directory_size; stream_finished<=0; error_code<=0;
                    magic0<=0; magic1<=0; file_len<=0; pixel_offset<=0; dib_size<=0;
                    width<=0; height<=0; planes<=0; bit_count<=0; compression<=0;
                    row_bytes<=0; row_stride<=0; expected_pixels<=0;
                end
                HEADER: begin
                    // 第11讲时序审查：HEADER 的 ready 恒为 1（abort 已在外层处理）。
                    // 头字段使能直接取 file_valid，去掉像素 FIFO ready 到头解析的长组合路径。
                    if(file_valid) begin
                        case(offset[5:0])
                            0:magic0<=file_data; 1:magic1<=file_data;
                            2,3,4,5:file_len[header_lane*8 +: 8]<=file_data;
                            10,11,12,13:pixel_offset[header_lane*8 +: 8]<=file_data;
                            14,15,16,17:dib_size[header_lane*8 +: 8]<=file_data;
                            18,19,20,21:width[header_lane*8 +: 8]<=file_data;
                            22,23,24,25:height[header_lane*8 +: 8]<=file_data;
                            26:planes[7:0]<=file_data; 27:planes[15:8]<=file_data;
                            28:bit_count[7:0]<=file_data; 29:bit_count[15:8]<=file_data;
                            30,31,32,33:compression[header_lane*8 +: 8]<=file_data;
                        endcase
                        if(offset[5:0]==33) state<=CHECK0;
                    end
                    if(file_done) fail(4'd1);
                end
                CHECK0: begin
                    // Sizes from the header. Out-of-range values are rejected in CHECK2; the
                    // 11-bit products below are only used once the range check has passed.
                    // narrow arithmetic (≤ 2047 wide/high): 13-bit row sizes, 22-bit pixel count
                    row_bytes<={2'b00,width[10:0]}+{1'b0,width[10:0],1'b0};
                    row_stride<=({2'b00,width[10:0]}+{1'b0,width[10:0],1'b0}+13'd3)&~13'd3;
                    expected_pixels<={11'd0,width[10:0]}*{11'd0,height[10:0]};
                    state<=CHECK1;
                end
                CHECK1: begin
                    required_end<={2'b0,pixel_offset}+{10'd0,{11'd0,row_stride}*{13'd0,height[10:0]}};
                    dib_end<={2'b0,dib_size}+34'd14;
                    state<=CHECK2;
                end
                CHECK2: begin
                    header_ok<=magic0=="B" && magic1=="M" && planes==1 && bit_count==24 && compression==0 &&
                        width>=MIN_W && width<=MAX_W && height>=MIN_H && height<=MAX_H &&
                        (dib_size==40 || dib_size==52 || dib_size==56 || dib_size==108 || dib_size==124) &&
                        {2'b0,pixel_offset}>=dib_end && pixel_offset<file_len && required_end<={2'b0,file_len} &&
                        file_len<=size_latched && size_latched<=MAX_BMP_BYTES;
                    state<=CHECK3;
                end
                CHECK3: if(header_ok) begin write_req<=1; state<=WAIT_ACK; end else fail(4'd1);
                WAIT_ACK: if(write_ack) begin write_req<=0; state<=DATA; end
                DATA: begin
                    if(take && in_window) begin
                        byte_in_row<=(byte_in_row+13'd1>=row_stride) ? 13'd0:byte_in_row+13'd1;
                        if(byte_in_row<row_bytes) begin
                            case(component)
                                0:pixel_data[7:0]<=file_data;
                                1:pixel_data[15:8]<=file_data;
                                2:begin pixel_data[23:16]<=file_data; pixel_valid<=1; pixel_count<=pixel_count+1'b1; end
                            endcase
                            component<=(component==2) ? 0:component+1'b1;
                        end
                    end
                    if(file_done || stream_finished) state<=FINISH0;
                end
                FINISH0: state<=FINISH;
                FINISH: if(!pixel_valid || pixel_accept) begin
                    if(end_offset_ok && end_pixels_ok && component==0) begin done<=1; state<=IDLE; end
                    else fail(4'd3);
                end
                default: state<=IDLE;
            endcase
        end
    end
end
endmodule
