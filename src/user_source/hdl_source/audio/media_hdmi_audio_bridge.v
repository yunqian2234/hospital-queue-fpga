`timescale 1ns/1ps
// 第11讲：保留已验证的官方 I2S_receiver/ACR/HDMI 打包链，只替换样本来源。
// 本工程实际 I2S 为 64 bit/声道、BCLK=MCLK/2、LRCK=MCLK/256=48kHz。
module media_hdmi_audio_bridge #(parameter DECLICK=1)(
 input audio_clk,audio_rst,pixel_clk,pixel_rst,
 input pcm_valid,pcm_silence,input signed [15:0] pcm_left,pcm_right,
 input [7:0] source_gain,frame_gain,output pcm_ready,output sample_tick,
 output reg i2s_bclk,i2s_lrck,i2s_dout,
 output audio_valid,output [23:0] audio_left_data,audio_right_data,
 output acr_valid,output [19:0] acr_cts,acr_n
);
reg [7:0] sample_count;
reg [5:0] bit_count;
reg [63:0] shift_reg;
reg [23:0] next_left,next_right,right_word;
reg [7:0] smooth_gain;
reg signed [15:0] last_left,last_right;
reg [5:0] tail_count,attack_count;
wire silent=!pcm_valid || pcm_silence;
wire [5:0] envelope=silent ? (tail_count==0 ? 6'd0:tail_count-1'b1):
                                      (attack_count<32 ? attack_count+1'b1:6'd32);
wire signed [15:0] raw_left=silent ? last_left:pcm_left;
wire signed [15:0] raw_right=silent ? last_right:pcm_right;
wire signed [22:0] shaped_l=raw_left*$signed({1'b0,envelope});
wire signed [22:0] shaped_r=raw_right*$signed({1'b0,envelope});
wire signed [15:0] shaped_left=DECLICK ? shaped_l[20:5]:(silent ? 16'sd0:pcm_left);
wire signed [15:0] shaped_right=DECLICK ? shaped_r[20:5]:(silent ? 16'sd0:pcm_right);
wire signed [24:0] source_l=shaped_left*$signed({1'b0,source_gain});
wire signed [24:0] source_r=shaped_right*$signed({1'b0,source_gain});
wire signed [15:0] source_left=source_gain==255 ? shaped_left:source_l[23:8];
wire signed [15:0] source_right=source_gain==255 ? shaped_right:source_r[23:8];
wire signed [24:0] frame_l=source_left*$signed({1'b0,smooth_gain});
wire signed [24:0] frame_r=source_right*$signed({1'b0,smooth_gain});
wire signed [15:0] scaled_left=smooth_gain==255 ? source_left:frame_l[23:8];
wire signed [15:0] scaled_right=smooth_gain==255 ? source_right:frame_r[23:8];
assign sample_tick=(sample_count==255);
assign pcm_ready=sample_tick && !audio_rst;
always @(posedge audio_clk or posedge audio_rst)begin
 if(audio_rst)begin
  sample_count<=0;bit_count<=0;shift_reg<=0;next_left<=0;next_right<=0;right_word<=0;
  i2s_bclk<=0;i2s_lrck<=0;i2s_dout<=0;smooth_gain<=255;
  last_left<=0;last_right<=0;tail_count<=0;attack_count<=0;
 end else begin
  sample_count<=sample_count+1'b1;
  if(sample_tick)begin
   if(smooth_gain<frame_gain)smooth_gain<=smooth_gain+1'b1;
   else if(smooth_gain>frame_gain)smooth_gain<=smooth_gain-1'b1;
   // 下溢在流接口输出零；桥接处用 32 个样本释放到零，恢复时同样短淡入。
   if(silent)begin attack_count<=0;if(tail_count!=0)tail_count<=tail_count-1'b1;end
   else begin last_left<=pcm_left;last_right<=pcm_right;tail_count<=envelope;if(attack_count<32)attack_count<=attack_count+1'b1;end
   next_left<={scaled_left,8'd0};next_right<={scaled_right,8'd0};
  end
  i2s_bclk<=~i2s_bclk;
  if(i2s_bclk)begin
   i2s_dout<=shift_reg[63];shift_reg<={shift_reg[62:0],1'b0};
   if(bit_count==63)begin
    bit_count<=0;
    if(!i2s_lrck)begin i2s_lrck<=1;shift_reg<={right_word,40'd0};end
    else begin i2s_lrck<=0;shift_reg<={next_left,40'd0};right_word<=next_right;end
   end else bit_count<=bit_count+1'b1;
  end
 end
end
I2S_receiver u_I2S_receiver(.I_clk(pixel_clk),.I_rst(pixel_rst),
 .I_i2s_BCLK(i2s_bclk),.I_i2s_LRCK(i2s_lrck),.I_i2s_DOUT(i2s_dout),
 .O_audio_valid(audio_valid),.O_audio_left_data(audio_left_data),.O_audio_right_data(audio_right_data));
audio_arc_calculate #(.ACR_N(6144)) u_audio_arc_calculate(
 .I_clk(pixel_clk),.I_rst(pixel_rst),.I_audio_valid(audio_valid),
 .O_acr_valid(acr_valid),.O_acr_cts(acr_cts),.O_acr_n(acr_n));
endmodule
