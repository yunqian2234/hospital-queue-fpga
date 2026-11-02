`timescale 1ns/1ps
// Same-key local/remote collision: execute the local action, explicitly refuse remote.
// Other simultaneous keys retain the core's deterministic capacity/semantic rules.
module hospital_staff_arbiter(
 input wire clk,rst,input wire [7:0] local_keys,remote_keys,
 output wire [7:0] core_keys,
 input wire [7:0] core_accepted,core_invalid,core_duplicate,core_full,core_conflict,
 output wire [7:0] remote_accepted,remote_invalid,remote_duplicate,remote_full,remote_conflict
);
 reg [7:0] owner,collision;
 assign core_keys=local_keys | remote_keys;
 always @(posedge clk or posedge rst)
  if(rst) begin owner<=0;collision<=0;end
  else begin owner<=remote_keys & ~local_keys;collision<=remote_keys & local_keys;end
 assign remote_accepted=core_accepted & owner;
 assign remote_invalid=core_invalid & owner;
 assign remote_duplicate=core_duplicate & owner;
 assign remote_full=core_full & owner;
 assign remote_conflict=(core_conflict & owner) | collision;
endmodule

// Volume-mode helpers share this already registered production source.
`timescale 1ns/1ps
// Consumes board-key events from hospital_key_frontend. No second debouncer.
// Bits 0/1/2 = board KEY4 decrease / KEY3 target / KEY2 increase.
// J1 hospital keys never pass through this controller.
// SW1 uses a synchronized, 20ms stable level. Held keys cannot cross modes.
module hospital_volume_control #(parameter integer STABLE_CYCLES=500000)(
 input wire clk,rst,mode_sw,input wire [7:0] press,pressed,
 output wire [7:0] business_press,output wire [2:0] business_blocked,
 output reg mode,output reg target_voice,
 output reg [3:0] music_level,voice_level
);
 localparam CW=STABLE_CYCLES<2 ? 1:$clog2(STABLE_CYCLES+1);
 reg sync0,sync1;
 reg [CW-1:0] count;
 reg [2:0] blocked;
 wire changing=(sync1!=mode);
 wire commit=changing && count==STABLE_CYCLES-1;
 wire [2:0] action=press[2:0] & ~blocked;
 assign business_press={press[7:3],(mode || changing ? 3'b000:action)};
 // Release consumers must cancel their gesture, rather than synthesize a
 // release by forcing the raw pin high when SW1 changes.
 assign business_blocked=blocked | {3{mode || changing}};
 always @(posedge clk or posedge rst)begin
  if(rst)begin
   sync0<=0;sync1<=0;count<=0;blocked<=7;
   mode<=0;target_voice<=0;music_level<=2;voice_level<=10;
  end else begin
   sync0<=mode_sw;sync1<=sync0;
   blocked<=blocked & pressed[2:0];
   if(!changing)count<=0;
   else if(commit)begin mode<=sync1;count<=0;blocked<=pressed[2:0] | press[2:0];end
   else count<=count+1'b1;
   // A key at a mode edge is consumed, never sent as a hospital command.
   if(mode && !changing)begin
    if(action[1])target_voice<=~target_voice;
    // Simultaneous down+up is a defined no-op; selection takes effect next press.
    if(action[0] ^ action[2])begin
     if(target_voice)begin
      if(action[0] && voice_level!=0)voice_level<=voice_level-1'b1;
      if(action[2] && voice_level<10)voice_level<=voice_level+1'b1;
     end else begin
      if(action[0] && music_level!=0)music_level<=music_level-1'b1;
      if(action[2] && music_level<10)music_level<=music_level+1'b1;
     end
    end
   end
  end
 end
endmodule

// Audio-domain gain: atomic CDC supplies both levels, then a short sample-rate
// ramp removes abrupt volume steps. 100% is bit-exact; 0% is exact silence.
// Music is relative to raw PCM; voice is relative to the existing +25% boost.
module hospital_user_volume(
 input wire clk,rst,sample_tick,voice_selected,
 input wire [3:0] music_level,voice_level,
 input wire signed [15:0] in_left,in_right,
 output wire signed [15:0] out_left,out_right
);
 function [8:0] gain;
  input [3:0] level;
  begin case(level)
   0:gain=0;1:gain=26;2:gain=51;3:gain=77;4:gain=102;
   5:gain=128;6:gain=154;7:gain=179;8:gain=205;9:gain=230;
   default:gain=256;
  endcase end
 endfunction
 reg [8:0] music_gain,voice_gain;
 wire [8:0] music_wanted=gain(music_level),voice_wanted=gain(voice_level);
 wire [8:0] selected_gain=voice_selected ? voice_gain:music_gain;
 wire signed [25:0] left_product=in_left*$signed({1'b0,selected_gain});
 wire signed [25:0] right_product=in_right*$signed({1'b0,selected_gain});
 assign out_left=left_product[23:8];
 assign out_right=right_product[23:8];
 always @(posedge clk or posedge rst)begin
  if(rst)begin music_gain<=51;voice_gain<=256;end
  else if(sample_tick)begin
   if(music_gain<music_wanted)music_gain<=music_gain+1'b1;
   else if(music_gain>music_wanted)music_gain<=music_gain-1'b1;
   if(voice_gain<voice_wanted)voice_gain<=voice_gain+1'b1;
   else if(voice_gain>voice_wanted)voice_gain<=voice_gain-1'b1;
  end
 end
endmodule
