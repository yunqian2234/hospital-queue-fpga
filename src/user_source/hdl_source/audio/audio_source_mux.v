`timescale 1ns/1ps
// 第11讲：选择仅在采样握手边界更新，ready 仅给选中源；切源先淡到零再淡入。
module audio_source_mux(
 input clk,rst_n,wav_valid,wav_active,wav_silence,
 input signed [15:0] wav_left,wav_right,output wav_ready,
 input arp_valid,input signed [15:0] arp_left,arp_right,output arp_ready,
 input test_valid,input signed [15:0] test_left,test_right,output test_ready,
 input force_arpeggio,force_test,
 output out_valid,input out_ready,output signed [15:0] out_left,out_right,
 output out_silence,output reg [7:0] source_gain,output reg [1:0] selected_source
);
localparam WAV=0,ARP=1,TEST=2;
wire [1:0] wanted=force_test ? TEST:force_arpeggio ? ARP:wav_active ? WAV:ARP;
assign out_valid=selected_source==WAV ? wav_valid:selected_source==TEST ? test_valid:arp_valid;
assign out_left=selected_source==WAV ? wav_left:selected_source==TEST ? test_left:arp_left;
assign out_right=selected_source==WAV ? wav_right:selected_source==TEST ? test_right:arp_right;
assign out_silence=selected_source==WAV && wav_silence;
assign wav_ready=rst_n && out_ready && selected_source==WAV;
assign arp_ready=rst_n && out_ready && selected_source==ARP;
assign test_ready=rst_n && out_ready && selected_source==TEST;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin selected_source<=ARP;source_gain<=0;end
 else if(out_ready)begin
  if(wanted!=selected_source)begin
   if(source_gain>4)source_gain<=source_gain-4;
   else begin source_gain<=0;selected_source<=wanted;end
  end else if(source_gain<251)source_gain<=source_gain+4;
  else source_gain<=255;
 end
end
endmodule
