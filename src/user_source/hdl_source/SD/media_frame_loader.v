// 第8课：有序 START/PIXEL/COMMIT/ABORT 异步流，四个固定帧区。
// 已完成的 bank 不再写；结果在最后一次突发退出并经过控制器收尾后发布。
module media_frame_loader #(
 parameter WIDTH=640, HEIGHT=480, BURST=128, STALL_CYCLES=125000000
)(
 input src_clk,src_rst,mem_clk,mem_rst,
 input load_start,input [1:0] image_index,output load_ready,
 input pixel_valid,input [23:0] pixel_rgb,output pixel_ready,
 input frame_commit,frame_abort,output reg load_done,output reg [3:0] load_error,
 input controller_ready,controller_busy,
 output reg [3:0] image_complete,
 output burst_request,input burst_grant,output reg burst_done,
 output app_wr_en,output [20:0] app_wr_addr,output [31:0] app_wr_data
);
localparam WORDS=WIDTH*HEIGHT;
localparam IDLE=0,FILL=1,ASK=2,PRIME=3,WRITE=4,RETIRE=5,DROP=6;
wire fifo_rst=src_rst|mem_rst;
wire full,almost_full,empty,raw_valid,pop,have;
wire [31:0] raw_data,token;
reg source_active,end_pending,end_abort;
reg fifo_blocked;
// Break FIFO pointer subtraction -> BMP/file-stream ready timing. Threshold 500
// leaves >10 spare entries, so this one-cycle registered stop cannot overflow.
always @(posedge src_clk or posedge src_rst)
 if(src_rst) fifo_blocked<=1;else fifo_blocked<=almost_full|full;
wire ready_sd;
cdc_level u_ready(.clk(src_clk),.rst(src_rst),.async_in(controller_ready),.level_out(ready_sd));
assign load_ready=!source_active && !fifo_blocked && ready_sd;
assign pixel_ready=source_active && !end_pending && !fifo_blocked;
wire begin_take=load_start && load_ready;
wire end_take=source_active && end_pending && !fifo_blocked;
wire pixel_take=pixel_valid && pixel_ready && !frame_abort;
wire fifo_write=begin_take || end_take || pixel_take;
wire [31:0] fifo_data=begin_take ? {2'b01,28'd0,image_index} :
                     end_take ? {end_abort ? 2'b11:2'b10,30'd0} : {8'd0,pixel_rgb};
reg result_toggle;
reg [3:0] result_error;
wire [4:0] result_sd;
reg result_seen;
cdc_status #(.WIDTH(5)) u_result_status(
 .src_clk(mem_clk),.src_rst(mem_rst),.src_data({result_toggle,result_error}),
 .dst_clk(src_clk),.dst_rst(src_rst),.dst_data(result_sd));
always @(posedge src_clk or posedge src_rst) begin
 if(src_rst) begin source_active<=0;end_pending<=0;end_abort<=0;load_done<=0;load_error<=0;result_seen<=0;end
 else begin
  load_done<=0;
  if(begin_take) begin source_active<=1;end_pending<=0;end_abort<=0;load_error<=0;end
  if(source_active && (frame_commit || frame_abort)) begin end_pending<=1;end_abort<=frame_abort;end
  if(end_take) end_pending<=0;
  if(result_sd[4]!=result_seen) begin
   result_seen<=result_sd[4];load_error<=result_sd[3:0];load_done<=1;source_active<=0;end_pending<=0;
  end
 end
end
// prefetch expects one valid pulse per read request (the vendor default is show-ahead).
wfifo_32_32_512 #(.AL_FULL_NUM(500),.SHOW_AHEAD_EN(1'b0)) u_stream_fifo(
 .rst(fifo_rst),.clkw(src_clk),.clkr(mem_clk),.we(fifo_write),.di(fifo_data),
 .re(pop),.dout(raw_data),.valid(raw_valid),.full_flag(full),.afull(almost_full),
 .empty_flag(empty),.aempty(),.wrusedw(),.rdusedw());
wire consume;
fifo_prefetch_2 u_prefetch(.clk(mem_clk),.rst(mem_rst),.raw_empty(empty),
 .raw_valid(raw_valid),.raw_data(raw_data),.raw_read_en(pop),.consume(consume),
 .out_valid(have),.out_empty(),.out_data(token));
reg [2:0] state;
reg [1:0] bank;
reg [23:0] block_mem[0:BURST-1];
reg [23:0] ram_data;
reg [$clog2(BURST):0] fill_count,read_index,burst_words;
reg [20:0] received,written,address;
reg [15:0] x;
reg committed;
reg [4:0] guard;
reg [31:0] timer;
assign consume=have && (state==IDLE || state==FILL || state==DROP);
assign burst_request=(state==ASK);
assign app_wr_en=(state==WRITE);
assign app_wr_addr=address;
assign app_wr_data={8'd0,ram_data};
function [20:0] base; input [1:0] i; begin
 case(i) 0:base=0;1:base=WORDS;2:base=WORDS*2;default:base=WORDS*3;endcase end endfunction
task result; input [3:0] code; begin
 result_error<=code;result_toggle<=~result_toggle;state<=IDLE;fill_count<=0;committed<=0;
end endtask
// 同步 BRAM 读；PRIME 预取首字，WRITE 每拍输出一个完整、连续的字。
// One physical read port: use a single address mux so TD infers block RAM.
wire [$clog2(BURST)-1:0] ram_read_address=(state==PRIME) ? 0:read_index+1'b1;
always @(posedge mem_clk) begin
 if(consume && state==FILL && token[31:30]==0 && received<WORDS)
  block_mem[fill_count[$clog2(BURST)-1:0]]<=token[23:0];
 if(state==PRIME || state==WRITE) ram_data<=block_mem[ram_read_address];
end
always @(posedge mem_clk or posedge mem_rst) begin
 if(mem_rst) begin
  state<=IDLE;bank<=0;fill_count<=0;read_index<=0;burst_words<=0;received<=0;written<=0;
  address<=0;x<=0;committed<=0;guard<=0;timer<=0;burst_done<=0;
  image_complete<=0;result_toggle<=0;result_error<=0;
 end else begin
  burst_done<=0;
  if(state==IDLE || consume || state==WRITE) timer<=0;
  else if(timer<STALL_CYCLES) timer<=timer+1'b1;
  case(state)
   IDLE: if(consume && token[31:30]==1) begin
    bank<=token[1:0];received<=0;written<=0;fill_count<=0;committed<=0;x<=0;
    address<=base(token[1:0])+(HEIGHT-1)*WIDTH;
    state<=image_complete[token[1:0]] ? DROP:FILL;
   end
   FILL: if(consume) begin
    case(token[31:30])
     0: if(received>=WORDS) state<=DROP;
        else begin
         received<=received+1'b1;fill_count<=fill_count+1'b1;
         if(fill_count==BURST-1) begin burst_words<=BURST;state<=ASK;end
        end
     2: if(received!=WORDS) result(4'd9);
        else if(fill_count!=0) begin committed<=1;burst_words<=fill_count;state<=ASK;end
        else begin image_complete[bank]<=1;result(0);end
     3: result(4'd9);
     default: state<=DROP;
    endcase
   end
   ASK: if(burst_grant) begin read_index<=0;state<=PRIME;end
   PRIME: state<=WRITE;
   WRITE: begin
    written<=written+1'b1;
    if(x==WIDTH-1) begin x<=0;address<=address-(WIDTH*2-1);end
    else begin x<=x+1'b1;address<=address+1'b1;end
    if(read_index+1==burst_words) begin state<=RETIRE;guard<=0;end
    else read_index<=read_index+1'b1;
   end
   RETIRE: begin
    if(guard!=31) guard<=guard+1'b1;
    if(guard>=16 && !controller_busy) begin
     burst_done<=1;fill_count<=0;
     if(committed) begin
      if(written==WORDS) begin image_complete[bank]<=1;result(0);end else result(4'd9);
     end else state<=FILL;
    end
   end
   DROP: if(consume && token[31:30]>=2) result(4'd9);
   default: state<=IDLE;
  endcase
  // 无响应不能永久占住仲裁器；超时 bank 永不置 complete。
  if(state!=IDLE && timer>=STALL_CYCLES) begin burst_done<=1;result(4'd9);end
 end
end
endmodule
