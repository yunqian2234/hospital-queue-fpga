// 第8课：视频域提交图片；只有 active_index 用于画面、数码管和音频。
module media_player_control #(
 parameter CLK_HZ=25000000,DEBOUNCE_MS=20,LONG_MS=1000,AUTO_MS=3000,
 parameter TRANSITIONS=0,ENABLE_THUMBNAILS=0,ENABLE_PAUSE=0,KEY_EVENT_INPUT=0
)(input clk,rst,key_next,key_auto,frame_start,
 input [3:0] available_mask,failed_mask,image_complete,
 output reg [1:0] active_index,output reg display_valid,output reg index_commit,
 output reg auto_enabled,output reg retry_toggle,
 // 第10课：保留消抖/长按/忙时单槽队列；仅将手动提交延后到全黑。
 input transition_allow,transition_busy,output reg transition_request,
 input thumbnail_mode,input interaction_pause,
 // Optional already-debounced board inputs; the legacy standalone path remains.
 input key_next_event,key_auto_pressed,key_auto_release_event,key_auto_cancel);
wire paused=ENABLE_PAUSE!=0 && interaction_pause;
// 缩略图中 active_index 就是 focus_index，沿用坏图跳过、队列和轮播。
wire use_transition=TRANSITIONS && !(ENABLE_THUMBNAILS && thumbnail_mode);
wire next_press,auto_stable;
generate if(KEY_EVENT_INPUT!=0) begin:g_key_events
 assign next_press=key_next_event;
 assign auto_stable=~key_auto_pressed;
end else begin:g_raw_keys
 key_press_debounce #(.CLK_FREQ_HZ(CLK_HZ),.DEBOUNCE_MS(DEBOUNCE_MS)) u_next(
  .clk(clk),.rst(rst),.button_in(key_next),.press_pulse(next_press),.button_stable_out());
 key_press_debounce #(.CLK_FREQ_HZ(CLK_HZ),.DEBOUNCE_MS(DEBOUNCE_MS)) u_auto(
  .clk(clk),.rst(rst),.button_in(key_auto),.press_pulse(),.button_stable_out(auto_stable));
end endgenerate
localparam [63:0] AUTO_LIMIT=(64'd1*CLK_HZ/1000)*AUTO_MS;
localparam [63:0] LONG_LIMIT=(64'd1*CLK_HZ/1000)*LONG_MS;
reg [31:0] auto_count,long_count;
reg auto_stable_q,long_reached,pending;
reg pending_manual,queued_manual,manual_sent,manual_ready;
reg [1:0] pending_index,queued;
wire [3:0] eligible=(available_mask & ~failed_mask)|image_complete;
// KEY4 修复：按下只计时，消抖后的松开沿统一区分短/长按。
// long_reached 仅记住 >=1秒，不在达到门限时执行动作。
wire auto_release=KEY_EVENT_INPUT!=0 ?
 (key_auto_release_event && !key_auto_cancel):(auto_stable && !auto_stable_q);
wire previous_press=auto_release && long_reached;
wire auto_short_release=auto_release && !long_reached;
function [2:0] select_next;
 input [1:0] current;input backwards;input [3:0] mask;
 integer n;reg [1:0] idx;
 begin select_next=0;
  for(n=1;n<=4;n=n+1) begin
   idx=backwards ? current-n:current+n;
   if(!select_next[2] && mask[idx]) select_next={1'b1,idx};
  end
 end
endfunction
wire [2:0] first=select_next(2'd3,1'b0,eligible);
wire [2:0] next_choice=select_next(active_index,queued==2,eligible);
always @(posedge clk or posedge rst) begin
 if(rst) begin
  active_index<=0;display_valid<=0;index_commit<=0;auto_enabled<=0;retry_toggle<=0;
  auto_count<=0;long_count<=0;auto_stable_q<=1;long_reached<=0;pending<=0;pending_index<=0;queued<=0;
  pending_manual<=0;queued_manual<=0;manual_sent<=0;manual_ready<=0;transition_request<=0;
 end else begin
  index_commit<=0;
  transition_request<=0;
  if(TRANSITIONS && transition_allow && manual_sent) manual_ready<=1;
  auto_stable_q<=auto_stable;
  if(auto_stable || (KEY_EVENT_INPUT!=0 && key_auto_cancel)) begin long_count<=0;long_reached<=0;end
  else if(!long_reached) begin
   if({32'd0,long_count}>=LONG_LIMIT-1) long_reached<=1;
   else long_count<=long_count+1'b1;
  end
  // 短按保留原轮播开关行为，只把生效时点移到松开沿。
  if(auto_short_release) begin auto_enabled<=~auto_enabled;auto_count<=0;end
  else if(!paused && auto_enabled && !previous_press && display_valid && !pending && queued==0) begin
   if({32'd0,auto_count}<AUTO_LIMIT-1) auto_count<=auto_count+1'b1;
   else begin queued<=1;queued_manual<=0;auto_count<=0;end
  end
  // 首张按最小文件编号；坏图跳过。未加载目标保持 pending，不显示半帧。
  if(!display_valid && !pending && first[2]) begin
   pending<=1;pending_index<=first[1:0];queued<=0;
   pending_manual<=0;manual_sent<=0;manual_ready<=0;
  end else if(!paused && display_valid && !pending && queued!=0 && next_choice[2] && !previous_press &&
              (!use_transition || !transition_busy)) begin
   pending<=1;pending_index<=next_choice[1:0];queued<=0;
   pending_manual<=queued_manual && next_choice[1:0]!=active_index;
   manual_sent<=0;manual_ready<=0;
  end
  if(!paused && use_transition && pending && pending_manual && image_complete[pending_index] &&
     !manual_sent && !transition_busy) begin
   transition_request<=1;manual_sent<=1;
  end
  if(pending && !eligible[pending_index]) begin
   pending<=0;manual_sent<=0;manual_ready<=0;
   if(display_valid) begin queued<=1;queued_manual<=pending_manual;end
  end else if(frame_start && (!paused || !display_valid) && pending && image_complete[pending_index] && !previous_press &&
              (!use_transition || !pending_manual || manual_ready)) begin
   active_index<=pending_index;display_valid<=1;index_commit<=1;pending<=0;auto_count<=0;
   manual_sent<=0;manual_ready<=0;
  end
  // 单槽保留忙时一次请求；同拍按键优先于清队列/自动计时。
  if(next_press) begin queued<=1;queued_manual<=1;retry_toggle<=~retry_toggle;end
  if(previous_press) begin
   // 长按始终回到手动，排队一次上一张；不允许旧自动请求再偷切一张。
   auto_enabled<=0;auto_count<=0;queued<=display_valid ? 2'd2:2'd0;queued_manual<=1;
   if(display_valid && pending && !pending_manual) begin
    pending<=0;manual_sent<=0;manual_ready<=0;
   end
   // 已开始的 KEY2 手动转场保留；本次回退沿用单槽队列等待其结束。
  end
 end
end
endmodule
