`timescale 1ns/1ps
// 阶段C：语音输出（音频 12.288MHz 域）。收到 go 翻转后从 voice_sample_fifo 预取样本，
// 以与 wav_stream_player 相同的保持型 valid 握手交给 audio_source_mux；
// 句尾标记被装入输出寄存器时，说明句子最后一个样本已被音频桥取走，翻转 drained。
// 句中 FIFO 暂空时输出静音并计入 underflow_count（首个样本前的等待不计）。
module voice_audio_out(
    input clk, rst,
    input go_toggle,
    input sample_tick, sample_ready,
    output fifo_rd_en, input [16:0] fifo_rd_data, input fifo_empty,
    output reg signed [15:0] sample_out, output reg sample_valid,
    output sample_silence, output reg active,
    output reg drained_toggle, output reg [15:0] underflow_count
);
reg g_s1, g_s2, g_seen, read_pending, head_valid, out_pcm, primed;
reg [16:0] head;
wire take=sample_tick && sample_ready && sample_valid;
assign fifo_rd_en=active && !fifo_empty && !read_pending && !head_valid;
assign sample_silence=!out_pcm;
always @(posedge clk or posedge rst) begin
    if(rst) begin
        g_s1<=0; g_s2<=0; g_seen<=0; read_pending<=0; head_valid<=0; head<=0;
        sample_out<=0; sample_valid<=0; out_pcm<=0; primed<=0; active<=0;
        drained_toggle<=0; underflow_count<=0;
    end else begin
        g_s1<=go_toggle; g_s2<=g_s1;
        if(g_s2!=g_seen) begin g_seen<=g_s2; active<=1; primed<=0; end
        if(fifo_rd_en) read_pending<=1;
        if(read_pending) begin head<=fifo_rd_data; head_valid<=1; read_pending<=0; end
        if(!sample_valid || take) begin
            sample_valid<=1;
            if(head_valid && !head[16]) begin
                sample_out<=head[15:0]; out_pcm<=1; head_valid<=0; primed<=1;
            end else begin
                sample_out<=0; out_pcm<=0;
                if(head_valid) begin
                    head_valid<=0; active<=0; drained_toggle<=~drained_toggle;
                end else if(take && active && primed && underflow_count!=16'hffff)
                    underflow_count<=underflow_count+1'b1;
            end
        end
    end
end
endmodule
