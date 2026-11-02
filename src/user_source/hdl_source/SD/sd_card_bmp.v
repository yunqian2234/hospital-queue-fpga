// 第8课：FAT32 启动加载调度。目录扫描后 PIC1 优先，四图各加载一次。
// 播放/按键已移至 media_player_control；缓存完成位跨 SD 局部复位保留。
module sd_card_bmp #(
 parameter CLK_FREQ_HZ=100000000,SD_READ_TIMEOUT_MS=1000,SD_INIT_TIMEOUT_MS=5000,
 parameter [31:0] MAX_BMP_BYTES=16777216,parameter ENABLE_AUDIO=0,parameter ENABLE_VOICE=0,parameter AUDIO_LOOP=0
)(input clk,rst,memory_ready,retry_event,input [15:0] bmp_width,bmp_height,
 output reg [3:0] error_code,output [3:0] available_mask,output reg [3:0] failed_mask,
 output reg load_start,output reg [1:0] load_index,input loader_ready,
 output pixel_valid,output [23:0] pixel_rgb,input pixel_ready,
 output reg frame_commit,frame_abort,input loader_done,input [3:0] loader_error,
 output SD_nCS,SD_DCLK,SD_MOSI,input SD_MISO,
 input audio_sector_ready,audio_byte_ready,output audio_begin,audio_byte_valid,
 output [7:0] audio_byte,output audio_done,audio_failed,audio_reset,output [3:0] audio_error,
 // 阶段C：VOICE.PCM 片段读取透传，见 fat32_bmp_reader。
 output voice_available,voice_reset,input clip_start,input [4:0] clip_id,
 output clip_busy,clip_done,clip_failed,output [3:0] clip_error,
 input clip_sector_ready,clip_byte_ready,output clip_byte_valid,output [7:0] clip_byte,
 // 10/26：本次加载图片的文件头宽高与缩放后尺寸（frame_commit 时有效），给 bmp_res_info
 output [10:0] img_w,img_h,img_fit_w,img_fit_h);
localparam BOOT=0,SCAN_START=1,SCAN_WAIT=2,PICK=3,BEGIN_LOAD=4,RUN=5,WAIT_END=6,HALT=7;
localparam [63:0] INIT_LIMIT=(64'd1*CLK_FREQ_HZ/1000)*SD_INIT_TIMEOUT_MS;
reg [2:0] state;
wire sd_init_done,sd_read,sd_valid,sd_end,sd_reset_req;
wire [31:0] sd_addr;wire [7:0] sd_data;
reg [5:0] reset_count;
wire local_reset=reset_count!=0;
wire ready,scan_done,scan_failed,found,done,failed,error_valid,write_req;
wire [3:0] valid_mask,bmp_error;
reg scan_start,read_start,read_abort;
reg [3:0] completed,retried;
reg scan_retried,result_seen,attempt_failed;
reg [3:0] result_error;
reg [31:0] timer;
wire [3:0] todo=valid_mask & ~completed & ~failed_mask;
wire [1:0] choice=todo[0] ? 0:todo[1] ? 1:todo[2] ? 2:3;
assign available_mask=(scan_done ? valid_mask:4'd0)|completed;
always @(posedge clk or posedge rst) begin
 if(rst) begin
  state<=BOOT;error_code<=0;failed_mask<=0;load_start<=0;load_index<=0;
  frame_commit<=0;frame_abort<=0;scan_start<=0;read_start<=0;read_abort<=0;
  reset_count<=0;completed<=0;retried<=0;scan_retried<=0;result_seen<=0;
  result_error<=0;attempt_failed<=0;timer<=0;
 end else begin
  load_start<=0;frame_commit<=0;frame_abort<=0;scan_start<=0;read_start<=0;read_abort<=0;
  if(reset_count!=0) reset_count<=reset_count-1'b1;
  if(sd_reset_req) reset_count<=32;
  if(loader_done) begin result_seen<=1;result_error<=loader_error;end
  if(error_valid) error_code<=bmp_error;
  if(state==BOOT || state==WAIT_END) begin if({32'd0,timer}<INIT_LIMIT) timer<=timer+1'b1;end
  else timer<=0;
  case(state)
   BOOT: if(sd_init_done && memory_ready && !local_reset && !sd_reset_req && ready) state<=SCAN_START;
         else if({32'd0,timer}>=INIT_LIMIT) begin error_code<=5;state<=HALT;end
   SCAN_START: begin scan_start<=1;state<=SCAN_WAIT;end
   SCAN_WAIT: begin
    if(scan_failed) begin
     if(!scan_retried) begin scan_retried<=1;state<=BOOT;end else state<=HALT;
    end else if(!sd_init_done) begin
     if(!scan_retried) begin scan_retried<=1;state<=BOOT;end
     else begin error_code<=2;state<=HALT;end
    end else if(scan_done) begin
     if(valid_mask==0 && completed==0) error_code<=6;
     state<=PICK;
    end
   end
   PICK: begin
    if(retry_event && (failed_mask!=0 || available_mask==0)) begin
     failed_mask<=0;retried<=0;scan_retried<=0;state<=BOOT;
    end else if(!sd_init_done || local_reset || sd_reset_req) state<=BOOT;
    else if(todo!=0 && ready && loader_ready) begin
     load_index<=choice;load_start<=1;result_seen<=0;result_error<=0;attempt_failed<=0;
     state<=BEGIN_LOAD;
    end
   end
   BEGIN_LOAD: begin read_start<=1;state<=RUN;end
   RUN: begin
    if(failed || !sd_init_done || local_reset || sd_reset_req || loader_done) begin
     attempt_failed<=1;frame_abort<=1;read_abort<=1;state<=WAIT_END;
     error_code<=failed ? bmp_error:loader_done ? 4'd9:4'd2;
    end else if(done) begin frame_commit<=1;state<=WAIT_END;end
   end
   WAIT_END: begin
    if(result_seen || loader_done) begin
     if(attempt_failed || (loader_done ? loader_error!=0:result_error!=0)) begin
      if(retried[load_index]) failed_mask[load_index]<=1;
      else retried[load_index]<=1;
      if(!attempt_failed) error_code<=9;
     end else begin completed[load_index]<=1;error_code<=0;end
     state<=PICK;
    end else if({32'd0,timer}>=INIT_LIMIT) begin error_code<=9;state<=HALT;read_abort<=1;frame_abort<=1;end
   end
   HALT: if(retry_event && loader_ready) begin
    error_code<=0;failed_mask<=0;retried<=0;scan_retried<=0;state<=BOOT;timer<=0;
    if(!sd_init_done) reset_count<=32;
   end
   default:state<=BOOT;
  endcase
 end
end
fat32_bmp_reader #(.CLK_FREQ_HZ(CLK_FREQ_HZ),.SD_READ_TIMEOUT_MS(SD_READ_TIMEOUT_MS),
 .MAX_BMP_BYTES(MAX_BMP_BYTES),.USE_PIXEL_READY(1),.ENABLE_AUDIO(ENABLE_AUDIO),.ENABLE_VOICE(ENABLE_VOICE),.AUDIO_LOOP(AUDIO_LOOP)) u_fat32(
 .clk(clk),.rst(rst),.sd_init_done(sd_init_done),.ready(ready),.scan_start(scan_start),
 .scan_pause(state==BEGIN_LOAD || state==RUN || state==WAIT_END),
 .scan_done(scan_done),.scan_failed(scan_failed),.scan_found(found),.valid_mask(valid_mask),
 .load_start(read_start),.load_index(load_index),.load_abort(read_abort),.load_done(done),
 .load_failed(failed),.error_valid(error_valid),.bmp_error(bmp_error),
 .bmp_width(bmp_width),.bmp_height(bmp_height),.write_req(write_req),.write_ack(state==RUN),
 .img_w(img_w),.img_h(img_h),.img_fit_w(img_fit_w),.img_fit_h(img_fit_h),
 .pixel_valid(pixel_valid),.pixel_data(pixel_rgb),.pixel_ready(pixel_ready),
 .sd_reset_req(sd_reset_req),.sd_read(sd_read),.sd_addr(sd_addr),
 .sd_data(sd_data),.sd_valid(sd_valid),.sd_end(sd_end),
 // 第11讲：四图处理完成后启动背景音频；后续图片重试仍共用扇区仲裁。
 .audio_enable(state==PICK && todo==0 && completed!=0),
 .audio_sector_ready(audio_sector_ready),.audio_byte_ready(audio_byte_ready),
 .audio_begin(audio_begin),.audio_byte_valid(audio_byte_valid),.audio_byte(audio_byte),
 .audio_done(audio_done),.audio_failed(audio_failed),.audio_reset(audio_reset),.audio_error(audio_error),
 .voice_available(voice_available),.voice_reset(voice_reset),.clip_start(clip_start),.clip_id(clip_id),
 .clip_busy(clip_busy),.clip_done(clip_done),.clip_failed(clip_failed),.clip_error(clip_error),
 .clip_sector_ready(clip_sector_ready),.clip_byte_ready(clip_byte_ready),
 .clip_byte_valid(clip_byte_valid),.clip_byte(clip_byte));
sd_card_top sd_card_top_m0(.clk(clk),.rst(rst|local_reset),.SD_nCS(SD_nCS),.SD_DCLK(SD_DCLK),
 .SD_MOSI(SD_MOSI),.SD_MISO(SD_MISO),.sd_init_done(sd_init_done),.sd_sec_read(sd_read),
 .sd_sec_read_addr(sd_addr),.sd_sec_read_data(sd_data),.sd_sec_read_data_valid(sd_valid),
 .sd_sec_read_end(sd_end),.sd_sec_write(1'b0),.sd_sec_write_addr(32'd0),
 .sd_sec_write_data(8'd0),.sd_sec_write_data_req(),.sd_sec_write_end());
endmodule

module key_press_debounce #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer DEBOUNCE_MS = 20
)(
    input  wire clk,
    input  wire rst,
    input  wire button_in,    // 默认：松开=1，按下=0
    output reg  press_pulse,
    // === 修改点⑥：消抖后的稳定状态输出（用于长按检测）===
    output reg  button_stable_out
);

localparam integer DEBOUNCE_CYCLES = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;

reg button_sync0;
reg button_sync1;
reg button_stable;
reg [31:0] cnt;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        button_sync0      <= 1'b1;
        button_sync1      <= 1'b1;
        button_stable     <= 1'b1;
        button_stable_out <= 1'b1;   // 复位空闲态=松开
        cnt               <= 32'd0;
        press_pulse       <= 1'b0;
    end else begin
        button_sync0 <= button_in;
        button_sync1 <= button_sync0;
        press_pulse  <= 1'b0;

        if (button_sync1 == button_stable) begin
            cnt <= 32'd0;
        end else begin
            if (cnt >= DEBOUNCE_CYCLES - 1) begin
                if (button_stable && !button_sync1)
                    press_pulse <= 1'b1;
                button_stable     <= button_sync1;
                button_stable_out <= button_sync1;   // 与 button_stable 同步输出
                cnt               <= 32'd0;
            end else begin
                cnt <= cnt + 32'd1;
            end
        end
    end
end

endmodule
