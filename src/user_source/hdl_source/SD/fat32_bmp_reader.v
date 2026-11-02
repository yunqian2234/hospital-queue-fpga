// 第6课：FAT32 / BMP 边界层。事务所有者锁定到扇区回放结束，失败文件不提交。
module fat32_bmp_reader #(
    parameter integer CLK_FREQ_HZ=100_000_000,
    parameter integer SD_READ_TIMEOUT_MS=1000,
    parameter [31:0] MAX_BMP_BYTES=32'd16_777_216,
    parameter integer USE_PIXEL_READY=0,ENABLE_AUDIO=0,AUDIO_LOOP=0,
    // 阶段C：VOICE.PCM 片段读取。默认关闭时不例化读取器、不参与仲裁。
    parameter integer ENABLE_VOICE=0,
    // 扩展要求3（10/21）：BMP 缩放到显示分辨率 OUT_W×OUT_H（保持宽高比，填边）
    parameter integer OUT_W=640, OUT_H=480,
    // accepted source sizes: official minimum = the output size, maximum 1920x1080
    parameter integer MIN_W=OUT_W, MIN_H=OUT_H, MAX_W=1920, MAX_H=1080
)(
    input clk, rst, sd_init_done, scan_start, scan_pause,
    output ready, output scan_done, scan_failed, scan_found,
    output [3:0] valid_mask,
    input load_start, input [1:0] load_index, input load_abort,
    output load_done, load_failed, error_valid, output [3:0] bmp_error,
    input [15:0] bmp_width, bmp_height,
    output write_req, input write_ack, output pixel_valid, output [23:0] pixel_data, input pixel_ready,
    // 10/26：本次加载的文件头宽高和缩放后尺寸（加载成功时有效，到下一次加载开始前不变），给 bmp_res_info
    output [10:0] img_w, img_h, img_fit_w, img_fit_h,
    output sd_reset_req, output sd_read, output [31:0] sd_addr,
    input [7:0] sd_data, input sd_valid, sd_end,
    // 第11讲：共享 FAT32 卷和扇区接口，音频按文件簇链流式读取。
    input audio_enable,audio_sector_ready,audio_byte_ready,
    output reg audio_begin,output audio_byte_valid,output [7:0] audio_byte,
    output audio_done,audio_failed,audio_reset,output [3:0] audio_error,
    // 阶段C：一次读取一个片段；字节流与 audio_* 相同使用 ready 反压，
    // clip_sector_ready 表示下游已有整扇区空间。voice_reset=介质复位，读取器随之清空。
    output voice_available,voice_reset,
    input clip_start,input [4:0] clip_id,
    output clip_busy,clip_done,clip_failed,output [3:0] clip_error,
    input clip_sector_ready,clip_byte_ready,
    output clip_byte_valid,output [7:0] clip_byte
);
wire media_rst=rst || !sd_init_done;
wire mounted, scan_req, file_req, adapter_ready, sector_valid, sector_done, sector_error;
wire [31:0] scan_lba, file_lba, fat_lba, data_lba, max_cluster;
wire [7:0] sector_data, spc, file_data;
wire [8:0] sector_index;
wire [3:0] shift_value, scan_error, decode_error;
wire [127:0] clusters, sizes;
wire [31:0] selected_cluster=clusters[load_index*32 +: 32];
wire [31:0] selected_size=sizes[load_index*32 +: 32];
wire streamer_busy, decoder_busy, file_done, file_failed, file_valid, file_ready, file_consume;
// decoder -> scaler
wire decode_done, decode_failed, dec_pixel_valid, dec_pixel_ready, scaler_busy, scaler_done, scaler_failed;
wire [23:0] dec_pixel_data;
wire [10:0] dec_w, dec_h;
assign img_w=dec_w;
assign img_h=dec_h;
reg scale_cfg_sent;
reg [1:0] owner;
reg owned;
wire audio_found,audio_invalid,audio_req,audio_consume,audio_stream_failed;
wire [31:0] audio_cluster,audio_size,audio_lba;
wire voice_found,voice_invalid,voice_req,voice_consume;
wire [31:0] voice_cluster,voice_size,voice_lba;
assign voice_available=ENABLE_VOICE && voice_found && mounted;
assign voice_reset=media_rst;
reg audio_started,audio_failed_latched;
wire audio_file_done;
// Each lap is a fully completed file/FAT transaction, but not the end of the
// continuous PCM stream. Do not reset either FIFO pointer or its CDC at a lap.
assign audio_done=audio_file_done && (AUDIO_LOOP==0 || audio_stream_failed);
assign audio_reset=media_rst;
assign audio_error=(audio_invalid || audio_failed_latched) ? 4'd12:4'd0;
// 正常启动先完成图片；播放中优先补一个音频扇区，其次图片、目录。
// 音频必须有整扇区空间，目录/文件只在扇区边界交还通道，禁止事务串线。
// 阶段C：语音片段优先级最高；读取器自己只在下游有整扇区空间时才对数据扇区发请求。
wire choose_voice=ENABLE_VOICE && voice_req;
wire choose_audio=ENABLE_AUDIO && audio_req && audio_sector_ready && !choose_voice;
wire file_wanted=file_req && !load_abort && !load_failed;
wire choose_file=file_wanted && !choose_audio && !choose_voice;
wire request=!owned && (choose_voice || choose_audio || file_wanted || (scan_req && !scan_pause));
wire accepted=request && adapter_ready;
// V8 时序：各读者的 grant 直接由自己的请求与更高优先级请求组成，与原式
// accepted && choose_x 逻辑等价，但不再经过汇总四路请求的 accepted（扇出 28）。
wire slot_free=!owned && adapter_ready;
// Register ownership receipts. The adapter first buffers all 512 physical
// bytes, so the receipt reaches the client long before any sector replay.
// This cuts the priority/request -> grant -> client FSM feedback path.
reg voice_grant,audio_grant,file_grant,scan_grant;
assign ready=!streamer_busy && !decoder_busy && !scaler_busy && !write_ack && sd_init_done;
assign error_valid=scan_failed || load_failed;
assign load_done=scaler_done;
assign load_failed=decode_failed || scaler_failed;
// 缩放器自身报错（源像素收完后输出仍不满一帧，不应出现）按像素数不符记 3。
assign bmp_error=decode_failed ? decode_error:scaler_failed ? 4'd3:scan_error;
// 第11讲时序：目录解析不反压。把扇区所有者判定与目录字段 CE 分开一拍，
// data/index/valid/done/error 同步寄存，最后字节和 sector_done 的先后关系不变。
reg scan_valid_q,scan_done_q,scan_error_q;
reg [7:0] scan_data_q;
reg [8:0] scan_index_q;
always @(posedge clk or posedge media_rst)begin
 if(media_rst)begin scan_valid_q<=0;scan_done_q<=0;scan_error_q<=0;scan_data_q<=0;scan_index_q<=0;end
 else begin
  scan_valid_q<=sector_valid && owned && owner==0;
  scan_done_q<=sector_done && owned && owner==0;scan_error_q<=sector_error;
  scan_data_q<=sector_data;scan_index_q<=sector_index;
 end
end
always @(posedge clk or posedge media_rst) begin
    if(media_rst) begin
        owner<=0; owned<=0;audio_begin<=0;audio_started<=0;audio_failed_latched<=0;
        voice_grant<=0;audio_grant<=0;file_grant<=0;scan_grant<=0;
    end
    else begin
        audio_begin<=0;
        voice_grant<=slot_free && choose_voice;
        audio_grant<=slot_free && choose_audio;
        file_grant<=slot_free && choose_file;
        scan_grant<=slot_free && scan_req && !scan_pause && !file_wanted && !choose_audio && !choose_voice;
        if(ENABLE_AUDIO && audio_enable && scan_done && mounted && audio_found && !audio_started && !audio_failed_latched) begin
            audio_started<=1;audio_begin<=1;
        end
        // Re-arm only a successful complete lap. Any media/read/FAT error stops
        // automatic retries until the existing media reset has flushed state.
        if(AUDIO_LOOP!=0 && audio_file_done && !audio_stream_failed)audio_started<=0;
        if(audio_stream_failed)audio_failed_latched<=1;
        if(sector_done) owned<=0;
        if(accepted) begin owned<=1; owner<=choose_voice ? 2'd3:choose_audio ? 2'd2:choose_file ? 2'd1:2'd0;end
    end
end
sd_sector_adapter #(.CLK_FREQ_HZ(CLK_FREQ_HZ),.TIMEOUT_MS(SD_READ_TIMEOUT_MS)) u_sector(
    .clk(clk),.rst(rst),.media_ready(sd_init_done),.request(request),
    .request_lba(choose_voice ? voice_lba:choose_audio ? audio_lba:choose_file ? file_lba:scan_lba),.request_ready(adapter_ready),
    .valid(sector_valid),.data(sector_data),.byte_index(sector_index),
    .consume(owner==3 ? voice_consume:owner==2 ? audio_consume:owner==1 ? file_consume:1'b1),.done(sector_done),.error(sector_error),.reset_req(sd_reset_req),
    .sd_read(sd_read),.sd_addr(sd_addr),.sd_data(sd_data),.sd_valid(sd_valid),.sd_end(sd_end));
fat32_volume_scanner #(.MAX_FILE_BYTES(MAX_BMP_BYTES),.ENABLE_AUDIO(ENABLE_AUDIO),.ENABLE_VOICE(ENABLE_VOICE)) u_volume(
    .clk(clk),.rst(media_rst),.start(scan_start),.mounted(mounted),.scan_done(scan_done),
    .failed(scan_failed),.found(scan_found),.error_code(scan_error),.valid_mask(valid_mask),
    .file_clusters(clusters),.file_sizes(sizes),.fat_lba(fat_lba),.data_lba(data_lba),
    .max_cluster(max_cluster),.sectors_per_cluster(spc),.cluster_shift(shift_value),
    .request(scan_req),.request_lba(scan_lba),.grant(scan_grant),
    .sector_valid(scan_valid_q),.sector_data(scan_data_q),.sector_index(scan_index_q),
    .sector_done(scan_done_q),.sector_error(scan_error_q),
    .audio_found(audio_found),.audio_invalid(audio_invalid),.audio_cluster(audio_cluster),.audio_size(audio_size),
    .voice_found(voice_found),.voice_invalid(voice_invalid),.voice_cluster(voice_cluster),.voice_size(voice_size));
fat32_file_streamer #(.MAX_FILE_BYTES(MAX_BMP_BYTES)) u_file(
    .clk(clk),.rst(media_rst),.start(load_start && mounted),.abort(load_abort || load_failed),
    .first_cluster(selected_cluster),.file_size(selected_size),.fat_lba(fat_lba),.data_lba(data_lba),
    .max_cluster(max_cluster),.sectors_per_cluster(spc),.cluster_shift(shift_value),
    .busy(streamer_busy),.done(file_done),.failed(file_failed),
    .request(file_req),.request_lba(file_lba),.grant(file_grant),
    .sector_valid(sector_valid && owned && owner==1),.sector_data(sector_data),.sector_index(sector_index),
    .sector_done(sector_done && owned && owner==1),.sector_error(sector_error),.sector_consume(file_consume),
    .file_valid(file_valid),.file_data(file_data),.file_ready(file_ready));
bmp_stream_decode #(.CLK_FREQ_HZ(CLK_FREQ_HZ),.TIMEOUT_MS(SD_READ_TIMEOUT_MS),.MAX_BMP_BYTES(MAX_BMP_BYTES),.USE_PIXEL_READY(1),
    .MIN_W(MIN_W),.MIN_H(MIN_H),.MAX_W(MAX_W),.MAX_H(MAX_H)) u_bmp(
    .clk(clk),.rst(media_rst),.start(load_start && mounted),.abort(load_abort),.directory_size(selected_size),
    .bmp_width(bmp_width),.bmp_height(bmp_height),.file_valid(file_valid),.file_data(file_data),.file_ready(file_ready),
    .file_done(file_done),.file_failed(file_failed),.busy(decoder_busy),.done(decode_done),.failed(decode_failed),
    .error_code(decode_error),.write_req(write_req),.write_ack(write_ack),
    .pixel_valid(dec_pixel_valid),.pixel_data(dec_pixel_data),.pixel_ready(dec_pixel_ready),
    .src_w(dec_w),.src_h(dec_h));
// 扩展要求3：解码像素（原分辨率）-> 区域平均 + 双线性 -> OUT_W×OUT_H，居中填边。
// 640×480 原图逐位直通。缩放器的输出握手即原来解码器的像素握手。
always @(posedge clk or posedge media_rst)
    if(media_rst) scale_cfg_sent<=0;
    else if(load_start || load_abort) scale_cfg_sent<=0;
    else if(write_req && write_ack) scale_cfg_sent<=1;
bmp_scaler #(.OUT_W(OUT_W),.OUT_H(OUT_H)) u_scale(
    .clk(clk),.rst(media_rst),.start(load_start && mounted),.abort(load_abort || decode_failed),
    .cfg_valid(write_req && write_ack && !scale_cfg_sent),.src_w(dec_w),.src_h(dec_h),
    .in_valid(dec_pixel_valid),.in_rgb(dec_pixel_data),.in_ready(dec_pixel_ready),
    .src_done(decode_done),
    .out_valid(pixel_valid),.out_rgb(pixel_data),
    .out_ready(USE_PIXEL_READY==0 ? 1'b1 : pixel_ready),
    .done(scaler_done),.failed(scaler_failed),.busy(scaler_busy),
    .fit_w(img_fit_w),.fit_h(img_fit_h),.box_k());
// AUDIO_LOOP=1重新读取成功结束的背景文件；缺文件/失败不反复重试。音频请求获批前预留整扇区缓冲，
// 未选中音源时不会占着 SD 扇区回放阻塞图片加载。FAT/碎片簇链沿用原 streamer。
generate if(ENABLE_AUDIO)begin:g_audio
 fat32_file_streamer #(.MAX_FILE_BYTES(32'd268435456)) u_audio_file(
  .clk(clk),.rst(media_rst),.start(audio_begin),.abort(1'b0),
  .first_cluster(audio_cluster),.file_size(audio_size),.fat_lba(fat_lba),.data_lba(data_lba),
  .max_cluster(max_cluster),.sectors_per_cluster(spc),.cluster_shift(shift_value),
  .busy(),.done(audio_file_done),.failed(audio_stream_failed),
  .request(audio_req),.request_lba(audio_lba),.grant(audio_grant),
  .sector_valid(sector_valid && owned && owner==2),.sector_data(sector_data),.sector_index(sector_index),
  .sector_done(sector_done && owned && owner==2),.sector_error(sector_error),.sector_consume(audio_consume),
  .file_valid(audio_byte_valid),.file_data(audio_byte),.file_ready(audio_byte_ready));
 assign audio_failed=audio_stream_failed;
end else begin:g_no_audio
 assign audio_req=0;assign audio_lba=0;assign audio_consume=1;
 assign audio_byte_valid=0;assign audio_byte=0;assign audio_file_done=0;
 assign audio_failed=0;assign audio_stream_failed=0;
end endgenerate
generate if(ENABLE_VOICE)begin:g_voice
 fat32_clip_reader u_clip(
  .clk(clk),.rst(media_rst),.start(clip_start),.clip_id(clip_id),.bank_valid(voice_available),
  .bank_cluster(voice_cluster),.bank_size(voice_size),.fat_lba(fat_lba),.data_lba(data_lba),
  .max_cluster(max_cluster),.sectors_per_cluster(spc),.cluster_shift(shift_value),
  .busy(clip_busy),.done(clip_done),.failed(clip_failed),.error_code(clip_error),
  .request(voice_req),.request_lba(voice_lba),.grant(voice_grant),
  .sector_valid(sector_valid && owned && owner==3),.sector_data(sector_data),.sector_index(sector_index),
  .sector_done(sector_done && owned && owner==3),.sector_error(sector_error),.sector_consume(voice_consume),
  .data_sector_ready(clip_sector_ready),
  .byte_valid(clip_byte_valid),.byte_data(clip_byte),.byte_ready(clip_byte_ready));
end else begin:g_no_voice
 assign voice_req=0;assign voice_lba=0;assign voice_consume=1;
 assign clip_busy=0;assign clip_done=0;assign clip_failed=0;assign clip_error=0;
 assign clip_byte_valid=0;assign clip_byte=0;
end endgenerate
endmodule
