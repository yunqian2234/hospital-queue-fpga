`timescale 1ns/1ps
// 第11讲：课程规定的 s16le/48kHz/mono 数据，由 FAT32 streamer 提供字节。
// 背景循环的各圈共用连续FIFO，直到真正file_done/failed；BRAM不清零，Gray在源域生成。
module wav_stream_player #(
 parameter integer ADDR_WIDTH=12,PREFILL_SAMPLES=256,SECTOR_SAMPLES=256
)(
 input wr_clk,wr_rst_n,stream_start,file_valid,input [7:0] file_data,
 output file_ready,sector_ready,input file_done,file_failed,
 input rd_clk,rd_rst_n,sample_tick,sample_ready,
 output reg signed [15:0] sample_out,output reg sample_valid,
 output sample_silence,stream_active,output reg stream_end,
 output buffer_low,output reg underflow,output reg [31:0] sample_counter
);
localparam integer DEPTH=1<<ADDR_WIDTH;
reg [15:0] buffer[0:DEPTH-1];
reg [ADDR_WIDTH:0] wr_binary,wr_gray,rd_binary,rd_gray;
reg [ADDR_WIDTH:0] rd_gray_sync1,rd_gray_sync2,wr_gray_sync1,wr_gray_sync2; /* synthesis keep */
wire [ADDR_WIDTH:0] wr_next=wr_binary+1'b1,rd_next=rd_binary+1'b1;
function [ADDR_WIDTH:0] from_gray;
 input [ADDR_WIDTH:0] g;integer i;begin
 from_gray[ADDR_WIDTH]=g[ADDR_WIDTH];
 for(i=ADDR_WIDTH-1;i>=0;i=i-1)from_gray[i]=from_gray[i+1]^g[i];
 end
endfunction
wire [ADDR_WIDTH:0] wr_level=wr_binary-from_gray(rd_gray_sync2);
wire [ADDR_WIDTH:0] rd_level=from_gray(wr_gray_sync2)-rd_binary;
wire full=wr_gray=={~rd_gray_sync2[ADDR_WIDTH:ADDR_WIDTH-1],rd_gray_sync2[ADDR_WIDTH-2:0]};
wire empty=rd_gray==wr_gray_sync2;
reg started_wr,ended_wr,lo_pending,room;
reg [7:0] lo_byte;
wire accept_byte=file_valid && file_ready;
wire write_sample=accept_byte && lo_pending;
assign file_ready=started_wr && !ended_wr && !full;
// 先有一整个扇区的空间才允许仲裁 grant，避免暂停音源时占住 TF 通道。
assign sector_ready=room;
always @(posedge wr_clk) if(write_sample)buffer[wr_binary[ADDR_WIDTH-1:0]]<={file_data,lo_byte};
always @(posedge wr_clk or negedge wr_rst_n) begin
 if(!wr_rst_n)begin
  wr_binary<=0;wr_gray<=0;rd_gray_sync1<=0;rd_gray_sync2<=0;
  started_wr<=0;ended_wr<=0;lo_pending<=0;lo_byte<=0;room<=0;
 end else begin
  rd_gray_sync1<=rd_gray;rd_gray_sync2<=rd_gray_sync1;
  room<=wr_level<=DEPTH-SECTOR_SAMPLES-2;
  if(stream_start)started_wr<=1;
  if(accept_byte)begin
   if(!lo_pending)begin lo_byte<=file_data;lo_pending<=1;end
   else begin wr_binary<=wr_next;wr_gray<=wr_next^(wr_next>>1);lo_pending<=0;end
  end
  if(file_done || file_failed)ended_wr<=1;
 end
end
reg started_sync1,started_sync2,end_sync1,end_sync2; /* synthesis keep */
reg end_guard1,end_guard2,primed,ever_primed,read_pending,head_valid,out_pcm;
reg [15:0] ram_read,head_data;
wire fetch=primed && !empty && !read_pending && !head_valid;
wire take=sample_tick && sample_ready && sample_valid;
assign stream_active=started_sync2 && !stream_end;
assign sample_silence=!out_pcm;
assign buffer_low=rd_level<(DEPTH/4);
// 同步 RAM 读，避免把 reg 数组综合成大量 LUT；数据先预取，再对外保持 valid。
always @(posedge rd_clk) if(fetch)ram_read<=buffer[rd_binary[ADDR_WIDTH-1:0]];
always @(posedge rd_clk or negedge rd_rst_n)begin
 if(!rd_rst_n)begin
  rd_binary<=0;rd_gray<=0;wr_gray_sync1<=0;wr_gray_sync2<=0;
  started_sync1<=0;started_sync2<=0;end_sync1<=0;end_sync2<=0;end_guard1<=0;end_guard2<=0;
  primed<=0;ever_primed<=0;read_pending<=0;head_valid<=0;head_data<=0;
  sample_out<=0;sample_valid<=0;out_pcm<=0;stream_end<=0;underflow<=0;sample_counter<=0;
 end else begin
  wr_gray_sync1<=wr_gray;wr_gray_sync2<=wr_gray_sync1;
  started_sync1<=started_wr;started_sync2<=started_sync1;
  end_sync1<=ended_wr;end_sync2<=end_sync1;end_guard1<=end_sync2;end_guard2<=end_guard1;
  underflow<=0;
  if(!primed && (rd_level>=PREFILL_SAMPLES || (end_guard2 && !empty)))begin primed<=1;ever_primed<=1;end
  if(primed && empty && !head_valid && !read_pending && !out_pcm)primed<=0;
  if(fetch)read_pending<=1;
  if(read_pending)begin
   head_data<=ram_read;head_valid<=1;read_pending<=0;
   rd_binary<=rd_next;rd_gray<=rd_next^(rd_next>>1);
  end
  // 真实样本/静音均保持到 ready；未选中音源不能消耗样本或丢掉 valid。
  if(!sample_valid || take)begin
   sample_valid<=1;sample_out<=head_valid ? head_data:16'd0;out_pcm<=head_valid;
   if(head_valid)head_valid<=0;
  end
  if(take && out_pcm)sample_counter<=sample_counter+1'b1;
  if(take && !out_pcm && stream_active && ever_primed && !end_guard2)underflow<=1;
  // 等最后的同步指针稳定，并把预取槽/输出槽的最后样本全部交付才报结束。
  if(started_sync2 && end_guard2 && empty && !read_pending && !head_valid && !out_pcm)stream_end<=1;
 end
end
endmodule
