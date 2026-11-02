`timescale 1ns/1ps
// 第10课：手动淡出->全黑提交->淡入，自动切图用旧/新 bank 水平揭示。
// ctrl_clk 与 pix_clk 可异步；所有可见状态/进度仅在 frame_start 更新。
module video_fade_transition #(
 parameter integer FADE_FRAMES=16,ENABLE_BYPASS=0,ENABLE_PAUSE=0
)(
 input ctrl_clk,ctrl_rst_n,next_event_in,
 output next_event_out,fade_busy,
 input pix_clk,pix_rst_n,player_active,frame_start,index_commit,
 input [1:0] active_index,
 output [7:0] alpha_out,output fade_active,wipe_active,
 output [8:0] ramp_out,output [1:0] transition_kind,old_index,
 input bypass,input interaction_pause
);
generate if(FADE_FRAMES==0) begin:g_bypass
 assign next_event_out=next_event_in;
 assign fade_busy=0;
 assign alpha_out=255;
 assign fade_active=0;
 assign wipe_active=0;
 assign ramp_out=0;
 assign transition_kind=0;
 assign old_index=active_index;
end else begin:g_fade
 localparam integer STEP=256/FADE_FRAMES;
 localparam integer CNT_W=$clog2(FADE_FRAMES+1);
 localparam [1:0] S_IDLE=0,S_OUT=1,S_HOLD=2,S_IN=3;
 reg [1:0] state,last_index,old_bank;
 reg [CNT_W-1:0] ramp;
 reg wipe_mode,have_frame,paused_frame,commit_pending;
 wire committed=index_commit || commit_pending;
 reg req_toggle,ack_seen,request_pending;
 reg commit_sync1,commit_sync2,busy_sync1,busy_sync2; /* synthesis keep */
 reg req_sync1,req_sync2; /* synthesis keep */
 reg req_seen,commit_toggle;
 wire fade_running=(state!=S_IDLE);
 wire [15:0] ramp_alpha=ramp*STEP;
 assign fade_active=fade_running;
 assign fade_busy=request_pending|busy_sync2;
 assign next_event_out=commit_sync2!=ack_seen;
 assign wipe_active=(state==S_IN)&&wipe_mode;
 assign transition_kind=wipe_active ? 2'd1:2'd0;
 assign old_index=old_bank;
 // 9 位覆盖文档 32 帧及 256 帧，避免原 5-CNT_W 的负数拼接。
 assign ramp_out=ramp;
 assign alpha_out=(paused_frame && !wipe_mode) ? 8'd255:
                  (state==S_IDLE || wipe_active || ramp==FADE_FRAMES) ? 8'd255:
                  state==S_HOLD ? 8'd0:ramp_alpha[7:0];
 always @(posedge ctrl_clk or negedge ctrl_rst_n) begin
  if(!ctrl_rst_n) begin
   req_toggle<=0;ack_seen<=0;request_pending<=0;
   commit_sync1<=0;commit_sync2<=0;busy_sync1<=0;busy_sync2<=0;
  end else begin
   busy_sync1<=fade_running;busy_sync2<=busy_sync1;
   commit_sync1<=commit_toggle;commit_sync2<=commit_sync1;
   // 本地立即锁忙，堵住请求发出到 busy 回传之间的 CDC 窗口。
   if(next_event_in && !fade_busy) begin req_toggle<=~req_toggle;request_pending<=1;end
   if(busy_sync2) request_pending<=0;
   // Bypass can acknowledge a request without ever asserting fade_running.
   // Retire the local pending flag on either acknowledgement or observed busy.
   if(commit_sync2!=ack_seen) begin ack_seen<=commit_sync2;request_pending<=0;end
  end
 end
 always @(posedge pix_clk or negedge pix_rst_n) begin
  if(!pix_rst_n) begin
   state<=S_IDLE;ramp<=0;last_index<=0;old_bank<=0;wipe_mode<=0;have_frame<=0;
   req_sync1<=0;req_sync2<=0;req_seen<=0;commit_toggle<=0;paused_frame<=0;commit_pending<=0;
  end else begin
   req_sync1<=req_toggle;req_sync2<=req_sync1;
   // A commit pulse can be in flight from the preceding frame boundary when
   // interaction starts. Keep it until the frozen transition resumes.
   if(ENABLE_PAUSE!=0 && interaction_pause && index_commit) commit_pending<=1;
   if(frame_start) begin
    paused_frame<=ENABLE_PAUSE!=0 && interaction_pause;
    if(!(ENABLE_PAUSE!=0 && interaction_pause)) begin
    commit_pending<=0;
    if(player_active) begin
     last_index<=active_index;have_frame<=1;
    end
    // 第13讲：预览/退出预览只在帧边界取消特效。保留 CDC toggle 历史，
    // 对尚未完成淡出的手动请求补确认，避免控制域永远等不到应答。
    if(ENABLE_BYPASS && bypass) begin
     state<=S_IDLE;ramp<=FADE_FRAMES;wipe_mode<=0;old_bank<=active_index;
     if(state==S_OUT || req_sync2!=req_seen) commit_toggle<=~commit_toggle;
     req_seen<=req_sync2;
    end else case(state)
     S_IDLE: begin
      wipe_mode<=0;
      // 首张上屏/同一编号再次提交不做 Wipe，没有旧图时不能露出未完成 bank。
      if(committed && player_active && have_frame && active_index!=last_index) begin
       state<=S_IN;ramp<=0;wipe_mode<=1;old_bank<=last_index;
      end else if(req_sync2!=req_seen) begin
       req_seen<=req_sync2;state<=S_OUT;ramp<=FADE_FRAMES;
      end
     end
     S_OUT: if(ramp<=1) begin
      ramp<=0;state<=S_HOLD;commit_toggle<=~commit_toggle;
     end else ramp<=ramp-1'b1;
     S_HOLD: if(committed) begin state<=S_IN;ramp<=0;wipe_mode<=0;end
     S_IN: if(ramp>=FADE_FRAMES-1) begin state<=S_IDLE;ramp<=FADE_FRAMES;end
           else ramp<=ramp+1'b1;
     default: begin state<=S_IDLE;ramp<=FADE_FRAMES;end
    endcase
    end // freeze progress, request history and frame descriptor while interacting
   end
  end
 end
 // synthesis translate_off
 initial if(FADE_FRAMES<1 || FADE_FRAMES>256 || 256%FADE_FRAMES!=0)
  $fatal(1,"FADE_FRAMES must be 0 or a power of two up to 256");
 // synthesis translate_on
end endgenerate
endmodule
