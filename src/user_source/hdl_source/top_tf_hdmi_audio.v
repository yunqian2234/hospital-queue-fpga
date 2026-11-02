
module top(
    input                       clk,
    input                       rst_n,
    input                       key1,           // 板上 KEY2/B2：下一张/缩略图焦点
    input                       key2,           // 板上 KEY4/C1：轮播开关
    input                       key3,           // 第14讲：板上 KEY3/B1，低有效，循环调亮度
    input                       volume_sw,      // SW1/C8: board KEY4-/KEY3 select/KEY2+ volume mode
    input                       contrast_sw,    // 阶段D：SW3/C6，上=1 时 KEY3 调对比度，下=0 调亮度
    input                       res_sw,         // 10/26：SW4/C5，上=1 大厅屏底行显示当前图片的原始分辨率
    input                       wave_sw,        // 10/28：SW2/C7，上=1 显示音频柱形图，下=0 隐藏
    input                       link_rx,         // V7-2：J2 板间链路接收（从板 TX）
    output                      link_tx,         // V7-2：J2 板间链路发送（到从板 RX）
    // V8：板载网口（RTL8211E，RGMII 100M），LINK_ETH=1 时板间链路走网线
    output                      eth_txc,
    output [3:0]                eth_txd,
    output                      eth_tx_ctl,
    input                       eth_rxc,
    input  [3:0]                eth_rxd,
    input                       eth_rx_ctl,
    output                      eth_mdc,
    inout                       eth_mdio,
    input                       tjc_rx,          // V6：J1-39/T15，陶晶驰触摸屏 TX -> FPGA，9600 8N1
    output                      tjc_tx,          // V6：J1-40/R14，FPGA -> 触摸屏 RX（第 4 步启用，目前保持空闲高电平）

    output [5:0]                seg_sel,
    output [7:0]                seg_data,

    // HDMI TMDS
    output                      HDMI_CLK_P,
    output                      HDMI_D2_P,
    output                      HDMI_D1_P,
    output                      HDMI_D0_P,

    // HDMI DDC
    output                      HDMI_DDC_SCL,
    inout                       HDMI_DDC_SDA,

    // TF card SPI
    output                      sd_ncs,
    output                      sd_dclk,
    output                      sd_mosi,
    input                       sd_miso
);

parameter MEM_DATA_BITS = 32;
parameter ADDR_BITS     = 21;
parameter BUSRT_BITS    = 10;
// 第4课：图像/缓存尺寸使用同一组参数；HDMI 时序仍是本工程的 640x480。
parameter BMP_WIDTH    = 640;
parameter BMP_HEIGHT   = 480;
parameter FRAME_PIXELS = BMP_WIDTH * BMP_HEIGHT;
// 第10课：0 完全旁路；16 为默认，8/32 等 256 的约数也可使用。
parameter FADE_FRAMES = 16;
// 第11讲：0 自动 WAV→琶音；1 强制琶音；2 强制测试音。按键功能不变。
parameter AUDIO_SOURCE_MODE = 0;
// Background PCM repeats through the same FAT streamer/FIFO, not a media reset.
// Set 0 only for legacy one-shot diagnostics.
parameter MUSIC_LOOP_ENABLE = 1;
// AUDIO.PCM默认循环；缺文件、读卡失败或关闭循环后播完，选择器回落到内置琶音。
// 0=回落时静音（候诊场景默认）；1=恢复原琶音背景旋律。AUDIO_SOURCE_MODE=1 强制琶音时不受影响。
parameter ARP_FALLBACK_ENABLE = 0;
// Keep the diagnostic overlay during the first integrated hospital build.
// It provides a visible fallback while the business OSD is being validated.
// V6：1=接收触摸屏命令（与外接八键并行进入同一业务核心）；0=忽略触摸屏。
parameter TOUCH_ENABLE = 1;   // 阶段D：最终画面默认关闭右上诊断框，调试时改 1
// 阶段C：1=医院事件经 TF 卡 VOICE.PCM 真实播报，播完才回执；0=退回仅显示消费者。
parameter VOICE_ENABLE = 1;
// V7-2 单板链路自检：1=用 J2 的 TX/RX 跳线自测板间链路，数码管显示收发统计（见
// link/link_loopback_test.v）。两块板联调时应设 0。默认 0，不影响现有功能。
parameter LOOPBACK_ENABLE = 0;
// V7-4 双板：1=J2 板间链路连诊室板（每帧发状态，接收医生 K1/K2/K3 命令）。未接诊室板时
// 链路只是一直发状态、收不到东西，不影响单板功能。LOOPBACK_ENABLE=1 时自检优先，本项不生效。
parameter LINK_ENABLE = 1;
// V8：1=板间链路走板载网口（网线直连诊室板），0=退回 V7 的 J2 杜邦线串口。两块板必须设成一样。
// 帧内容、序号、重发、心跳、断线回退都不变，只换底层传输。
parameter LINK_ETH = 1;
// V8 单板网口自检：1=网口芯片内部环回（不插网线），大厅板收到自己发的状态帧。平时为 0。
parameter ETH_PHY_LOOPBACK = 0;
// 10/25 多诊室：协议按 4 个诊室设计；本次演示编译 2 个诊室（1、2 诊室），省去 3、4 诊室的逻辑。
// 需要 3、4 诊室时改为 4（大厅资源会增加，需要重新做资源/时序检查）。
parameter HOSPITAL_ROOMS = 2;

wire Sdr_init_done;
wire Sdr_init_ref_vld;
wire Sdr_busy;

wire sd_card_clk;
wire ext_mem_clk;
wire ext_mem_clk_sft;
wire video_clk;
wire hdmi_5x_clk;

wire hs;
wire vs;
wire de;

wire [23:0] vout_data;
wire        display_valid;

wire [3:0]  state_code;
wire [6:0]  seg_data_0;
wire [3:0]  media_error;
wire [3:0] video_error;
wire [6:0]  seg_error;
wire [7:0] diagnostic_board;
wire [3:0] error_display=diagnostic_board[7:4];
wire [3:0] state_code_board=diagnostic_board[3:0];
wire [3:0] state_code_audio;
wire sdram_ready_sd;
wire wav_begin,wav_byte_valid,wav_byte_ready,wav_sector_ready,wav_done,wav_failed,wav_media_reset;
wire [7:0] wav_byte;
wire [3:0] audio_error_sd,audio_error_pix;


wire App_rd_en;
wire [ADDR_BITS-1:0] App_rd_addr;
wire Sdr_rd_en;
wire [MEM_DATA_BITS-1:0] Sdr_rd_dout;
wire App_wr_en;
wire [ADDR_BITS-1:0] App_wr_addr;
wire [MEM_DATA_BITS-1:0] App_wr_din;
wire [3:0] App_wr_dm;

wire hs_0;
wire vs_0;
wire de_0;

// HDMI 1.4b 音频发射相关
wire        audio_pll_lock;
wire        audio_mclk;
wire        audio_i2s_bclk;
wire        audio_i2s_lrck;
wire        audio_i2s_dout;
wire        audio_valid;
wire [23:0] audio_left_data;
wire [23:0] audio_right_data;
wire        acr_valid;
wire [19:0] acr_cts;
wire [19:0] acr_n;

wire        axis_s_user;
wire        axis_s_valid;
wire        axis_s_last;
wire [23:0] axis_s_data;
wire        axis_s_ready;
wire axis_raw_user,axis_raw_valid,axis_raw_last,axis_input_fault;
wire hdmi_video_locked;
wire [23:0] axis_raw_data;

wire        edid_trig;
wire        edid_valid;
wire [7:0]  edid_data;

wire [9:0]  tmds_ch0_data;
wire [9:0]  tmds_ch1_data;
wire [9:0]  tmds_ch2_data;
wire [9:0]  tmds_clk_data;

// 第5课：PLL 复位独立于业务复位；各域异步置位、同步释放。
// 任一 PLL 失锁重新初始化，连续锁定 20ms 后恢复；不再永久忽略失锁。
wire sys_pll_lock, video_pll_lock;
wire pll_rst, system_arst;
wire rst_board, rst_sd, rst_mem, rst_video, rst_audio;
clock_reset_ctrl u_clock_reset(
    .ref_clk(clk),.ext_rst_n(rst_n),
    .pll_locked({sys_pll_lock,video_pll_lock,audio_pll_lock}),
    .pll_rst(pll_rst),.system_arst(system_arst));
reset_sync u_board_reset(.clk(clk),.arst(system_arst),.rst(rst_board));
reset_sync u_sd_reset(.clk(sd_card_clk),.arst(system_arst),.rst(rst_sd));
reset_sync u_mem_reset(.clk(ext_mem_clk),.arst(system_arst),.rst(rst_mem));
reset_sync u_video_reset(.clk(video_clk),.arst(system_arst),.rst(rst_video));
reset_sync u_audio_reset(.clk(audio_mclk),.arst(system_arst),.rst(rst_audio));
// HDMI 125MHz 串行域在 lane_lvds_10_1 内独立同步释放。
cdc_level u_sdram_ready_sd(.clk(sd_card_clk),.rst(rst_sd),
    .async_in(Sdr_init_done),.level_out(sdram_ready_sd));
// 多位图片编号采用整体握手，避免音频偶尔接收到混合编号。
cdc_status #(.WIDTH(4)) u_media_audio(
    .src_clk(video_clk),.src_rst(rst_video),.src_data(state_code),
    .dst_clk(audio_mclk),.dst_rst(rst_audio),.dst_data(state_code_audio));
cdc_status #(.WIDTH(8)) u_diagnostic_board(
    .src_clk(video_clk),.src_rst(rst_video),.src_data({video_error,state_code}),
    .dst_clk(clk),.dst_rst(rst_board),.dst_data(diagnostic_board));

// 保持你原来的 TF / SDRAM / video 时钟
sys_pll sys_pll_m0(
    .refclk     (clk),
    .clk0_out   (sd_card_clk),
    .clk1_out   (ext_mem_clk),
    .clk2_out   (ext_mem_clk_sft),
    .extlock    (sys_pll_lock),
    .reset      (pll_rst)
);

video_pll video_pll_m0(
    .refclk     (clk),
    .clk0_out   (video_clk),
    .clk1_out   (hdmi_5x_clk),
    .extlock    (video_pll_lock),
    .reset      (pll_rst)
);

// 复用你 I2S->HDMI 工程里的 PLL，只取 12.288MHz 音频主时钟
PLL_HDMI_AUDIO u_audio_pll(
    .refclk     (clk),
    .reset      (pll_rst),
    .extlock    (audio_pll_lock),
    .clk0_out   (),
    .clk1_out   (),
    .clk2_out   (audio_mclk)
);

// 第8课：四 bank 固定驻留，读取和播放不再触发 TF 重新加载。
wire [3:0] available_sd,failed_sd,complete_mem,complete_pix,sd_error_pix,reader_error_mem,reader_error_pix;
wire [7:0] catalogue_pix;
wire begin_load,loader_ready,source_pixel_valid,source_pixel_ready,commit_frame,abort_frame,loader_done;
wire [1:0] load_index,active_index;
wire [10:0] img_w,img_h,img_fit_w,img_fit_h;   // 10/26：本次加载图片的文件头宽高 / 缩放后尺寸（SD 域）
wire [23:0] source_rgb,reader_rgb;
wire [3:0] loader_error;
wire [11:0] video_x,video_y;
// 10/24：缩略图模式（SW4）已删除，只保留帧起点和完整图片掩码的帧边界提交。
wire hospital_photo_pause=1'b0;        // HDMI 按键页面已删除，照片轮播不再暂停
reg frame_vs_q;
reg [3:0] complete_frame;
wire frame_start=frame_vs_q && !vs_0;
always @(posedge video_clk or posedge rst_video) begin
 if(rst_video) begin frame_vs_q<=1;complete_frame<=0;end
 else begin
  frame_vs_q<=vs_0;
  if(frame_start) complete_frame<=complete_pix;
 end
end
// 第14讲（第13课）：消抖和档位均在像素域，无多位亮度总线跨域。
// 请求值记录每次按下；实际亮度只在 VSYNC 下降沿锁存，按住不连发。
// One physical frontend for board KEY4/C1, KEY3/B1, KEY2/B2.
// Port names key1/key2 are historical: they mean board KEY2/KEY4.
wire [2:0] board_key_press,board_key_release,board_key_pressed;
wire [7:0] board_business_press;
wire [2:0] board_key_blocked;
wire volume_mode,volume_target_voice;
wire [3:0] music_level,voice_level;
hospital_key_frontend #(.KEY_COUNT(3)) u_board_keys(
 .clk(video_clk),.rst(rst_video),.key_n({key1,key3,key2}),
 .pressed(board_key_pressed),.press_pulse(board_key_press),
 .release_pulse(board_key_release),.armed());
hospital_volume_control u_volume_keys(.clk(video_clk),.rst(rst_video),.mode_sw(volume_sw),
 .press({5'd0,board_key_press}),.pressed({5'd0,board_key_pressed}),
 .business_press(board_business_press),.business_blocked(board_key_blocked),
 .mode(volume_mode),.target_voice(volume_target_voice),.music_level(music_level),.voice_level(voice_level));
wire brightness_press=board_business_press[1];
reg [7:0] brightness_requested,brightness;
// 阶段D：SW3 选择 KEY3 调节对象；对比度四档 100/125/150/75%，同样只在帧边界生效。
reg contrast_sw_sync1,contrast_sw_sync2; /* synthesis keep */
reg [1:0] contrast_requested,contrast_idx;
wire contrast_press=brightness_press && contrast_sw_sync2;
wire brightness_step=brightness_press && !contrast_sw_sync2;
function [7:0] brightness_next;
 input [7:0] value;
 begin case(value)
  8'd255:brightness_next=8'd192;
  8'd192:brightness_next=8'd128;
  8'd128:brightness_next=8'd64;
  default:brightness_next=8'd255;
 endcase end
endfunction
always @(posedge video_clk or posedge rst_video) begin
 if(rst_video) begin brightness_requested<=8'd255;brightness<=8'd255;end
 else begin
  if(brightness_step) brightness_requested<=brightness_next(brightness_requested);
  if(frame_start) brightness<=brightness_step ? brightness_next(brightness_requested):brightness_requested;
 end
end
always @(posedge video_clk or posedge rst_video) begin
 if(rst_video) begin contrast_sw_sync1<=0;contrast_sw_sync2<=0;contrast_requested<=0;contrast_idx<=0;end
 else begin
  contrast_sw_sync1<=contrast_sw;contrast_sw_sync2<=contrast_sw_sync1;
  if(contrast_press) contrast_requested<=contrast_requested+1'b1;
  if(frame_start) contrast_idx<=contrast_press ? contrast_requested+1'b1:contrast_requested;
 end
end
wire [1:0] brightness_idx=brightness==8'd255 ? 2'd0:brightness==8'd192 ? 2'd1:brightness==8'd128 ? 2'd2:2'd3;
wire index_commit,auto_enabled,retry_toggle,retry_sync;
reg retry_seen;
wire reader_pixel_valid,reader_underflow;
wire wr_request,rd_request,wr_grant,rd_grant,wr_done,rd_done;
cdc_level u_retry_sd(.clk(sd_card_clk),.rst(rst_sd),.async_in(retry_toggle),.level_out(retry_sync));
always @(posedge sd_card_clk or posedge rst_sd)
 if(rst_sd) retry_seen<=0;else retry_seen<=retry_sync;
cdc_status #(.WIDTH(8)) u_catalogue_status(.src_clk(sd_card_clk),.src_rst(rst_sd),
 .src_data({failed_sd,available_sd}),.dst_clk(video_clk),.dst_rst(rst_video),.dst_data(catalogue_pix));
cdc_status #(.WIDTH(4)) u_complete_status(.src_clk(ext_mem_clk),.src_rst(rst_mem),
 .src_data(complete_mem),.dst_clk(video_clk),.dst_rst(rst_video),.dst_data(complete_pix));
cdc_status #(.WIDTH(4)) u_sd_error_status(.src_clk(sd_card_clk),.src_rst(rst_sd),
 .src_data(media_error),.dst_clk(video_clk),.dst_rst(rst_video),.dst_data(sd_error_pix));
cdc_status #(.WIDTH(4)) u_reader_error_status(.src_clk(ext_mem_clk),.src_rst(rst_mem),
 .src_data(reader_error_mem),.dst_clk(video_clk),.dst_rst(rst_video),.dst_data(reader_error_pix));
assign video_error=axis_input_fault ? 4'd13:reader_error_pix!=0 ? reader_error_pix:
                       reader_underflow ? 4'd11:sd_error_pix!=0 ? sd_error_pix:audio_error_pix;
assign state_code={2'd0,active_index}+4'd1;
cdc_status #(.WIDTH(4)) u_audio_error_status(.src_clk(sd_card_clk),.src_rst(rst_sd),
 .src_data(audio_error_sd),.dst_clk(video_clk),.dst_rst(rst_video),.dst_data(audio_error_pix));
// 阶段C：语音片段读取共用同一 SD 扇区通道（优先级 语音>背景音>图片>目录）。
wire voice_available,voice_media_reset,clip_start,clip_busy,clip_done,clip_failed;
wire clip_sector_ready,clip_byte_ready,clip_byte_valid;
wire [4:0] clip_id;wire [3:0] clip_error;wire [7:0] clip_byte;
sd_card_bmp #(.ENABLE_AUDIO(1),.ENABLE_VOICE(VOICE_ENABLE),.AUDIO_LOOP(MUSIC_LOOP_ENABLE)) sd_card_bmp_m0(
 .clk(sd_card_clk),.rst(rst_sd),.memory_ready(sdram_ready_sd),.retry_event(retry_sync!=retry_seen),
 .bmp_width(BMP_WIDTH[15:0]),.bmp_height(BMP_HEIGHT[15:0]),.error_code(media_error),
 .available_mask(available_sd),.failed_mask(failed_sd),.load_start(begin_load),.load_index(load_index),
 .loader_ready(loader_ready),.pixel_valid(source_pixel_valid),.pixel_rgb(source_rgb),.pixel_ready(source_pixel_ready),
 .frame_commit(commit_frame),.frame_abort(abort_frame),.loader_done(loader_done),.loader_error(loader_error),
 .audio_begin(wav_begin),.audio_byte_valid(wav_byte_valid),.audio_byte(wav_byte),
 .audio_byte_ready(wav_byte_ready),.audio_sector_ready(wav_sector_ready),
 .audio_done(wav_done),.audio_failed(wav_failed),.audio_reset(wav_media_reset),.audio_error(audio_error_sd),
 .voice_available(voice_available),.voice_reset(voice_media_reset),.clip_start(clip_start),.clip_id(clip_id),
 .clip_busy(clip_busy),.clip_done(clip_done),.clip_failed(clip_failed),.clip_error(clip_error),
 .clip_sector_ready(clip_sector_ready),.clip_byte_ready(clip_byte_ready),
 .clip_byte_valid(clip_byte_valid),.clip_byte(clip_byte),
 .img_w(img_w),.img_h(img_h),.img_fit_w(img_fit_w),.img_fit_h(img_fit_h),
 .SD_nCS(sd_ncs),.SD_DCLK(sd_dclk),.SD_MOSI(sd_mosi),.SD_MISO(sd_miso));
media_frame_loader #(.WIDTH(BMP_WIDTH),.HEIGHT(BMP_HEIGHT)) u_loader(
 .src_clk(sd_card_clk),.src_rst(rst_sd),.mem_clk(ext_mem_clk),.mem_rst(rst_mem),
 .load_start(begin_load),.image_index(load_index),.load_ready(loader_ready),
 .pixel_valid(source_pixel_valid),.pixel_rgb(source_rgb),.pixel_ready(source_pixel_ready),
 .frame_commit(commit_frame),.frame_abort(abort_frame),.load_done(loader_done),.load_error(loader_error),
 .controller_ready(Sdr_init_done),.controller_busy(Sdr_busy),.image_complete(complete_mem),
 .burst_request(wr_request),.burst_grant(wr_grant),.burst_done(wr_done),
 .app_wr_en(App_wr_en),.app_wr_addr(App_wr_addr),.app_wr_data(App_wr_din));
assign App_wr_dm=4'd0;
media_sdram_arbiter u_memory_arbiter(.clk(ext_mem_clk),.rst(rst_mem),.ready(Sdr_init_done),
 .busy(Sdr_busy),.refresh(Sdr_init_ref_vld),.wr_request(wr_request),.rd_request(rd_request),
 .wr_done(wr_done),.rd_done(rd_done),.wr_grant(wr_grant),.rd_grant(rd_grant));
// 第10课：player 仍留在原 25MHz 域，保留原消抖/长按；事件用 toggle 桥接。
wire manual_request_pix,manual_allow_pix,fade_request_ctrl,fade_commit_ctrl;
wire fade_busy_ctrl,fade_active,wipe_active;
wire [7:0] fade_alpha;
wire [8:0] wipe_ramp;
wire [1:0] wipe_old_index;
reg manual_req_toggle,manual_allow_toggle;
reg manual_req_sync1,manual_req_sync2,manual_allow_sync1,manual_allow_sync2; /* synthesis keep */
reg manual_req_seen,manual_allow_seen;
always @(posedge video_clk or posedge rst_video) begin
 if(rst_video) begin manual_req_toggle<=0;manual_allow_sync1<=0;manual_allow_sync2<=0;manual_allow_seen<=0;end
 else begin
  if(manual_request_pix) manual_req_toggle<=~manual_req_toggle;
  manual_allow_sync1<=manual_allow_toggle;manual_allow_sync2<=manual_allow_sync1;
  manual_allow_seen<=manual_allow_sync2;
 end
end
always @(posedge sd_card_clk or posedge rst_sd) begin
 if(rst_sd) begin manual_req_sync1<=0;manual_req_sync2<=0;manual_req_seen<=0;manual_allow_toggle<=0;end
 else begin
  manual_req_sync1<=manual_req_toggle;manual_req_sync2<=manual_req_sync1;manual_req_seen<=manual_req_sync2;
  if(fade_commit_ctrl) manual_allow_toggle<=~manual_allow_toggle;
 end
end
assign fade_request_ctrl=manual_req_sync2!=manual_req_seen;
assign manual_allow_pix=manual_allow_sync2!=manual_allow_seen;
// 第13讲：VSYNC 边界分三拍提交，给模式/焦点/特效描述符留出锁存时间。
reg transition_frame_start,reader_frame_start;
always @(posedge video_clk or posedge rst_video)
 if(rst_video) begin transition_frame_start<=0;reader_frame_start<=0;end
 else begin transition_frame_start<=frame_start;reader_frame_start<=transition_frame_start;end
localparam integer WIPE_DIVISOR=(FADE_FRAMES==0) ? 1:FADE_FRAMES;
// 第14讲资源审查：640=512+128。固定宽度用移位加法，避免 TD 因亮度
// 改变 DSP 打包后为原来的 Wipe 常数乘法另占一块 DSP；边界数值不变。
wire [20:0] wipe_ramp_extended={12'd0,wipe_ramp};
wire [20:0] wipe_scaled;
generate if(BMP_WIDTH==640) begin:g_wipe_640
 assign wipe_scaled=(wipe_ramp_extended<<9)+(wipe_ramp_extended<<7);
end else begin:g_wipe_other
 assign wipe_scaled=wipe_ramp*BMP_WIDTH;
end endgenerate
wire [11:0] wipe_boundary=wipe_scaled/WIPE_DIVISOR;
video_fade_transition #(.FADE_FRAMES(FADE_FRAMES),.ENABLE_BYPASS(1),.ENABLE_PAUSE(1)) u_fade_transition(
 .ctrl_clk(sd_card_clk),.ctrl_rst_n(~rst_sd),.next_event_in(fade_request_ctrl),
 .next_event_out(fade_commit_ctrl),.fade_busy(fade_busy_ctrl),
 .pix_clk(video_clk),.pix_rst_n(~rst_video),.player_active(display_valid),
 .frame_start(transition_frame_start),.index_commit(index_commit),.active_index(active_index),
 .alpha_out(fade_alpha),.fade_active(fade_active),.wipe_active(wipe_active),
 .ramp_out(wipe_ramp),.transition_kind(),.old_index(wipe_old_index),
 .bypass(1'b0),.interaction_pause(hospital_photo_pause));
media_player_control #(.TRANSITIONS(FADE_FRAMES!=0),.ENABLE_THUMBNAILS(0),.ENABLE_PAUSE(1),.KEY_EVENT_INPUT(1)) u_player(.clk(video_clk),.rst(rst_video),.key_next(key1),.key_auto(key2),
 .key_next_event(board_business_press[2]),.key_auto_pressed(board_key_pressed[0]),
 .key_auto_release_event(board_key_release[0] && !board_key_blocked[0]),
 .key_auto_cancel(board_key_blocked[0]),
 .frame_start(frame_start),.available_mask(catalogue_pix[3:0]),.failed_mask(catalogue_pix[7:4]),
 .image_complete(complete_pix),.active_index(active_index),.display_valid(display_valid),
 .index_commit(index_commit),.auto_enabled(auto_enabled),.retry_toggle(retry_toggle),
 .transition_request(manual_request_pix),.transition_allow(manual_allow_pix),.transition_busy(fade_active),
 .thumbnail_mode(1'b0),.interaction_pause(hospital_photo_pause));
// 第9课：时序前肩/同步/后肩与 OSD 有效区 X 换算共用，避免坐标偏移。
localparam VIDEO_H_FP=16,VIDEO_H_SYNC=96,VIDEO_H_BP=48;
localparam VIDEO_H_BLANK=VIDEO_H_FP+VIDEO_H_SYNC+VIDEO_H_BP;
video_timing_ctrl #(.H_ACT(BMP_WIDTH),.V_ACT(BMP_HEIGHT),.ACTIVE_LAST(1),
 .H_FP(VIDEO_H_FP),.H_SYNC(VIDEO_H_SYNC),.H_BP(VIDEO_H_BP)) u_timing(
 .pclk(video_clk),.rst_n(~rst_video),.hsync(hs_0),.vsync(vs_0),.de(de_0),.x(video_x),.y(video_y));
localparam VIDEO_V_BLANK=10+2+33;
wire [11:0] fetch_x,fetch_y;
wire [3:0] fetch_complete;
wire reader_consume=de_0;
media_frame_reader #(.WORDS(FRAME_PIXELS),.WIDTH(BMP_WIDTH),.ENABLE_WIPE(FADE_FRAMES!=0),.ENABLE_THUMBNAILS(0)) u_reader(
 .mem_clk(ext_mem_clk),.mem_rst(rst_mem),.pix_clk(video_clk),.pix_rst(rst_video),
 .controller_ready(Sdr_init_done),.controller_busy(Sdr_busy),.frame_start(reader_frame_start),
 .display_valid(display_valid),.active_index(active_index),.pixel_consume(reader_consume),
 .thumbnail_mode(1'b0),.image_complete(complete_frame),
 .fetch_x(fetch_x),.fetch_y(fetch_y),.fetch_complete(fetch_complete),
 .fetch_valid(1'b0),.source_index(2'd0),.source_x(10'd0),.source_y(10'd0),
 .wipe_active(wipe_active),.wipe_old_index(wipe_old_index),.wipe_boundary(wipe_boundary),
 .pixel_rgb(reader_rgb),.pixel_valid(reader_pixel_valid),.underflow(reader_underflow),
 .reader_error(reader_error_mem),.burst_request(rd_request),.burst_grant(rd_grant),.burst_done(rd_done),
 .app_rd_en(App_rd_en),.app_rd_addr(App_rd_addr),.sdram_rd_valid(Sdr_rd_en),.sdram_rd_data(Sdr_rd_dout));
// 第10课：reader 已按边界组合旧/新 bank；无需两路整帧读取/额外帧缓存。
// 第14讲：eff_alpha = fade_alpha * (brightness+1) >> 8。
// 四档固定系数为 256/193/129/65，用移位加法准确实现，不新增乘法器。
// 先扩为 16 位，避免 brightness=255 加一溢出或移位丢高位。
function [7:0] fold_brightness;
 input [7:0] alpha,level;
 reg [15:0] a,product;
 begin
  a={8'd0,alpha};
  case(level)
   8'd192:product=(a<<7)+(a<<6)+a;
   8'd128:product=(a<<7)+a;
   8'd64: product=(a<<6)+a;
   default:product=a<<8;
  endcase
  fold_brightness=product[15:8];
 end
endfunction
wire [7:0] eff_alpha=fold_brightness(fade_alpha,brightness);
// 阶段D 对比度：以 128 为中心，d=v-128 按 1、1.25、1.5、0.75 倍用移位加法放缩后饱和，
// 不新增乘法器；第 0 档逐位直通。对比度在亮度/淡入淡出之前。
function [7:0] contrast_channel;
 input [7:0] v;
 input [1:0] idx;
 reg signed [9:0] d,s;
 begin
  d=$signed({2'b00,v})-10'sd128;
  case(idx)
   2'd1:s=d+(d>>>2);
   2'd2:s=d+(d>>>1);
   2'd3:s=d-(d>>>2);
   default:s=d;
  endcase
  contrast_channel=s>10'sd127 ? 8'd255:s<-10'sd128 ? 8'd0:s[7:0]+8'd128;
 end
endfunction
wire [23:0] contrast_rgb={contrast_channel(reader_rgb[23:16],contrast_idx),
 contrast_channel(reader_rgb[15:8],contrast_idx),contrast_channel(reader_rgb[7:0],contrast_idx)};
// 复用原转场三通道乘法。255 直通，保证最高档稳定显示逐位不失真。
wire [15:0] fade_r=contrast_rgb[23:16]*eff_alpha;
wire [15:0] fade_g=contrast_rgb[15:8]*eff_alpha;
wire [15:0] fade_b=contrast_rgb[7:0]*eff_alpha;
wire [23:0] adjusted_rgb=eff_alpha==255 ? contrast_rgb:{fade_r[15:8],fade_g[15:8],fade_b[15:8]};
// 图片共用亮度/对比度，波形与界面文字随后叠加；音频继续只取原 fade_alpha。
wire [23:0] transition_rgb=adjusted_rgb;
// reader -> 转场（组合）-> OSD（组合）-> 原一拍 adapter。有效像素 X 从 0 开始。
// 视频时序、读缓存消费节拍和 HDMI/音频接口均保持原来的延迟。
wire [11:0] osd_x_active=video_x-VIDEO_H_BLANK;
wire [9:0] osd_pixel_x=de_0 ? osd_x_active[9:0]:10'd0;
wire [23:0] osd_rgb_out;
wire osd_de_out;
// EB 在原 reader 的帧起点清零，早于 VSYNC 下降沿。只对 OSD 保留帧间
// 出现过的最后一个错误，使短错误也能显示一帧，不改变原有恢复/数码管逻辑。
reg [3:0] osd_error_pending;
reg osd_vs_q,osd_vs_delay;
// player 在 VS 边界提交编号，OSD 延后一拍锁存状态；仍位于场消隐内，
// RGB/DE 没有增加延迟，避免缩略图焦点已移动但状态条滞后一帧。
wire osd_frame_start=osd_vs_q && !osd_vs_delay;
always @(posedge video_clk or posedge rst_video) begin
 if(rst_video) begin osd_error_pending<=0;osd_vs_q<=1;osd_vs_delay<=1;end
 else begin
  osd_vs_delay<=vs_0;osd_vs_q<=osd_vs_delay;
  if(osd_frame_start) osd_error_pending<=0;
  else if(video_error!=0) osd_error_pending<=video_error;
 end
end
wire [3:0] osd_error_value=video_error!=0 ? video_error:osd_error_pending;
// 与现有数码管一致：正常 00，错误 E1..EC；内部 4 位编号不作改动。
wire [7:0] osd_error_code=osd_error_value==0 ? 8'h00:{4'he,osd_error_value};
// 阶段D：原 4 字符状态码移到右下角（状态条右侧），不被顶部叫号横幅遮挡。
// Media ID/auto/error are rendered by the shared Chinese product OSD below.
assign osd_rgb_out=transition_rgb;
assign osd_de_out=de_0;
// 第12讲：OSD 后叠加，沿用原 adapter 的一拍延迟；不改变 SDRAM/HDMI 时序。
wire [23:0] waveform_rgb_out;
wire waveform_enable_pix,pcm_tap_valid;
wire signed [15:0] pcm_tap_left;
// 10/28：线形波形改为 16 根跳动柱形图（青绿柱 + 琥珀峰值帽），位置为原波形框的右半边
// x=320..575、y=252..315；SW2 拨上才显示（播放时），拨下隐藏。
reg wave_sw_sync1,wave_sw_sync2;
always @(posedge video_clk or posedge rst_video)
 if(rst_video) begin wave_sw_sync1<=0;wave_sw_sync2<=0;end
 else begin wave_sw_sync1<=wave_sw;wave_sw_sync2<=wave_sw_sync1;end
audio_bar_visualizer #(.BAR_X(320),.BAR_Y(252)) u_audio_bars(
 .clk(video_clk),.rst_n(~rst_video),.vsync(vs_0),.de(osd_de_out),
 .rgb_in(osd_rgb_out),.pixel_x(osd_pixel_x),.show(wave_sw_sync2),.enable(waveform_enable_pix),
 .pcm_tap_valid(pcm_tap_valid),.pcm_tap_left(pcm_tap_left),
 .rgb_out(waveform_rgb_out));

// 10/24：外接 J1 八键与 HDMI 选卡/预览页面已删除。业务请求只来自触摸屏（请求接口）
// 和诊室板医生命令（链路按键脉冲），二者直接进入 hospital_app_core。
wire [7:0] hospital_link_keys;      // V7-4：诊室板医生命令（K1/K2/K3 脉冲）
wire [1:0] hospital_link_room;      // 10/25：命令来自几号诊室（0..3 = 1..4 诊室）
wire [19:0] hospital_room_numbers;  // 10/25：各诊室当前患者号
wire [1:0] hospital_last_room,hospital_help_room;
wire [11:0] hospital_reg_pending;
wire [47:0] hospital_room_records;  // 10/25：各诊室当前患者的报到登记
wire [7:0] hospital_core_keys;
wire [7:0] remote_accepted,remote_invalid,remote_duplicate,remote_full,remote_conflict;
wire [4:0] hospital_history1,hospital_history2,hospital_history3;
wire [43:0] hospital_active_event;
wire touch_request_valid,touch_request_ready,touch_request_done;
wire core_request_valid,core_request_ready,core_request_done,core_request_accepted;
wire [2:0] touch_request_kind,touch_request_card;
wire [4:0] touch_request_number;
wire [2:0] core_request_kind,core_request_card,core_request_result;
wire [4:0] core_request_number;
wire hospital_clinic_online;
wire [3:0] eth_phy_state;
wire [1:0] touch_page;              // 触摸屏当前页面，随状态帧发给诊室板
wire [4:0] hospital_call_number;
wire [4:0] hospital_issued_number, hospital_waiting_count;   // V7 取号
wire [2:0] hospital_selected_card, hospital_last_card;
wire hospital_last_card_valid;
wire [1:0] hospital_help_state;
wire [15:0] hospital_help_seq;
wire hospital_event_valid;
wire [43:0] hospital_event_data;
wire [3:0] hospital_queued_events;
wire hospital_busy;
wire [15:0] hospital_active_seq;
wire [7:0] hospital_accepted_keys, hospital_rejected_keys;
wire [7:0] hospital_reject_invalid, hospital_reject_duplicate;
wire [7:0] hospital_reject_full, hospital_reject_conflict;
wire hospital_overflow_sticky, hospital_completion_error_sticky;
wire hospital_event_ready;
wire hospital_event_done;
wire [15:0] hospital_event_done_seq;
wire hospital_voice_busy;
wire [2:0] hospital_voice_status;

// V6 触摸屏：串口帧 -> 与患者按键等价的按压序列（点卡 N = 选到 N 再确认；重播 = K7）。
// 屏只发“哪张卡被点了”，所有业务判断仍在 hospital_app_core。
wire touch_cmd_valid,touch_busy;
wire touch_command_rejected;
wire [6:0] touch_cmd,touch_arg;
wire touch_tx_valid,touch_tx_ready;
wire [7:0] touch_tx_data;
generate if(TOUCH_ENABLE!=0) begin:g_touch
 tjc_touch_rx #(.CLK_HZ(25_000_000),.BAUD(9600)) u_touch_rx(
  .clk(video_clk),.rst(rst_video),.rx(tjc_rx),.cmd_valid(touch_cmd_valid),.cmd(touch_cmd),.arg(touch_arg),
  .good_frames(),.bad_frames(),.other_frames(),.line_errors());
 hospital_touch_keys #(.SEMANTIC_INPUT(1)) u_touch_keys(
  .clk(video_clk),.rst(rst_video),.cmd_valid(touch_cmd_valid),.cmd(touch_cmd),.arg(touch_arg),
  .selected_card(hospital_selected_card),.key_press_in(8'd0),.key_press_out(),
  .busy(touch_busy),.accepted_cmds(),.dropped_cmds(),.command_rejected(touch_command_rejected),
  .call_number(hospital_call_number),.request_valid(touch_request_valid),
  .request_kind(touch_request_kind),.request_card(touch_request_card),.request_number(touch_request_number),
  .request_ready(touch_request_ready),.request_done(touch_request_done),
  .request_accepted(core_request_accepted),.request_result(core_request_result));
 // V6/V7：业务状态 -> 屏 t0（状态/取号结果）与 q0（当前号、下一位、候诊人数），屏只显示不决策。
 hospital_touch_status #(.SEMANTIC_INPUT(1)) u_touch_status(
  .clk(video_clk),.rst(rst_video),.frame_start(frame_start),
  .cmd_valid(touch_cmd_valid),.cmd(touch_cmd),.arg(touch_arg),
  .accepted_keys(hospital_accepted_keys),.call_number(hospital_call_number),
  .issued_number(hospital_issued_number),.waiting_count(hospital_waiting_count),.page(touch_page),
  .busy(hospital_busy),.help_state(hospital_help_state),.help_room(hospital_help_room),
  .reject_invalid(hospital_reject_invalid),.reject_duplicate(hospital_reject_duplicate),
  .reject_full(hospital_reject_full),.reject_conflict(hospital_reject_conflict),
  .queued_events(hospital_queued_events),.tx_ready(touch_tx_ready),
  .tx_valid(touch_tx_valid),.tx_data(touch_tx_data),.command_rejected(touch_command_rejected));
 uart_tx #(.CLK_HZ(25_000_000),.BAUD(9600)) u_touch_tx(
  .clk(video_clk),.rst(rst_video),.valid(touch_tx_valid),.data(touch_tx_data),
  .ready(touch_tx_ready),.tx(tjc_tx));
end else begin:g_no_touch
 assign touch_cmd_valid=1'b0;assign touch_cmd=0;assign touch_arg=0;assign touch_busy=1'b0;
 assign touch_command_rejected=1'b0;
 assign touch_request_valid=0;assign touch_request_kind=0;assign touch_request_card=0;assign touch_request_number=0;
 assign touch_page=2'd0;
 assign touch_tx_valid=1'b0;assign touch_tx_data=0;assign touch_tx_ready=1'b0;assign tjc_tx=1'b1;
end endgenerate
// V7：TICKET_MODE=1，触摸“取号”发号 001～020。触摸请求直连业务核心；
// 诊室命令直接作为核心按键脉冲，核心的接受/拒绝向量原样回送诊室板。
assign core_request_valid=touch_request_valid;assign core_request_kind=touch_request_kind;
assign core_request_card=touch_request_card;assign core_request_number=touch_request_number;
assign touch_request_ready=core_request_ready;assign touch_request_done=core_request_done;
// 诊室命令只有 K1/K2/K3（叫号/重播/确认求助）；屏蔽其余位，让核心里 K4..K8 的旧按键逻辑被综合删掉。
assign hospital_core_keys=hospital_link_keys & 8'h07;
assign remote_accepted=hospital_accepted_keys;assign remote_invalid=hospital_reject_invalid;
assign remote_duplicate=hospital_reject_duplicate;assign remote_full=hospital_reject_full;
assign remote_conflict=hospital_reject_conflict;
// 10/25：语音事件队列深度 4（含正在播的 1 条），为大厅资源让路；连续快速按键第 5 次提示“请求忙”。
hospital_app_core #(.TICKET_MODE(1),.SEMANTIC_INPUT(1),.ROOMS(HOSPITAL_ROOMS),.QDEPTH(4)) u_hospital_app(
 .clk(video_clk),.rst(rst_video),.key_press(hospital_core_keys),
 .event_ready(hospital_event_ready),.event_done(hospital_event_done),
 .event_done_seq(hospital_event_done_seq),.call_number(hospital_call_number),
 .issued_number(hospital_issued_number),.waiting_count(hospital_waiting_count),
 .selected_card(hospital_selected_card),.last_card(hospital_last_card),
 .last_card_valid(hospital_last_card_valid),.help_state(hospital_help_state),
 .help_seq(hospital_help_seq),.event_valid(hospital_event_valid),
 .event_data(hospital_event_data),.queued_events(hospital_queued_events),
 .busy(hospital_busy),.active_seq(hospital_active_seq),
 .accepted_keys(hospital_accepted_keys),.rejected_keys(hospital_rejected_keys),
 .reject_invalid(hospital_reject_invalid),.reject_duplicate(hospital_reject_duplicate),
 .reject_full(hospital_reject_full),.reject_conflict(hospital_reject_conflict),
 .overflow_sticky(hospital_overflow_sticky),
 .completion_error_sticky(hospital_completion_error_sticky),
 .request_valid(core_request_valid),.request_ready(core_request_ready),.request_kind(core_request_kind),
 .request_source(1'b1),.request_number(core_request_number),.request_card(core_request_card),
 .request_done(core_request_done),.request_accepted(core_request_accepted),.request_result(core_request_result),
 .history1(hospital_history1),.history2(hospital_history2),.history3(hospital_history3),.active_event(hospital_active_event),
 .key_room(hospital_link_room),.room_numbers(hospital_room_numbers),.last_room(hospital_last_room),.help_room(hospital_help_room));
// 10/25 耳鼻喉科报到登记：触摸屏 cmd 5/6/7/8 先登记，点“报到”(cmd 3) 时绑定到新号；
// 某诊室叫到该号时把登记交给该诊室（经登记帧送到诊室屏）。
hospital_registration #(.ROOMS(HOSPITAL_ROOMS)) u_registration(
 .clk(video_clk),.rst(rst_video),.cmd_valid(touch_cmd_valid),.cmd(touch_cmd),.arg(touch_arg),
 .ticket_taken(hospital_accepted_keys[7]),.issued_number(hospital_issued_number),
 .call_taken(hospital_accepted_keys[0]),.call_number(hospital_call_number),.last_room(hospital_last_room),
 .pending(hospital_reg_pending),.room_records(hospital_room_records));


// 语音命令/结果跨 video_clk 与 sd_card_clk：字段冻结 + 翻转握手（约束见 timing.sdc）。
// 调度器与播放器都只用系统复位，SD 介质复位由播放器转成读失败结果。
wire voice_cmd_toggle,voice_rsp_toggle;
wire [15:0] voice_cmd_seq,voice_rsp_seq;
wire [2:0] voice_cmd_count,voice_rsp_status;
wire [19:0] voice_cmd_clips;
wire voice_go_toggle,voice_drained_toggle;
wire voice_fifo_wr_en,voice_fifo_rd_en,voice_fifo_empty;
wire [16:0] voice_fifo_wr_data,voice_fifo_rd_data;
wire [11:0] voice_fifo_free;
generate if(VOICE_ENABLE!=0) begin:g_voice
 hospital_voice_dispatch u_voice_dispatch(
  .clk(video_clk),.rst(rst_video),.event_valid(hospital_event_valid),.event_data(hospital_event_data),
  .event_ready(hospital_event_ready),.event_done(hospital_event_done),.event_done_seq(hospital_event_done_seq),
  .cmd_toggle(voice_cmd_toggle),.cmd_seq(voice_cmd_seq),.cmd_count(voice_cmd_count),.cmd_clips(voice_cmd_clips),
  .rsp_toggle(voice_rsp_toggle),.rsp_seq(voice_rsp_seq),.rsp_status(voice_rsp_status),
  .voice_busy(hospital_voice_busy),.last_status(hospital_voice_status),.last_seq(),
  .degraded(),.protocol_error_sticky());
 hospital_voice_player u_voice_player(
  .clk(sd_card_clk),.rst(rst_sd),.cmd_toggle(voice_cmd_toggle),.cmd_seq(voice_cmd_seq),
  .cmd_count(voice_cmd_count),.cmd_clips(voice_cmd_clips),.rsp_toggle(voice_rsp_toggle),
  .rsp_seq(voice_rsp_seq),.rsp_status(voice_rsp_status),.clip_start(clip_start),.clip_id(clip_id),
  .clip_done(clip_done),.clip_failed(clip_failed),.clip_error(clip_error),.voice_reset(voice_media_reset),
  .clip_byte_valid(clip_byte_valid),.clip_byte(clip_byte),.clip_byte_ready(clip_byte_ready),
  .clip_sector_ready(clip_sector_ready),.fifo_wr_en(voice_fifo_wr_en),.fifo_wr_data(voice_fifo_wr_data),
  .fifo_free(voice_fifo_free),.go_toggle(voice_go_toggle),.drained_toggle(voice_drained_toggle),
  .busy(),.last_clip_error());
 voice_sample_fifo u_voice_fifo(.wr_clk(sd_card_clk),.wr_rst(rst_sd),.wr_en(voice_fifo_wr_en),
  .wr_data(voice_fifo_wr_data),.wr_free(voice_fifo_free),.rd_clk(audio_mclk),.rd_rst(rst_audio),
  .rd_en(voice_fifo_rd_en),.rd_data(voice_fifo_rd_data),.rd_empty(voice_fifo_empty));
end else begin:g_display_only
 // 仅显示消费者：取到事件下一拍回执，不代表语音完成。
 reg done_q; reg [15:0] done_seq_q;
 always @(posedge video_clk or posedge rst_video)
  if(rst_video) begin done_q<=0; done_seq_q<=0; end
  else begin done_q<=hospital_event_valid; if(hospital_event_valid) done_seq_q<=hospital_event_data[43:28]; end
 assign hospital_event_ready=1'b1;
 assign hospital_event_done=done_q;
 assign hospital_event_done_seq=done_seq_q;
 assign hospital_voice_busy=1'b0;
 assign hospital_voice_status=3'd5;
 assign voice_cmd_toggle=1'b0;assign voice_cmd_seq=0;assign voice_cmd_count=0;assign voice_cmd_clips=0;
 assign voice_rsp_toggle=1'b0;assign voice_rsp_seq=0;assign voice_rsp_status=0;
 assign clip_start=1'b0;assign clip_id=0;assign clip_byte_ready=1'b0;assign clip_sector_ready=1'b0;
 assign voice_go_toggle=1'b0;assign voice_fifo_wr_en=1'b0;assign voice_fifo_wr_data=0;assign voice_fifo_free=0;
 assign voice_fifo_rd_data=0;assign voice_fifo_empty=1'b1;
end endgenerate

wire [23:0] hospital_osd_rgb;
wire hospital_osd_de;
wire [11:0] screen_y=video_y-VIDEO_V_BLANK;
// 10/24 UI v3：全屏照片 + 抗锯齿文字（顶栏/底部信息区为浅色半透明带）。
// 10/25：演示配置为 1、2 诊室（rooms_present）；协议支持 4 个诊室。
// 10/26 扩展要求3 演示：SW4 拨上时底行显示“PIC2.BMP  原图 1024×768 → 显示 640×480”。数字来自
// 板子自己解析的 BMP 文件头和缩放器算出的尺寸（bmp_res_info，SD 域写、像素域按当前图片号读）。
reg res_sw_sync1,res_sw_sync2;
reg [1:0] res_index;                       // 当前显示的图片号，只在帧起点更新
wire [59:0] res_cells;
always @(posedge video_clk or posedge rst_video) begin
 if(rst_video) begin res_sw_sync1<=0;res_sw_sync2<=0;res_index<=0;end
 else begin
  res_sw_sync1<=res_sw;res_sw_sync2<=res_sw_sync1;
  if(frame_start) res_index<=active_index;
 end
end
bmp_res_info u_res_info(.clk(sd_card_clk),.rst(rst_sd),.commit(commit_frame),.index(load_index),
 .src_w(img_w),.src_h(img_h),.fit_w(img_fit_w),.fit_h(img_fit_h),
 .rd_clk(video_clk),.rd_index(res_index),.cells(res_cells));
hospital_screen #(.H_BLANK(VIDEO_H_BLANK)) u_hospital_osd(
 .clk(video_clk),.rst(rst_video),.frame_start(frame_start),
 .in_de(osd_de_out),.in_rgb(waveform_rgb_out),
 .video_x(video_x),.pixel_y(screen_y),
 .call_number(hospital_call_number),
 .issued_number(hospital_issued_number),.waiting_count(hospital_waiting_count),
 .help_state(hospital_help_state),.voice_status(hospital_voice_status),
 .brightness_idx(brightness_idx),.contrast_idx(contrast_idx),
 .volume_mode(volume_mode),.volume_target(volume_target_voice),.music_level(music_level),.voice_level(voice_level),
 .reject_invalid(hospital_reject_invalid),.reject_duplicate(hospital_reject_duplicate),
 .reject_full(hospital_reject_full),.reject_conflict(hospital_reject_conflict),
 .history1(hospital_history1),.history2(hospital_history2),.history3(hospital_history3),
 .room_numbers(hospital_room_numbers),.last_room(hospital_last_room),.help_room(hospital_help_room),
 .call_needs(hospital_room_records[12*hospital_last_room+8 +: 4]),
 .replay_pulse(hospital_accepted_keys[1] | hospital_accepted_keys[6]),   // 10/26：重播也显示“请留意屏幕”
 .rooms_present(HOSPITAL_ROOMS>=4 ? 4'b1111:HOSPITAL_ROOMS==3 ? 4'b0111:4'b0011),
 .phy_connected(LINK_ETH!=0 && eth_phy_state==4),.clinic_online(hospital_clinic_online),
 .media_ready(display_valid),.auto_enabled(auto_enabled),.media_error(osd_error_value),
 .res_show(res_sw_sync2),.res_pic(res_index),.res_cells(res_cells),
 .out_de(hospital_osd_de),.out_rgb(hospital_osd_rgb));
rgb_video_adapter u_video_adapter(.pclk(video_clk),.rst_n(~rst_video),
 .hs_in(hs_0),.vs_in(vs_0),.de_in(hospital_osd_de),.rgb_in(hospital_osd_rgb),
 .video_clk(),.video_hs(hs),.video_vs(vs),.video_de(de),.video_rgb(vout_data));

seg_decoder seg_decoder_m0(
    .bin_data          (state_code_board),
    .seg_data          (seg_data_0)
);

seg_decoder seg_error_m0(.bin_data(error_display),.seg_data(seg_error));
// V7-2：单板链路自检时，6 个数码管显示 发送/接收/错误 三个十六进制字节。
// The link test runs in the video clock domain, like the rest of the business logic, so
// frames are queued on frame boundaries and no extra clock crossing is needed. It is
// compiled in only when asked for: slice usage is already tight, so the default build
// must not pay for a self-test it does not use.
wire [47:0] loopback_disp;
generate if(LOOPBACK_ENABLE!=0) begin:g_loopback
 link_loopback_test #(.CLK_HZ(25_000_000), .BAUD(1_000_000)) u_link_loopback(
    .clk(video_clk), .rst(rst_video), .frame_start(frame_start), .enable(1'b1),
    .link_rx(link_rx), .link_tx(link_tx), .disp(loopback_disp), .link_up_led(),
    .sent_count(), .ok_count(), .err_count());
end else begin:g_no_loopback
 assign loopback_disp = 48'hffffff_ffff_ff;
end endgenerate
// V7-4：大厅板链路端点。状态帧格式与命令定义见 V7 方案第 8 节；医生命令按 K1/K2/K3
// 脉冲与本地按键/触摸相或，业务核心的拒绝/重复规则照常适用。
// V8：LINK_ETH=1 时帧字节经 eth_link 走网口（以太网原始帧，EtherType 0x88B5）。
wire eth_tx_valid, eth_tx_ready, eth_rx_valid;
wire [7:0] eth_tx_data, eth_rx_data;
wire [15:0] eth_frames_ok;
generate if(LOOPBACK_ENABLE==0 && LINK_ENABLE!=0 && LINK_ETH!=0) begin:g_eth
 eth_link #(.MAC_ADDR(48'h02_48_41_4c_4c_01), .LOOPBACK(ETH_PHY_LOOPBACK)) u_eth_link(
    .clk(video_clk), .rst(rst_video), .clk5(hdmi_5x_clk),
    .src_valid(eth_tx_valid), .src_data(eth_tx_data), .src_ready(eth_tx_ready),
    .out_valid(eth_rx_valid), .out_data(eth_rx_data),
    .eth_txc(eth_txc), .eth_txd(eth_txd), .eth_tx_ctl(eth_tx_ctl),
    .eth_rxc(eth_rxc), .eth_rxd(eth_rxd), .eth_rx_ctl(eth_rx_ctl),
    .eth_mdc(eth_mdc), .eth_mdio(eth_mdio),
    .phy_state(eth_phy_state), .phy_addr(), .phy_link_ok(),
    .frames_sent(), .frames_ok(eth_frames_ok), .frames_bad(), .frames_dropped());
end else begin:g_no_eth
 assign eth_tx_ready = 1'b0; assign eth_rx_valid = 1'b0; assign eth_rx_data = 8'h00;
 assign eth_phy_state = 4'h0; assign eth_frames_ok = 16'h0000;
 assign eth_txc = 1'b0; assign eth_txd = 4'h0; assign eth_tx_ctl = 1'b0;
 assign eth_mdc = 1'b0; assign eth_mdio = 1'bz;
end endgenerate
generate if(LOOPBACK_ENABLE==0 && LINK_ENABLE!=0) begin:g_link
 link_master #(.CLK_HZ(25_000_000), .BAUD(1_000_000), .LINK_TIMEOUT_CYCLES(25_000_000),
               .ETH(LINK_ETH), .ROOMS(HOSPITAL_ROOMS)) u_link_master(
    .clk(video_clk), .rst(rst_video), .frame_start(frame_start),
    .link_rx(link_rx), .link_tx(link_tx),
    .eth_tx_valid(eth_tx_valid), .eth_tx_data(eth_tx_data), .eth_tx_ready(eth_tx_ready),
    .eth_rx_valid(eth_rx_valid), .eth_rx_data(eth_rx_data),
    .call_number(hospital_call_number), .issued_number(hospital_issued_number),
    .waiting_count(hospital_waiting_count), .help_state(hospital_help_state),
    .help_room(hospital_help_room), .last_room(hospital_last_room),
    .room_numbers(hospital_room_numbers), .room_records(hospital_room_records),
    .core_accepted(remote_accepted), .core_invalid(remote_invalid),
    .core_duplicate(remote_duplicate), .core_full(remote_full),
    .core_conflict(remote_conflict),
    .key_press(hospital_link_keys), .key_room(hospital_link_room), .link_up(hospital_clinic_online),
    .cmds_executed(), .cmds_repeated(), .cmds_bad());
end else begin:g_no_link
 assign hospital_link_keys = 8'h00; assign hospital_link_room = 2'd0;
 assign hospital_clinic_online=1'b0;
 assign eth_tx_valid = 1'b0; assign eth_tx_data = 8'h00;
 if (LOOPBACK_ENABLE==0) begin:g_idle_tx
  assign link_tx = 1'b1;                 // J2 pin 1 idle when the link is off
 end
end endgenerate
wire [7:0] seg_d0 = LOOPBACK_ENABLE!=0 ? loopback_disp[7:0]  : (error_display==0 ? 8'hff : {1'b1,7'b000_0110});
wire [7:0] seg_d1 = LOOPBACK_ENABLE!=0 ? loopback_disp[15:8] : (error_display==0 ? 8'hff : {1'b1,seg_error});
// V8：网口链路时第 3 位显示网口状态（4=100M 已连通，见 eth_phy_ctrl.v），
// 第 4、5 位显示收到的有效以太网帧数低 8 位（十六进制，持续增长说明诊室板在发）。
wire eth_seg_on = LOOPBACK_ENABLE==0 && LINK_ENABLE!=0 && LINK_ETH!=0;
wire [6:0] seg_eth_state, seg_eth_hi, seg_eth_lo;
seg_decoder seg_eth_state_m0(.bin_data(eth_phy_state),.seg_data(seg_eth_state));
seg_decoder seg_eth_hi_m0(.bin_data(eth_frames_ok[7:4]),.seg_data(seg_eth_hi));
seg_decoder seg_eth_lo_m0(.bin_data(eth_frames_ok[3:0]),.seg_data(seg_eth_lo));
wire [7:0] seg_d2 = LOOPBACK_ENABLE!=0 ? loopback_disp[23:16] : eth_seg_on ? {1'b1,seg_eth_state} : {1'b1,7'b1111_111};
wire [7:0] seg_d3 = LOOPBACK_ENABLE!=0 ? loopback_disp[31:24] : eth_seg_on ? {1'b1,seg_eth_hi} : {1'b1,7'b1111_111};
wire [7:0] seg_d4 = LOOPBACK_ENABLE!=0 ? loopback_disp[39:32] : eth_seg_on ? {1'b1,seg_eth_lo} : {1'b1,7'b1111_111};
wire [7:0] seg_d5 = LOOPBACK_ENABLE!=0 ? loopback_disp[47:40] : {1'b1,seg_data_0};
// E1~E6 使用原来空闲的两位；图片编号与音频选择仍取 state_code。
seg_scan seg_scan_m0(
    .clk               (clk),
    .rst_n             (~rst_board),
    .seg_sel           (seg_sel),
    .seg_data          (seg_data),
    .seg_data_0        (seg_d0),
    .seg_data_1        (seg_d1),
    .seg_data_2        (seg_d2),
    .seg_data_3        (seg_d3),
    .seg_data_4        (seg_d4),
    .seg_data_5        (seg_d5)
);

sdram U3(
    .Clk               (ext_mem_clk),
    .Clk_sft           (ext_mem_clk_sft),
    .Rst               (rst_mem),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),
    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_dm         (App_wr_dm),
    .App_wr_din        (App_wr_din),
    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout)
);

// 第11讲：FAT32 AUDIO.PCM → 异步 BRAM → 三选一 PCM → 原官方 I2S/HDMI。
// 卡重新初始化时双侧清空指针；音频侧仍异步置位、同步释放，避免旧样本串入。
wire wav_audio_rst;
reset_sync u_wav_audio_reset(.clk(audio_mclk),.arst(rst_audio|wav_media_reset),.rst(wav_audio_rst));
wire signed [15:0] wav_sample,arp_sample,test_sample,pcm_left,pcm_right;
// B UI delivery: music -12.04dB, other PCM +1.94dB with signed saturation.
// Current HVB1 peak 26214 * 1.25 reaches 32767, without speech-library rewrites.
function signed [15:0] louder_pcm;
 input signed [15:0] sample;
 reg signed [16:0] extended,boosted;
 begin
  extended={sample[15],sample};
  boosted=extended+(extended>>>2);
  louder_pcm=boosted>17'sd32767 ? 16'sh7fff:boosted < -17'sd32768 ? 16'sh8000:boosted[15:0];
 end
endfunction
// Music now uses the explicit 0..100% user gain after source selection.
wire signed [15:0] music_quiet=wav_sample;
wire signed [15:0] test_louder=louder_pcm(test_sample);

wire wav_valid,wav_active,wav_silence,wav_ready,arp_ready,test_ready;
wire pcm_valid,pcm_ready,pcm_silence,audio_sample_tick;
wire [7:0] source_gain;
// 原三选一输出作为背景，经语音优先选择后再进 HDMI 音频桥。
wire signed [15:0] bg_left,bg_right,voice_sample;
wire signed [15:0] voice_louder=louder_pcm(voice_sample);
wire bg_valid,bg_ready,bg_silence,voice_valid,voice_ready,voice_silence,voice_active,voice_selected;
wire [7:0] bg_gain;
// 10/26：背景音乐不再跟随照片淡出（手动切图的“淡出-全黑-淡入”曾让音乐中断约 1 秒，自动轮播用
// 水平揭示不变暗所以不受影响）。照片淡入淡出不变，音乐与语音一样保持固定增益。
wire [7:0] bg_photo_gain=bg_gain;
wire [1:0] selected_audio_source;
wire [1:0] audio_media_id=(state_code_audio==0) ? 2'd0:state_code_audio[1:0]-2'd1;
wav_stream_player u_wav_stream(
 .wr_clk(sd_card_clk),.wr_rst_n(~wav_media_reset),.stream_start(wav_begin),
 .file_valid(wav_byte_valid),.file_data(wav_byte),.file_ready(wav_byte_ready),.sector_ready(wav_sector_ready),
 .file_done(wav_done),.file_failed(wav_failed),.rd_clk(audio_mclk),.rd_rst_n(~wav_audio_rst),
 .sample_tick(audio_sample_tick),.sample_ready(wav_ready),.sample_out(wav_sample),.sample_valid(wav_valid),
 .sample_silence(wav_silence),.stream_active(wav_active),.stream_end(),.buffer_low(),.underflow(),.sample_counter());
// 回落琶音置零而不是去掉音源：选择器仍有有效样本可取，HDMI 音频流连续，语音优先切换照旧。
wire signed [15:0] arp_audible=(ARP_FALLBACK_ENABLE!=0 || AUDIO_SOURCE_MODE==1) ? arp_sample:16'sd0;
wire signed [15:0] arp_louder=louder_pcm(arp_audible);
media_pcm_tones u_pcm_tones(.clk(audio_mclk),.rst(rst_audio),.media_id(audio_media_id),
 .arp_ready(arp_ready),.test_ready(test_ready),.arp_sample(arp_sample),.test_sample(test_sample));
audio_source_mux u_audio_mux(.clk(audio_mclk),.rst_n(~rst_audio),
 .wav_valid(wav_valid),.wav_active(wav_active),.wav_silence(wav_silence),.wav_left(music_quiet),.wav_right(music_quiet),.wav_ready(wav_ready),
 .arp_valid(1'b1),.arp_left(arp_louder),.arp_right(arp_louder),.arp_ready(arp_ready),
 .test_valid(1'b1),.test_left(test_louder),.test_right(test_louder),.test_ready(test_ready),
 .force_arpeggio(AUDIO_SOURCE_MODE==1),.force_test(AUDIO_SOURCE_MODE==2),
 .out_valid(bg_valid),.out_ready(bg_ready),.out_left(bg_left),.out_right(bg_right),
 .out_silence(bg_silence),.source_gain(bg_gain),.selected_source(selected_audio_source));
generate if(VOICE_ENABLE!=0) begin:g_voice_out
 voice_audio_out u_voice_out(.clk(audio_mclk),.rst(rst_audio),.go_toggle(voice_go_toggle),
  .sample_tick(audio_sample_tick),.sample_ready(voice_ready),.fifo_rd_en(voice_fifo_rd_en),
  .fifo_rd_data(voice_fifo_rd_data),.fifo_empty(voice_fifo_empty),.sample_out(voice_sample),
  .sample_valid(voice_valid),.sample_silence(voice_silence),.active(voice_active),
  .drained_toggle(voice_drained_toggle),.underflow_count());
end else begin:g_no_voice_out
 assign voice_fifo_rd_en=1'b0;assign voice_sample=0;assign voice_valid=1'b0;assign voice_silence=1'b1;
 assign voice_active=1'b0;assign voice_drained_toggle=1'b0;
end endgenerate
voice_priority_mux u_voice_pmux(.clk(audio_mclk),.rst_n(~rst_audio),
 .bg_valid(bg_valid),.bg_silence(bg_silence),.bg_left(bg_left),.bg_right(bg_right),.bg_gain(bg_photo_gain),.bg_ready(bg_ready),
 .voice_valid(voice_valid),.voice_active(voice_active),.voice_silence(voice_silence),.voice_sample(voice_louder),
 .voice_ready(voice_ready),.out_valid(pcm_valid),.out_silence(pcm_silence),.out_left(pcm_left),.out_right(pcm_right),
 .out_ready(pcm_ready),.out_gain(source_gain),.voice_selected(voice_selected));
// 第12讲：WAV valid 是保持电平，必须在实际消费时抽样；不改变 WAV 的 ready。
// 仅显示选中的 WAV 原始 PCM，音量淡出不会修改该观察支路的样本值。
// 阶段C：播报语音时波形改为显示正在播出的语音样本。
wire wave_pix_rst;
reg wave_enable_audio;
reset_sync u_wave_pix_reset(.clk(video_clk),.arst(rst_video|wav_media_reset),.rst(wave_pix_rst));
always @(posedge audio_mclk or posedge wav_audio_rst)
 if(wav_audio_rst) wave_enable_audio<=0;
 else wave_enable_audio<=voice_selected || (wav_active && selected_audio_source==2'd0);
cdc_level u_wave_enable(.clk(video_clk),.rst(wave_pix_rst),
 .async_in(wave_enable_audio),.level_out(waveform_enable_pix));
pcm_tap_cdc u_wave_tap(
 .src_clk(audio_mclk),.src_rst(wav_audio_rst),
 .src_valid(audio_sample_tick && ((wav_ready && wav_valid) || (voice_ready && voice_valid && !voice_silence))),
 .src_sample(voice_selected ? voice_sample:wav_sample),.src_busy(),
 .dst_clk(video_clk),.dst_rst(wave_pix_rst),.dst_valid(pcm_tap_valid),.dst_sample(pcm_tap_left));
wire [7:0] user_levels_audio;
cdc_status #(.WIDTH(8)) u_user_volume_cdc(.src_clk(video_clk),.src_rst(rst_video),
 .src_data({voice_level,music_level}),.dst_clk(audio_mclk),.dst_rst(rst_audio),.dst_data(user_levels_audio));
wire signed [15:0] user_pcm_left,user_pcm_right;
hospital_user_volume u_user_volume(.clk(audio_mclk),.rst(rst_audio),.sample_tick(audio_sample_tick),
 .voice_selected(voice_selected || selected_audio_source!=2'd0),.music_level(user_levels_audio[3:0]),.voice_level(user_levels_audio[7:4]),
 .in_left(pcm_left),.in_right(pcm_right),.out_left(user_pcm_left),.out_right(user_pcm_right));
media_hdmi_audio_bridge u_audio_bridge(.audio_clk(audio_mclk),.audio_rst(rst_audio),.pixel_clk(video_clk),.pixel_rst(rst_video),
 .pcm_valid(pcm_valid),.pcm_silence(pcm_silence),.pcm_left(user_pcm_left),.pcm_right(user_pcm_right),
 .source_gain(source_gain),.frame_gain(8'd255),.pcm_ready(pcm_ready),.sample_tick(audio_sample_tick),
 .i2s_bclk(audio_i2s_bclk),.i2s_lrck(audio_i2s_lrck),.i2s_dout(audio_i2s_dout),
 .audio_valid(audio_valid),.audio_left_data(audio_left_data),.audio_right_data(audio_right_data),
 .acr_valid(acr_valid),.acr_cts(acr_cts),.acr_n(acr_n));

// ===================== RGB/DE 转 AXIS 视频 =====================
video_rgb_to_axis_640x480 u_video_rgb_to_axis_640x480(
    .I_clk         (video_clk),
    .I_rst         (rst_video),
    .I_vs          (vs),
    .I_de          (de),
    .I_rgb         (vout_data),
    .O_video_user  (axis_raw_user),
    .O_video_valid (axis_raw_valid),
    .O_video_last  (axis_raw_last),
    .O_video_data  (axis_raw_data)
);

// APUG092 section 2.4.2 requires line_length=640, line_space=800,
// frame_space=525. This is a timed raster input, not an elastic AXIS sink.
// A ready-gated FIFO drains the horizontal blanking gap, destroys alignment,
// then holds VALID forever when the core rejects that malformed input.
// Preserve the original raster, including blanking. The official video_source_test
// likewise does not gate its raster with I_video_ready. Tested with the actual
// encrypted HDMI core: every active pixel is ready after alignment.
assign {axis_s_user,axis_s_valid,axis_s_last,axis_s_data}=
       {axis_raw_user,axis_raw_valid,axis_raw_last,axis_raw_data};
hdmi_raster_monitor u_hdmi_input_monitor(.clk(video_clk),.rst(rst_video),
 .video_sof(axis_s_user && axis_s_valid),.video_valid(axis_s_valid),
 .video_ready(axis_s_ready),.video_locked(hdmi_video_locked),.fault(axis_input_fault));

// 上电后自动打一拍，触发一次 EDID 读取
startup_pulse #(
    .CNT_MAX(20'd100000)
) u_startup_pulse (
    .I_clk   (video_clk),
    .I_rst   (rst_video),
    .O_pulse (edid_trig)
);

// ===================== 带音频的 HDMI 1.4b 发射 =====================
hdmi_1_4b_transmitter_core_wrapper #(
    .DEVICE                 ( "EG"       ),
    .HTOTAL                 ( 800        ),
    .HSA                    ( 96         ),
    .HFP                    ( 16         ),
    .HBP                    ( 48         ),
    .HACTIVE                ( 640        ),
    .VTOTAL                 ( 525        ),
    .VSA                    ( 2          ),
    .VFP                    ( 10         ),
    .VBP                    ( 33         ),
    .VACTIVE                ( 480        ),
    .VIDEO_VIC              ( 1          ),
    .VIDEO_TPG              ( "Disable"  ),
    .VIDEO_FORMAT           ( "RGB"      ),
    .AUDIO_SAMPLE_RATE      ( "48K"      ),
    .IIC_SCL_DIV            ( 250        )
) u_hdmi_1_4b_transmitter_core_wrapper(
    .I_pixel_clk        (video_clk),
    .I_rst              (rst_video),
    // 10/29：EDID 读出的数据本工程从未使用（输出固定 640x480），不再触发读取，TD 删去这部分逻辑，
    // 省下的约 300 个 LUT 用于音频频谱柱（扩展要求5）。
    .I_edid_read_trig   (1'b0),
    .O_edid_read_valid  (edid_valid),
    .O_edid_read_data   (edid_data),

    .I_axis_s_user      (axis_s_user),
    .I_axis_s_valid     (axis_s_valid),
    .I_axis_s_last      (axis_s_last),
    .I_axis_s_data      (axis_s_data),
    .O_axis_s_ready     (axis_s_ready),

    .I_audio_valid      (audio_valid),
    .I_audio_left_data  (audio_left_data),
    .I_audio_right_data (audio_right_data),
    .I_acr_valid        (acr_valid),
    .I_acr_cts          (acr_cts),
    .I_acr_n            (acr_n),

    .O_video_locked     (hdmi_video_locked),
    .O_ddc_scl          (HDMI_DDC_SCL),
    .IO_ddc_sda         (HDMI_DDC_SDA),

    .O_ch0_tmds_data    (tmds_ch0_data),
    .O_ch1_tmds_data    (tmds_ch1_data),
    .O_ch2_tmds_data    (tmds_ch2_data),
    .O_clk_tmds_data    (tmds_clk_data)
);

hdmi_phy_wrapper #(
    .DEVICE ( "EG" )
) u_hdmi2phy_wrapper(
    .I_pixel_clk        (video_clk),
    .I_serial_clk       (hdmi_5x_clk),
    .I_rst              (rst_video),
    .I_tmds_channel_0   (tmds_ch0_data),
    .I_tmds_channel_1   (tmds_ch1_data),
    .I_tmds_channel_2   (tmds_ch2_data),
    .I_tmds_channel_clk (tmds_clk_data),
    .O_tmds_ch0_p       (HDMI_D0_P),
    .O_tmds_ch1_p       (HDMI_D1_P),
    .O_tmds_ch2_p       (HDMI_D2_P),
    .O_tmds_clk_p       (HDMI_CLK_P)
);

endmodule
