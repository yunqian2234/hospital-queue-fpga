`timescale 1ns/1ps
// 第11讲修复：从 media_hdmi_audio_bridge.v 拆出完整音调源；模块只定义一次。
// 算法保持原已验证版本：四首六音符琶音，250ms/音符；切图提示音 1.5kHz/100ms。
// media_id 是图片下标 0..3（2 位），与顶层 audio_media_id 一致。
// clk = 12.288MHz；ready 是下游的 48kHz 采样使能，不在本模块重新分频。
// ready=0 时保持对应相位、输出样本和播放进度；音调表用常量 case，可直接综合。
module media_pcm_tones (
    input  wire clk,
    input  wire rst,
    input  wire [1:0] media_id,
    input  wire arp_ready,
    input  wire test_ready,
    output reg signed [15:0] arp_sample,
    output reg signed [15:0] test_sample
);

function [19:0] melody_inc;
    input [1:0] melody;
    input [2:0] note;
    begin
        case ({melody, note})
            // 0: C大调上行 C5 E5 G5 C6 G5 E5
            5'b00_000: melody_inc = 20'd11426;  // C5 523 Hz
            5'b00_001: melody_inc = 20'd14396;  // E5 659 Hz
            5'b00_010: melody_inc = 20'd17127;  // G5 784 Hz
            5'b00_011: melody_inc = 20'd22860;  // C6 1046 Hz
            5'b00_100: melody_inc = 20'd17127;  // G5
            5'b00_101: melody_inc = 20'd14396;  // E5
            // 1: A小调 A4 C5 E5 A5 E5 C5
            5'b01_000: melody_inc = 20'd9634;   // A4 440 Hz
            5'b01_001: melody_inc = 20'd11426;  // C5
            5'b01_010: melody_inc = 20'd14396;  // E5
            5'b01_011: melody_inc = 20'd19269;  // A5 880 Hz
            5'b01_100: melody_inc = 20'd14396;  // E5
            5'b01_101: melody_inc = 20'd11426;  // C5
            // 2: 五声音阶 C5 D5 E5 G5 A5 C6
            5'b10_000: melody_inc = 20'd11426;  // C5
            5'b10_001: melody_inc = 20'd12833;  // D5 587 Hz
            5'b10_010: melody_inc = 20'd14396;  // E5
            5'b10_011: melody_inc = 20'd17127;  // G5
            5'b10_100: melody_inc = 20'd19269;  // A5
            5'b10_101: melody_inc = 20'd22860;  // C6
            // 3: 低高摇摆 C5 G4 E5 C5 G4 E5
            5'b11_000: melody_inc = 20'd11426;  // C5
            5'b11_001: melody_inc = 20'd8566;   // G4 392 Hz
            5'b11_010: melody_inc = 20'd14396;  // E5
            5'b11_011: melody_inc = 20'd11426;  // C5
            5'b11_100: melody_inc = 20'd8566;   // G4
            5'b11_101: melody_inc = 20'd14396;  // E5
            default:   melody_inc = 20'd11426;
        endcase
    end
endfunction

function signed [15:0] sine_sample;
    input [3:0] index;
    begin
        case (index)
            4'd0 : sine_sample =  16'sd0;
            4'd1 : sine_sample =  16'sd4592;
            4'd2 : sine_sample =  16'sd8485;
            4'd3 : sine_sample =  16'sd11087;
            4'd4 : sine_sample =  16'sd12000;
            4'd5 : sine_sample =  16'sd11087;
            4'd6 : sine_sample =  16'sd8485;
            4'd7 : sine_sample =  16'sd4592;
            4'd8 : sine_sample =  16'sd0;
            4'd9 : sine_sample = -16'sd4592;
            4'd10: sine_sample = -16'sd8485;
            4'd11: sine_sample = -16'sd11087;
            4'd12: sine_sample = -16'sd12000;
            4'd13: sine_sample = -16'sd11087;
            4'd14: sine_sample = -16'sd8485;
            default: sine_sample = -16'sd4592;
        endcase
    end
endfunction

reg [19:0] arp_phase, test_phase;
reg [1:0] media_seen;
reg [12:0] blip_left;
reg [13:0] note_samples;
reg [2:0] note_index;

// 20 位 DDS，相位最高 4 位访问 16 点正弦表。
// 原琶音音量维持 255/256；测试音维持约 1kHz、峰值 12000。
wire [19:0] increment = blip_left != 0 ? 20'd32768 : melody_inc(media_seen, note_index);
wire signed [23:0] arp_scaled = sine_sample(arp_phase[19:16]) * 16'sd255;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        arp_phase   <= 0;
        test_phase  <= 0;
        media_seen  <= 0;
        blip_left   <= 0;
        note_samples <= 0;
        note_index  <= 0;
        arp_sample  <= 0;
        test_sample <= 0;
    end else begin
        if (arp_ready) begin
            arp_sample <= arp_scaled[23:8];
            arp_phase  <= arp_phase + increment;
            if (blip_left != 0) begin
                blip_left <= blip_left - 1'b1;
            end else if (note_samples == 11999) begin
                note_samples <= 0;
                note_index <= note_index == 5 ? 3'd0 : note_index + 1'b1;
            end else begin
                note_samples <= note_samples + 1'b1;
            end
        end

        if (test_ready) begin
            test_sample <= sine_sample(test_phase[19:16]);
            test_phase  <= test_phase + 20'd21845;
        end

        // 切图优先于同拍计数：重新开始提示音和旋律，输出仍等 ready 更新。
        // WAV 播放时也记录最新图片编号，回退琶音时使用当前图片的旋律。
        if (media_id != media_seen) begin
            media_seen  <= media_id;
            blip_left   <= 4800;
            note_index  <= 0;
            note_samples <= 0;
        end
    end
end
endmodule
