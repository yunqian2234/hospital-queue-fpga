`timescale 1ns/1ps
// 阶段C：语音优先选择（音频域），位于原 audio_source_mux 之后、HDMI 音频桥之前。
// 语音 active 时先把背景（原选择器输出）淡到零再切到语音，句子结束后语音淡出再切回。
// 切换只在采样握手边界发生；未选中的一侧不给 ready，保持其样本与内部状态不丢失。
// 原选择器与其测试不变；out_gain 合成原选择器增益与本级淡入淡出增益。
module voice_priority_mux #(parameter [7:0] STEP=8'd8)(
    input clk, rst_n,
    input bg_valid, bg_silence, input signed [15:0] bg_left, bg_right,
    input [7:0] bg_gain, output bg_ready,
    input voice_valid, voice_active, voice_silence, input signed [15:0] voice_sample,
    output voice_ready,
    output out_valid, out_silence, output signed [15:0] out_left, out_right,
    input out_ready, output [7:0] out_gain,
    output reg voice_selected
);
reg [7:0] gain;
wire [15:0] product=bg_gain*gain;
assign out_valid=voice_selected ? voice_valid:bg_valid;
assign out_silence=voice_selected ? voice_silence:bg_silence;
assign out_left=voice_selected ? voice_sample:bg_left;
assign out_right=voice_selected ? voice_sample:bg_right;
assign out_gain=voice_selected ? gain:(gain==8'd255 ? bg_gain:product[15:8]);
assign bg_ready=rst_n && out_ready && !voice_selected;
assign voice_ready=rst_n && out_ready && voice_selected;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin voice_selected<=0; gain<=8'd255; end
    else if(out_ready) begin
        if(voice_active!=voice_selected) begin
            if(gain>STEP) gain<=gain-STEP;
            else begin gain<=0; voice_selected<=voice_active; end
        end else if(gain<8'd255-STEP) gain<=gain+STEP;
        else gain<=8'd255;
    end
end
endmodule
