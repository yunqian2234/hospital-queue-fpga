// 第8课：一帧只锁存一个 bank，完整读突发收齐后才能换帧/交接写通道。
module media_frame_reader #(
 parameter WORDS=307200,BURST=128,TIMEOUT_CYCLES=125000000,
 parameter WIDTH=640,ENABLE_WIPE=0,ENABLE_THUMBNAILS=0,
 parameter THUMB_WIDTH=WIDTH/4,THUMB_HEIGHT=(WORDS/WIDTH)/4
)(
 input mem_clk,mem_rst,pix_clk,pix_rst,controller_ready,controller_busy,
 input frame_start,display_valid,input [1:0] active_index,input pixel_consume,
 // 第10课：冻结整帧的 bank/边界描述符，按行分段读旧图/新图。
 input wipe_active,input [1:0] wipe_old_index,input [11:0] wipe_boundary,
 // 第13讲：整帧描述符跨域；布局使用预取坐标，不能等当前像素再读 SDRAM。
 input thumbnail_mode,input [3:0] image_complete,
 output [11:0] fetch_x,fetch_y,output [3:0] fetch_complete,
 input fetch_valid,input [1:0] source_index,input [9:0] source_x,source_y,
 output [23:0] pixel_rgb,output pixel_valid,output reg underflow,
 output reg [3:0] reader_error,
 output burst_request,input burst_grant,output reg burst_done,
 output app_rd_en,output [20:0] app_rd_addr,
 input sdram_rd_valid,input [31:0] sdram_rd_data
);
localparam IDLE=0,RESET_FIFO=1,READY=2,ISSUE=3,DRAIN=4,HALT=5,
           PLAN_DIFF=6,PLAN_LIMIT=7,PLAN_TARGET=8,PLAN_ROW=9,PLAN_WAIT=10;
reg [3:0] state;
reg request_toggle,request_wait;
reg [1:0] request_index;
reg request_wipe;
reg request_thumb;
reg [3:0] request_complete;
reg thumb_mem;
reg [3:0] complete_mem;
reg [11:0] thumb_column,thumb_row;
reg [20:0] thumb_row_address;
reg [9:0] thumb_source_x,thumb_source_y;
reg thumb_segment_valid;
reg [8:0] thumb_limit;
assign fetch_x=thumb_column;
assign fetch_y=thumb_row;
assign fetch_complete=complete_mem;
// 阶段C时序：外部组合布局(thumbnail_layout)的结果先寄存一拍再进入 PLAN_DIFF。
// 原路径 thumb_column -> 两级比较/减法 -> PLAN_DIFF 采样 -> 行地址乘法器输入寄存器
// 共 9 级，125MHz 下为 -0.396ns。寄存后 PLAN_DIFF 使用上一拍坐标的布局结果，
// 因此坐标刚改变的那一拍不得进入 PLAN_DIFF（见 PLAN_WAIT）。
reg layout_valid_q;
reg [1:0] layout_index_q;
reg [9:0] layout_x_q,layout_y_q;
always @(posedge mem_clk) begin
 layout_valid_q<=fetch_valid;layout_index_q<=source_index;
 layout_x_q<=source_x;layout_y_q<=source_y;
end
reg [1:0] request_old_index;
reg [11:0] request_boundary;
reg req0,req1,req2,request_seen,ack_toggle,ack0,ack1,ack2;
reg frame_ok,request_pending;
reg [20:0] consumed;
reg [1:0] index_mem;
reg wipe_mem;
reg [1:0] old_index_mem;
reg [11:0] boundary_mem,column;
reg [20:0] issued,address;
reg [8:0] sent,returned,target;
reg [4:0] reset_count,guard;
reg reload_pending,fault;
reg [31:0] timer;
wire fifo_reset=mem_rst|pix_rst|(reset_count!=0);
wire full,empty,raw_valid,raw_read,prefetch_valid;
wire [8:0] used;
wire [31:0] raw_data,prefetch_data;
assign pixel_valid=prefetch_valid && frame_ok && display_valid;
assign pixel_rgb=pixel_valid ? prefetch_data[23:0]:24'd0;
wire consume=pixel_consume && pixel_valid;
always @(posedge pix_clk or posedge pix_rst) begin
 if(pix_rst) begin
  request_toggle<=0;request_wait<=0;request_index<=0;request_pending<=0;
  request_wipe<=0;request_old_index<=0;request_boundary<=0;
  request_thumb<=0;request_complete<=0;
  ack0<=0;ack1<=0;ack2<=0;frame_ok<=0;underflow<=0;consumed<=0;
 end else begin
  ack0<=ack_toggle;ack1<=ack0;ack2<=ack1;
  // A late acknowledgement must not restart pixels halfway through a failed frame.
  if(request_wait && ack2==request_toggle) begin request_wait<=0;frame_ok<=!underflow;end
  if(frame_start) begin
   frame_ok<=0;consumed<=0;underflow<=0;
   if(!request_wait) request_pending<=1;
   else if(display_valid) underflow<=1;
  end else if(request_pending) begin
   // control 在 frame_start 更新 active_index；下一拍才捕获。
   if(display_valid) begin
    request_index<=active_index;request_toggle<=~request_toggle;request_wait<=1;
    request_wipe<=ENABLE_WIPE && wipe_active;request_old_index<=wipe_old_index;
    request_thumb<=ENABLE_THUMBNAILS && thumbnail_mode;request_complete<=image_complete;
    request_boundary<=wipe_boundary>WIDTH ? WIDTH:wipe_boundary;
   end
   request_pending<=0;
  end
  if(pixel_consume && display_valid) begin
   if(pixel_valid) consumed<=consumed+1'b1;
   else begin underflow<=1;frame_ok<=0;end // 本帧余下输出黑色，不错位续播。
  end
 end
end
wire have_returns=(state==ISSUE || state==DRAIN);
// 连续源图 burst 每四字保留首字；返回计数仍统计全部源字，保证正确收尾。
wire keep_return=!thumb_mem || returned[1:0]==0;
// 阶段C时序：SDRAM 返回字先寄存一拍再写 FIFO。原来 full(指针减法+比较) 还要经过
// 返回有效/状态/复位的组合与门才到 FIFO 写地址 CE，125MHz 下余量只有 0.08~0.27ns，
// 设计变大后为 -0.33ns。寄存后 full 只与一位 wr_stage_valid 相与。
// 单突发在途、fifo_room 预留 BURST+16 空位，多一拍在途不会溢出；DRAIN 至少等 16 拍。
// FIFO 复位在 IP 内再同步两拍，复位边沿那一拍的写入会被随后的复位清掉。
reg wr_stage_valid;
reg [31:0] wr_stage_data;
always @(posedge mem_clk or posedge mem_rst)
 if(mem_rst) wr_stage_valid<=0;
 else wr_stage_valid<=sdram_rd_valid && have_returns && keep_return && !fifo_reset;
always @(posedge mem_clk) wr_stage_data<=sdram_rd_data;
wire fifo_we=wr_stage_valid && !full;
rfifo_32_32_512 u_read_fifo(
 .rst(fifo_reset),.clkw(mem_clk),.clkr(pix_clk),.we(fifo_we),.di(wr_stage_data),
 .re(raw_read),.dout(raw_data),.valid(raw_valid),.full_flag(full),.empty_flag(empty),
 .afull(),.aempty(),.wrusedw(used),.rdusedw());
// Frame flush is asserted in mem_clk; release the pixel registers synchronously.
wire prefetch_reset;
reset_sync u_prefetch_reset(.clk(pix_clk),.arst(fifo_reset),.rst(prefetch_reset));
fifo_prefetch_2 u_prefetch(.clk(pix_clk),.rst(prefetch_reset),.raw_empty(empty),
 .raw_valid(raw_valid),.raw_data(raw_data),.raw_read_en(raw_read),.consume(consume),
 .out_valid(prefetch_valid),.out_empty(),.out_data(prefetch_data));
function [20:0] base; input [1:0] i; begin
 case(i) 0:base=0;1:base=WORDS;2:base=WORDS*2;default:base=WORDS*3;endcase end endfunction
// 水平 Wipe 每像素仍只读一次；突发不得越过一行或新旧 bank 边界。
// 不用 issued % WIDTH，避免在 125MHz 地址链上引入除法器。
// 第10课时序审查：减法、限幅、取最小值分三拍准备，不能串在一个 8ns 周期。
reg [20:0] remaining,burst_base,planned_address;
reg [11:0] line_left,new_left;
reg [8:0] frame_limit,line_limit,new_limit;
reg use_new;
wire [1:0] selected_bank=(!wipe_mem || column<boundary_mem) ? index_mem:old_index_mem;
// 单突发在途：FIFO 的空位只需为这一整个突发预留，不假定返回固定延迟。
// 第10课时序审查：空位比较先寄存，截断 FIFO 指针->仲裁->写通道的长组合链。
// READY 时上一突发已收齐，FIFO 占用只会下降；延迟一拍的空位许可是保守的。
reg fifo_room;
always @(posedge mem_clk or posedge mem_rst)
 if(mem_rst) fifo_room<=0;
 else fifo_room<=!full && used<=512-BURST-16;
assign burst_request=state==READY && !reload_pending && controller_ready &&
                     fifo_room && (thumb_mem ? thumb_row<2*THUMB_HEIGHT:issued<WORDS);
assign app_rd_en=(state==ISSUE);
assign app_rd_addr=address;
always @(posedge mem_clk or posedge mem_rst) begin
 if(mem_rst) begin
  state<=IDLE;req0<=0;req1<=0;req2<=0;request_seen<=0;ack_toggle<=0;index_mem<=0;
  wipe_mem<=0;old_index_mem<=0;boundary_mem<=0;column<=0;
  thumb_mem<=0;complete_mem<=0;thumb_column<=0;thumb_row<=0;
  thumb_row_address<=0;thumb_source_x<=0;thumb_source_y<=0;thumb_segment_valid<=0;thumb_limit<=0;
  remaining<=0;burst_base<=0;planned_address<=0;line_left<=0;new_left<=0;
  frame_limit<=0;line_limit<=0;new_limit<=0;use_new<=0;
  issued<=0;address<=0;sent<=0;returned<=0;target<=0;reset_count<=0;guard<=0;
  reload_pending<=0;fault<=0;timer<=0;burst_done<=0;reader_error<=0;
 end else begin
  req0<=request_toggle;req1<=req0;req2<=req1;burst_done<=0;
  // 寄存后的返回字遇到满 FIFO 即会丢失，按原规则判为读取故障。
  if(wr_stage_valid && full) begin fault<=1;reader_error<=4'd10;end
  if(req2!=request_seen) begin
   request_seen<=req2;index_mem<=request_index;reload_pending<=1;
   wipe_mem<=request_wipe;old_index_mem<=request_old_index;boundary_mem<=request_boundary;
   thumb_mem<=request_thumb;complete_mem<=request_complete;
  end
  if(state==ISSUE || state==DRAIN) begin
   if(sdram_rd_valid) begin
    returned<=returned+1'b1;
    if(returned>=target) begin fault<=1;reader_error<=4'd10;end
    timer<=0;
   end else if(timer<TIMEOUT_CYCLES) timer<=timer+1'b1;
  end else timer<=0;
  case(state)
   IDLE,READY: if(reload_pending) begin
    reload_pending<=0;issued<=0;address<=base(index_mem);column<=0;
    thumb_column<=0;thumb_row<=0;
    reset_count<=16;state<=RESET_FIFO;reader_error<=0;
   end else if(burst_grant) begin
    sent<=0;returned<=0;
    address<=planned_address;
    if(wipe_mem) column<=(column+target==WIDTH) ? 12'd0:column+target;
    if(thumb_mem) begin
     if(thumb_column+(target>>2)==2*THUMB_WIDTH) begin thumb_column<=0;thumb_row<=thumb_row+1'b1;end
     else thumb_column<=thumb_column+(target>>2);
    end
    state<=ISSUE;guard<=0;
   end
   RESET_FIFO: if(reset_count!=0) reset_count<=reset_count-1'b1;
               else begin ack_toggle<=request_seen;state<=PLAN_DIFF;end
   PLAN_DIFF: begin
    remaining<=WORDS-issued;line_left<=WIDTH-column;new_left<=boundary_mem-column;
    use_new<=column<boundary_mem;burst_base<=base(thumb_mem ? layout_index_q:selected_bank);state<=PLAN_ROW;
    thumb_source_y<=layout_y_q;thumb_source_x<=layout_x_q;thumb_segment_valid<=layout_valid_q;
   end
   PLAN_ROW: begin
    // Separate the layout subtract/range checks from the row multiply at 125MHz.
    thumb_row_address<=thumb_source_y*WIDTH;state<=PLAN_LIMIT;
   end
   PLAN_LIMIT: begin
    frame_limit<=remaining>=BURST ? BURST:remaining[8:0];
    line_limit<=line_left>=BURST ? BURST:line_left[8:0];
    new_limit<=new_left>=BURST ? BURST:new_left[8:0];
    planned_address<=burst_base+(thumb_mem ? thumb_row_address:issued);state<=PLAN_TARGET;
    thumb_limit<=(WIDTH-thumb_source_x>=BURST) ? BURST:(WIDTH-thumb_source_x);
   end
   PLAN_TARGET: begin
    if(thumb_mem) begin
     target<=thumb_limit;planned_address<=planned_address+thumb_source_x;
    end else if(!wipe_mem) target<=frame_limit;
    else if(use_new && new_limit<frame_limit && new_limit<line_limit) target<=new_limit;
    else target<=frame_limit<line_limit ? frame_limit:line_limit;
    state<=READY;
    // 缺图跳过整个窗口，不写 FIFO；显示端也不消费该窗口，避免错位。
    if(thumb_mem && !thumb_segment_valid && thumb_row<2*THUMB_HEIGHT) begin
     if(thumb_column<THUMB_WIDTH) thumb_column<=THUMB_WIDTH;
     else begin thumb_column<=0;thumb_row<=thumb_row+1'b1;end
     state<=PLAN_WAIT;
    end
   end
   // 坐标刚在 PLAN_TARGET 更新，等一拍让 layout_*_q 采到新坐标的布局结果。
   PLAN_WAIT: state<=PLAN_DIFF;
   ISSUE: begin
    address<=address+1'b1;issued<=issued+1'b1;sent<=sent+1'b1;
    if(sent+1==target) begin state<=DRAIN;guard<=0;end
   end
   DRAIN: begin
    if(guard!=31) guard<=guard+1'b1;
    if(returned==target && guard>=16 && !controller_busy) begin
     burst_done<=1;state<=fault ? HALT:PLAN_DIFF;
    end
   end
   HALT: begin end // 真正丢失 SDRAM 返回时，等待系统复位，不能把迟到数据归入新帧。
   default:state<=IDLE;
  endcase
  if((state==ISSUE || state==DRAIN) && timer>=TIMEOUT_CYCLES) begin
   state<=HALT;reader_error<=4'd10;burst_done<=1;fault<=1;
  end
 end
end
endmodule
