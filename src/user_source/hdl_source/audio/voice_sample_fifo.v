`timescale 1ns/1ps
// 阶段C：语音样本异步 FIFO（SD 100MHz 写 -> 音频 12.288MHz 读）。
// 17 位：bit16=句尾标记，bit15:0=s16 样本。Gray 指针两级同步，额外回绕位区分满/空。
// 同步读 RAM（rd_en 后一拍 rd_data 有效），适配片上块 RAM；两侧由同一系统复位同时清零。
module voice_sample_fifo #(parameter integer ADDR_WIDTH=11)(
    input wr_clk, wr_rst, wr_en, input [16:0] wr_data,
    output reg [ADDR_WIDTH:0] wr_free,
    input rd_clk, rd_rst, rd_en, output reg [16:0] rd_data,
    output rd_empty
);
localparam integer DEPTH=1<<ADDR_WIDTH;
reg [16:0] mem [0:DEPTH-1];
reg [ADDR_WIDTH:0] wr_bin, wr_gray, rd_bin, rd_gray;
reg [ADDR_WIDTH:0] rd_gray_s1, rd_gray_s2, wr_gray_s1, wr_gray_s2; /* synthesis keep */
function [ADDR_WIDTH:0] from_gray;
    input [ADDR_WIDTH:0] g; integer i;
    begin
        from_gray[ADDR_WIDTH]=g[ADDR_WIDTH];
        for(i=ADDR_WIDTH-1;i>=0;i=i-1) from_gray[i]=from_gray[i+1]^g[i];
    end
endfunction
wire [ADDR_WIDTH:0] wr_next=wr_bin+1'b1, rd_next=rd_bin+1'b1;
wire [ADDR_WIDTH:0] used_w=wr_bin-from_gray(rd_gray_s2);
assign rd_empty=(rd_gray==wr_gray_s2);
// 写侧只在 wr_free 非零时写；wr_free 为寄存值，保守（可能少报，不会多报）。
always @(posedge wr_clk) if(wr_en) mem[wr_bin[ADDR_WIDTH-1:0]]<=wr_data;
always @(posedge wr_clk or posedge wr_rst) begin
    if(wr_rst) begin
        wr_bin<=0; wr_gray<=0; rd_gray_s1<=0; rd_gray_s2<=0; wr_free<=0;
    end else begin
        rd_gray_s1<=rd_gray; rd_gray_s2<=rd_gray_s1;
        if(wr_en) begin wr_bin<=wr_next; wr_gray<=wr_next^(wr_next>>1); end
        // 本拍写入后的余量；下一拍才可见，写侧每拍最多写一次。
        wr_free<=DEPTH-used_w-(wr_en ? 1'b1:1'b0);
    end
end
always @(posedge rd_clk) if(rd_en && !rd_empty) rd_data<=mem[rd_bin[ADDR_WIDTH-1:0]];
always @(posedge rd_clk or posedge rd_rst) begin
    if(rd_rst) begin
        rd_bin<=0; rd_gray<=0; wr_gray_s1<=0; wr_gray_s2<=0;
    end else begin
        wr_gray_s1<=wr_gray; wr_gray_s2<=wr_gray_s1;
        if(rd_en && !rd_empty) begin rd_bin<=rd_next; rd_gray<=rd_next^(rd_next>>1); end
    end
end
endmodule
