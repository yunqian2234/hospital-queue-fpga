`timescale 1ns/1ps
// 阶段C：语音句子播放器（SD 100MHz 域）。
// 接收 hospital_voice_dispatch 的命令（翻转握手，字段冻结），依次让 fat32_clip_reader
// 读出各片段，把字节拼成 s16 样本写入 voice_sample_fifo；句子结束（含失败）写句尾标记。
// 只有音频域真正取走句尾标记（即最后一个样本已交给 HDMI 音频桥）后，才回复结果。
// 必须用系统复位（rst_sd），不能挂在 SD 介质复位上，否则与调度器的翻转位失步；
// 介质复位发生在句中时按读失败结束本句。
module hospital_voice_player #(
    parameter integer PREFILL_SAMPLES=512,
    parameter integer FIFO_AW=11
)(
    input clk, rst,
    input cmd_toggle, input [15:0] cmd_seq, input [2:0] cmd_count, input [19:0] cmd_clips,
    output reg rsp_toggle, output reg [15:0] rsp_seq, output reg [2:0] rsp_status,
    output reg clip_start, output reg [4:0] clip_id,
    input clip_done, clip_failed, input [3:0] clip_error, input voice_reset,
    input clip_byte_valid, input [7:0] clip_byte, output clip_byte_ready, output clip_sector_ready,
    output reg fifo_wr_en, output reg [16:0] fifo_wr_data, input [FIFO_AW:0] fifo_free,
    output reg go_toggle,          // 本句已有足够预存样本（或已写完），音频域可开始播放
    input drained_toggle,          // 音频域已取走句尾标记
    output busy, output reg [3:0] last_clip_error
);
localparam [2:0] ST_OK=0, ST_NO_BANK=2, ST_READ_FAIL=3;
localparam [2:0] IDLE=0, NEXT=1, WAIT_CLIP=2, MARK=3, DRAIN=4, RESPOND=5;
reg [2:0] state;
reg c_s1, c_s2, c_seen, d_s1, d_s2, d_seen;
reg [15:0] seq; reg [2:0] count, index; reg [19:0] clips; reg [2:0] status;
reg lo_have; reg [7:0] lo_byte;
reg go_sent; reg [15:0] written;
wire cmd_edge=c_s2^c_seen, drained_edge=d_s2^d_seen;
// 留出写寄存/同步裕量：至少 4 个空位才接字节，至少一整扇区(256 样本)+8 才申请数据扇区。
assign clip_byte_ready=(state==WAIT_CLIP) && fifo_free>4;
assign clip_sector_ready=(state==WAIT_CLIP) && fifo_free>=256+8;
assign busy=(state!=IDLE);
always @(posedge clk or posedge rst) begin
    if(rst) begin
        state<=IDLE; c_s1<=0; c_s2<=0; c_seen<=0; d_s1<=0; d_s2<=0; d_seen<=0;
        rsp_toggle<=0; rsp_seq<=0; rsp_status<=ST_OK; clip_start<=0; clip_id<=0;
        seq<=0; count<=0; index<=0; clips<=0; status<=ST_OK; lo_have<=0; lo_byte<=0;
        fifo_wr_en<=0; fifo_wr_data<=0; go_toggle<=0; go_sent<=0; written<=0; last_clip_error<=0;
    end else begin
        c_s1<=cmd_toggle; c_s2<=c_s1; d_s1<=drained_toggle; d_s2<=d_s1;
        clip_start<=0; fifo_wr_en<=0;
        if(drained_edge) d_seen<=d_s2;
        if(fifo_wr_en && !go_sent && written>=PREFILL_SAMPLES) begin go_toggle<=~go_toggle; go_sent<=1; end
        case(state)
            IDLE: if(cmd_edge) begin
                c_seen<=c_s2;
                seq<=cmd_seq; count<=cmd_count; clips<=cmd_clips; index<=0;
                status<=ST_OK; go_sent<=0; written<=0; state<=NEXT;
            end
            NEXT: begin
                lo_have<=0;
                if(index==count || index==3'd4) state<=MARK;
                else if(voice_reset) begin status<=ST_READ_FAIL; state<=MARK; end
                else begin
                    clip_id<=clips[4:0]; clips<={5'd0,clips[19:5]};
                    clip_start<=1; index<=index+1'b1; state<=WAIT_CLIP;
                end
            end
            WAIT_CLIP: begin
                if(clip_byte_valid && clip_byte_ready) begin
                    if(!lo_have) begin lo_byte<=clip_byte; lo_have<=1; end
                    else begin
                        fifo_wr_en<=1; fifo_wr_data<={1'b0,clip_byte,lo_byte}; lo_have<=0;
                        written<=written+1'b1;
                    end
                end
                if(clip_done) state<=NEXT;
                else if(clip_failed) begin
                    last_clip_error<=clip_error;
                    status<=(clip_error==4'd6 || clip_error==4'd1) ? ST_NO_BANK:ST_READ_FAIL;
                    state<=MARK;
                end else if(voice_reset) begin status<=ST_READ_FAIL; state<=MARK; end
            end
            MARK: if(fifo_free>2 && !fifo_wr_en) begin
                fifo_wr_en<=1; fifo_wr_data<={1'b1,16'd0};
                if(!go_sent) begin go_toggle<=~go_toggle; go_sent<=1; end
                state<=DRAIN;
            end
            DRAIN: if(drained_edge) begin rsp_seq<=seq; rsp_status<=status; state<=RESPOND; end
            RESPOND: begin rsp_toggle<=~rsp_toggle; state<=IDLE; end
            default: state<=IDLE;
        endcase
    end
end
endmodule
