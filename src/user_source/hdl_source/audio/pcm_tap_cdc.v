`timescale 1ns/1ps
// 第12讲：逐样本事件握手。与 cdc_status 不同，相同 PCM 值也逐次传递。
// 源域仅观察实际 sample_tick && ready && valid，不反压原音频播放链路。
// 48kHz 的事件间隔为 256 个音频时钟；三级 req/ack 往返远小于该间隔。
// 两端必须共同异步复位、分别同步释放；数据保持到 ack 返回，并有 SDC max_delay。
module pcm_tap_cdc(
    input wire src_clk, src_rst, src_valid,
    input wire signed [15:0] src_sample,
    output wire src_busy,
    input wire dst_clk, dst_rst,
    output reg dst_valid,
    output reg signed [15:0] dst_sample
);
reg [15:0] hold_data; /* synthesis keep */
reg req_toggle, ack_toggle;
reg req0,req1,req2,ack0,ack1,ack2; /* synthesis keep */
assign src_busy=(req_toggle!=ack2);
always @(posedge src_clk or posedge src_rst) begin
    if(src_rst) begin
        hold_data<=0; req_toggle<=0; ack0<=0; ack1<=0; ack2<=0;
    end else begin
        ack0<=ack_toggle; ack1<=ack0; ack2<=ack1;
        if(src_valid && !src_busy) begin hold_data<=src_sample; req_toggle<=~req_toggle; end
    end
end
always @(posedge dst_clk or posedge dst_rst) begin
    if(dst_rst) begin
        req0<=0; req1<=0; req2<=0; ack_toggle<=0; dst_valid<=0; dst_sample<=0;
    end else begin
        req0<=req_toggle; req1<=req0; req2<=req1;
        dst_valid<=0;
        if(req2!=ack_toggle) begin
            dst_sample<=hold_data; dst_valid<=1; ack_toggle<=req2;
        end
    end
end
endmodule
