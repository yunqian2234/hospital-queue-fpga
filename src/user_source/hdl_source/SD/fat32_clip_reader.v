// 阶段C：VOICE.PCM 片段读取器（SD 100MHz 域）。
// 每次 start：查片段目录 -> 校验 -> 沿 FAT 链跳到片段起始扇区 -> 按样本数输出 s16le 字节，
// 尾部填充不输出。为了让句中片段衔接不断音，带两个小缓存（介质复位即清空）：
//   * 目录缓存：首次读头扇区时把 32 个 (起始扇区,样本数) 存入 RAM，此后不再读头扇区；
//   * FAT 缓存：保存最近读过的一个 FAT 扇区的 128 个表项，同扇区跳簇不再读卡。
// 头扇区/FAT 扇区 consume 恒为1；数据扇区只有下游有整扇区空间(data_sector_ready)时才申请。
// 所有比较先寄存为一位标志，再驱动状态/地址写使能，保持 100MHz 余量。
module fat32_clip_reader(
    input clk, rst, start,
    input [4:0] clip_id,
    input bank_valid,
    input [31:0] bank_cluster, bank_size, fat_lba, data_lba, max_cluster,
    input [7:0] sectors_per_cluster, input [3:0] cluster_shift,
    output busy, output reg done, output reg failed, output reg [3:0] error_code,
    output reg request, output reg [31:0] request_lba, input grant,
    input sector_valid, input [7:0] sector_data, input [8:0] sector_index,
    input sector_done, sector_error, output sector_consume,
    input data_sector_ready,
    output byte_valid, output [7:0] byte_data, input byte_ready
);
// 错误码：1 头部非法，2 空槽，3 片段越界，4 FAT 链断，5 SD 读错误，6 无语音库
localparam [3:0] E_NONE=0, E_HEADER=1, E_EMPTY=2, E_RANGE=3, E_CHAIN=4, E_READ=5, E_NO_BANK=6;
localparam [4:0] IDLE=0, START_CHECK=1, ADDR=2, ADDR_SHIFT=3, ADDR_BASE=4, ADDR_SECTOR=5,
    SEC_REQ=6, HDR_WAIT=7, HDR_LOOKUP=8, HDR_EVAL=9, HDR_RANGE=10, HDR_CHECK=11, SEEK=12,
    DATA_WAIT=13, DATA_CHECK=14, FAT_ADDR=15, FAT_TAG=16, FAT_REQ=17, FAT_WAIT=18,
    FAT_EVAL=19, FAT_CHECK=20, HDR_READ=21, FAT_HIT=22;
reg [4:0] state;
reg phase_data, start_bad;
reg [4:0] slot;
reg [31:0] cluster, next_cluster, size;
reg [7:0] sector_in_cluster;
reg [32:0] cluster_offset, translated, end_bytes;
reg [31:0] entry_start, entry_samples;
reg [22:0] hops, hops_pre;
reg [7:0] sic_pre;
reg [21:0] remaining;
reg has_bytes, f_empty, f_long, f_start_bad, f_range, fat_bad;
// 目录缓存
reg [63:0] dir_ram [0:31];
reg [63:0] dir_q, dir_word;
reg dir_cached, dir_ok, hdr_ok;
// FAT 缓存
reg [27:0] fat_ram [0:127];
reg [27:0] fat_q;
reg [31:0] fat_tag, fat_want;
reg fat_tag_valid, fat_hit;
// 10/05 时序：FAT 表项字节匹配寄存一拍。sector_index 在 FETCH 拍就已更新、到 REPLAY
// (valid=1) 前保持不变（sd_sector_adapter 的 ADVANCE/FETCH/REPLAY），故寄存后的比较结果
// 在 sector_valid 为 1 时总是对应当前字节。
reg fat_idx_match;
reg [23:0] fat_word;
wire [8:0] fat_offset={cluster[6:0],2'b00};
assign busy=(state!=IDLE);
assign byte_valid=(state==DATA_WAIT) && sector_valid && has_bytes;
assign byte_data=sector_data;
assign sector_consume=(state!=DATA_WAIT || !has_bytes) ? 1'b1:byte_ready;
wire dir_byte=(state==HDR_WAIT) && sector_valid && sector_index>=9'd16 && sector_index<9'd272;
wire fat_byte=(state==FAT_WAIT) && sector_valid;
always @(posedge clk) begin
    if(dir_byte && sector_index[2:0]==3'd7) dir_ram[sector_index[7:3]-5'd2]<={sector_data,dir_word[63:8]};
    if(fat_byte && sector_index[1:0]==2'd3) fat_ram[sector_index[8:2]]<={sector_data[3:0],fat_word};
    dir_q<=dir_ram[slot];
    fat_q<=fat_ram[cluster[6:0]];
end
task fail;
    input [3:0] code;
    begin failed<=1; error_code<=code; request<=0; has_bytes<=0; state<=IDLE; end
endtask
always @(posedge clk or posedge rst) begin
    if(rst) begin
        state<=IDLE; done<=0; failed<=0; error_code<=E_NONE; request<=0; request_lba<=0;
        phase_data<=0; start_bad<=0; slot<=0; cluster<=0; next_cluster<=0; size<=0;
        sector_in_cluster<=0; cluster_offset<=0; translated<=0; end_bytes<=0;
        entry_start<=0; entry_samples<=0; hops<=0; hops_pre<=0; sic_pre<=0; remaining<=0;
        has_bytes<=0; f_empty<=0; f_long<=0; f_start_bad<=0; f_range<=0; fat_bad<=0;
        dir_word<=0; dir_cached<=0; dir_ok<=0; hdr_ok<=0;
        fat_tag<=0; fat_want<=0; fat_tag_valid<=0; fat_hit<=0; fat_word<=0; fat_idx_match<=0;
    end else begin
        done<=0; failed<=0;
        fat_idx_match<=sector_index[8:2]==fat_offset[8:2];
        if(dir_byte) dir_word<={sector_data,dir_word[63:8]};
        if(fat_byte) fat_word<={sector_data,fat_word[23:8]};
        case(state)
            IDLE: if(start) begin
                error_code<=E_NONE; phase_data<=0; has_bytes<=0; hops<=0;
                slot<=clip_id; cluster<=bank_cluster; size<=bank_size; sector_in_cluster<=0;
                // Range check registered here (10/05 timing fix): the 32-bit compare against
                // max_cluster no longer sits in the same cycle as the request/state update.
                start_bad<=!bank_valid || bank_cluster<2 || bank_cluster>max_cluster;
                state<=START_CHECK;
            end
            START_CHECK: begin
                if(start_bad) fail(E_NO_BANK);
                else if(dir_cached) state<=HDR_READ;
                else begin hdr_ok<=0; state<=ADDR; end
            end
            ADDR: begin cluster_offset<={1'b0,cluster}-33'd2; state<=ADDR_SHIFT; end
            ADDR_SHIFT: begin cluster_offset<=cluster_offset<<cluster_shift[2:0]; state<=ADDR_BASE; end
            ADDR_BASE: begin translated<={1'b0,data_lba}+cluster_offset; state<=ADDR_SECTOR; end
            ADDR_SECTOR: begin translated<=translated+sector_in_cluster; state<=SEC_REQ; end
            SEC_REQ: begin
                request_lba<=translated[31:0];
                if(translated[32]) fail(E_RANGE);
                else if(grant) begin request<=0; state<=phase_data ? DATA_WAIT:HDR_WAIT; end
                else request<=!phase_data || data_sector_ready;
            end
            HDR_WAIT: begin
                if(sector_valid && sector_index[8:3]==6'd0) begin
                    case(sector_index[2:0])
                        0:hdr_ok<=sector_data=="H";
                        1:if(sector_data!="V") hdr_ok<=0;
                        2:if(sector_data!="B") hdr_ok<=0;
                        3:if(sector_data!="1") hdr_ok<=0;
                        4:if(sector_data!=8'd32) hdr_ok<=0;
                        5:if(sector_data!=8'd0) hdr_ok<=0;
                        6:if(sector_data!=8'd48) hdr_ok<=0;
                        7:if(sector_data!=8'd0) hdr_ok<=0;
                    endcase
                end
                if(sector_done) begin
                    if(sector_error) fail(E_READ);
                    else begin dir_cached<=1; dir_ok<=hdr_ok; state<=HDR_READ; end
                end
            end
            HDR_READ: state<=HDR_LOOKUP;   // dir_q 同步读出
            HDR_LOOKUP: begin
                entry_start<=dir_q[31:0]; entry_samples<=dir_q[63:32];
                if(!dir_ok) fail(E_HEADER); else state<=HDR_EVAL;
            end
            HDR_EVAL: begin
                f_empty<=entry_samples==0;
                f_long<=entry_samples[31:20]!=0;
                f_start_bad<=entry_start==0 || entry_start[31:23]!=0;
                end_bytes<={1'b0,entry_start[22:0],9'd0}+{1'b0,entry_samples[30:0],1'b0};
                state<=HDR_RANGE;
            end
            // 10/05 时序：移位与掩码在 HDR_RANGE 预先算好（entry_start 已稳定），HDR_CHECK
            // 只做选择，不再把桶形移位器串在 cluster_shift 到 hops 的路径上。
            HDR_RANGE: begin
                f_range<=end_bytes<={1'b0,size};
                hops_pre<=entry_start[22:0]>>cluster_shift[2:0];
                sic_pre<=entry_start[7:0] & (sectors_per_cluster-8'd1);
                state<=HDR_CHECK;
            end
            HDR_CHECK: begin
                if(f_empty) fail(E_EMPTY);
                else if(f_long || f_start_bad || !f_range) fail(E_RANGE);
                else begin
                    hops<=hops_pre;
                    sector_in_cluster<=sic_pre;
                    remaining<={entry_samples[20:0],1'b0};
                    has_bytes<=1; phase_data<=1; state<=SEEK;
                end
            end
            SEEK: state<=(hops==0) ? ADDR:FAT_ADDR;
            DATA_WAIT: begin
                if(byte_valid && byte_ready) begin
                    remaining<=remaining-1'b1;
                    if(remaining==22'd1) has_bytes<=0;
                end
                if(sector_done) begin if(sector_error) fail(E_READ); else state<=DATA_CHECK; end
            end
            DATA_CHECK: begin
                if(!has_bytes) begin done<=1; state<=IDLE; end
                else if(sector_in_cluster+9'd1>=sectors_per_cluster) state<=FAT_ADDR;
                else begin sector_in_cluster<=sector_in_cluster+1'b1; state<=ADDR; end
            end
            FAT_ADDR: begin fat_want<=fat_lba+(cluster>>7); state<=FAT_TAG; end
            FAT_TAG: begin
                fat_hit<=fat_tag_valid && fat_tag==fat_want;
                request_lba<=fat_want; next_cluster<=0; state<=FAT_HIT;
            end
            // fat_q 已在上一拍按 cluster[6:0] 读出；命中则直接用缓存表项。
            FAT_HIT: if(fat_hit) begin next_cluster<={4'd0,fat_q}; state<=FAT_EVAL; end
                     else begin fat_tag_valid<=0; state<=FAT_REQ; end
            FAT_REQ: begin request<=1; if(grant) begin request<=0; state<=FAT_WAIT; end end
            FAT_WAIT: begin
                if(sector_valid && fat_idx_match) begin
                    case(sector_index[1:0])
                        0:next_cluster[7:0]<=sector_data;
                        1:next_cluster[15:8]<=sector_data;
                        2:next_cluster[23:16]<=sector_data;
                        3:next_cluster[31:24]<={4'd0,sector_data[3:0]};
                    endcase
                end
                if(sector_done) begin
                    if(sector_error) fail(E_READ);
                    else begin fat_tag<=request_lba; fat_tag_valid<=1; state<=FAT_EVAL; end
                end
            end
            // 片段尚未读完时链尾(>=0x0ffffff8 必大于 max_cluster)同样视为断链。
            FAT_EVAL: begin
                fat_bad<=next_cluster<2 || next_cluster>max_cluster || next_cluster==cluster;
                state<=FAT_CHECK;
            end
            FAT_CHECK: begin
                if(fat_bad) fail(E_CHAIN);
                else begin
                    cluster<=next_cluster;
                    if(hops!=0) begin hops<=hops-1'b1; state<=SEEK; end
                    else begin sector_in_cluster<=0; state<=ADDR; end
                end
            end
            default: state<=IDLE;
        endcase
    end
end
endmodule
