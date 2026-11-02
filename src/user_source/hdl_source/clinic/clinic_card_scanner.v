// 10/23 诊室板：由 SD/fat32_volume_scanner.v 生成（delivery/clinic_cards_20261023/tools/make_card_scanner.py），
// 只把根目录文件名匹配改为 CARD1.BMP～CARD6.BMP（六个槽位）；挂载、校验、目录簇链与原模块相同。
// 原说明：只读 FAT32 挂载与根目录扫描。
// 支持 LBA0 VBR / 四个 MBR 主分区中的 FAT32；根目录遍历全部扇区和簇链。
// 不信任字符串 FAT32、固定根簇号或连续物理位置；所有地址先验证卷范围。
module clinic_card_scanner #(
    parameter [31:0] MAX_FILE_BYTES=32'd16_777_216,
    parameter integer MAX_DIR_CLUSTERS=4096, ENABLE_AUDIO=0,
    parameter [31:0] MAX_AUDIO_BYTES=32'd268435456,
    // 阶段C：根目录 VOICE.PCM 语音库（扇区0为片段目录），默认关闭，不改变原扫描行为。
    parameter integer ENABLE_VOICE=0,
    parameter [31:0] MAX_VOICE_BYTES=32'd268435456
)(
    input clk, rst, start,
    output reg mounted, scan_done, failed, found,
    output reg [3:0] error_code, output reg [5:0] valid_mask,
    output reg [191:0] file_clusters, file_sizes,
    output reg [31:0] fat_lba, data_lba, max_cluster,
    output reg [7:0] sectors_per_cluster, output reg [3:0] cluster_shift,
    output reg request, output reg [31:0] request_lba, input grant,
    input sector_valid, input [7:0] sector_data, input [8:0] sector_index,
    input sector_done, sector_error,
    // 第11讲：根目录短文件名 AUDIO.PCM，保留原 PIC1..4.BMP 槽位。
    output reg audio_found,audio_invalid,
    output reg [31:0] audio_cluster,audio_size,
    output reg voice_found,voice_invalid,
    output reg [31:0] voice_cluster,voice_size
);
// The sector arbiter/adapter owns the raw byte bus. Register the whole
// observation, including its terminal flags, before the scanner fans it out
// to BPB, MBR and directory fields. Nothing is dropped or consumed twice.
reg sector_valid_q,sector_done_q,sector_error_q;
reg [7:0] sector_data_q;
reg [8:0] sector_index_q;
always @(posedge clk or posedge rst)begin
 if(rst)begin sector_valid_q<=0;sector_done_q<=0;sector_error_q<=0;sector_data_q<=0;sector_index_q<=0;end
 else begin
  sector_valid_q<=sector_valid;sector_done_q<=sector_done;sector_error_q<=sector_error;
  sector_data_q<=sector_data;sector_index_q<=sector_index;
 end
end
localparam IDLE=0, BOOT_REQ=1, BOOT_WAIT=2, BOOT_CHECK=3, PART_SELECT=4,
    GEOMETRY1=5, GEOMETRY2=6, GEOMETRY3=7, GEOMETRY4=8,
    DIR_ADDR=9, DIR_REQ=10, DIR_WAIT=11, DIR_CHECK=12,
    FAT_REQ=13, FAT_WAIT=14, FAT_CHECK=15, FINISH=16, PART_SUM=17, PART_CHECK=18,
    DIR_SHIFT=19, DIR_BASE=20, DIR_SECTOR=21, GEOMETRY_VALIDATE=22, GEOMETRY_CHECK=23, FAT_EVAL=24,
    GEOMETRY_FAT=25, PART_READ=26, PART_BYTE=27;
reg [4:0] state;
reg partitioned;
reg [31:0] volume_lba, partition_size;
// One byte-wide synchronous BRAM holds the four MBR start/size pairs.
// All 32 bytes are overwritten by a successfully read MBR before selection.
(* ram_style="bram" *) reg [7:0] part_bytes[0:31];
reg [7:0] part_data_q;
reg [2:0] part_byte_index;
reg [1:0] part_index;
wire [2:0] part_byte_lane=sector_index_q[2:0]-3'd6;
always @(posedge clk)begin
 if(state==BOOT_WAIT && sector_valid_q && !partitioned && sector_index_q[8:6]==3'b111 &&
    sector_index_q[3:0]>=6 && sector_index_q[3:0]<=13)
  part_bytes[{sector_index_q[5:4],part_byte_lane}]<=sector_data_q;
 part_data_q<=part_bytes[{part_index,part_byte_index}];
end
reg [7:0] part_type[0:3];
reg [31:0] chosen_start, chosen_size;
reg [7:0] chosen_type;
reg [32:0] chosen_end;
reg chosen_ok;   // partition type/start/size checks, registered in PART_SUM (10/05 timing fix)
reg [15:0] reserved_sectors, ext_flags;
// These BPB fields are only compared against constants; accumulate the byte
// equalities rather than storing six full words and decoding them again.
reg bytes_per_sector_ok, root_entries_ok, total16_ok, fat16_ok, version_ok, signature_ok;
reg [7:0] bpb_spc, fat_count;
reg [31:0] total_sectors, fat_size, root_cluster;
reg [3:0] shift_value;
reg [33:0] overhead, data_start, active_fat_start;
reg [33:0] fat_base, active_fat_offset;
reg [32:0] volume_end;
reg [31:0] cluster_count;
reg [32:0] fat_entries_needed;
reg geometry_ok;
localparam DIR_HOP_WIDTH=MAX_DIR_CLUSTERS<2 ? 1:$clog2(MAX_DIR_CLUSTERS+1);
reg [31:0] dir_cluster, next_cluster;
reg [DIR_HOP_WIDTH-1:0] dir_hops;
reg [7:0] dir_sector;
reg [32:0] translated;
reg [32:0] cluster_offset;
reg dir_end, name_ok, attr_ok;
reg audio_name_ok,voice_name_ok;
reg [2:0] name_slot;
reg [31:0] entry_cluster, entry_size;
reg entry_pending, bpb_layout_ok, bpb_geometry_ok;
// 10/05 时序：目录项的范围比较先寄存（entry_check），下一拍再提交；比较结果对应的
// entry_cluster/entry_size 在两拍内不变（下一个目录项的字节至少 4 拍后才到）。
reg entry_check, cluster_ok, bmp_size_ok, audio_size_ok, voice_size_ok;
// 目录簇链比较结果先寄存（FAT_EVAL），FAT_CHECK 只用一位标志驱动 dir_hops 等写使能。
reg dir_eoc, dir_bad;
wire [8:0] fat_offset={dir_cluster[6:0],2'b00};
wire bpb_shape=bpb_layout_ok && bpb_geometry_ok;
integer n;
always @* begin
    case(bpb_spc)
        1:shift_value=0; 2:shift_value=1; 4:shift_value=2; 8:shift_value=3;
        16:shift_value=4; 32:shift_value=5; 64:shift_value=6; 128:shift_value=7;
        default:shift_value=15;
    endcase
end
task fail;
    input [3:0] code;
    begin failed<=1; error_code<=code; scan_done<=1; request<=0; state<=IDLE; end
endtask
always @(posedge clk or posedge rst) begin
    if(rst) begin
        state<=IDLE; request<=0; request_lba<=0; mounted<=0; scan_done<=0; failed<=0; found<=0;
        error_code<=0; valid_mask<=0; file_clusters<=0; file_sizes<=0;
        fat_lba<=0; data_lba<=0; max_cluster<=0; sectors_per_cluster<=0; cluster_shift<=0;
        partitioned<=0; volume_lba<=0; partition_size<=0; part_index<=0;
        chosen_start<=0; chosen_size<=0; chosen_type<=0; chosen_end<=0; chosen_ok<=0;
        part_byte_index<=0;
        for(n=0;n<4;n=n+1) part_type[n]<=0;
        reserved_sectors<=0; bytes_per_sector_ok<=0; root_entries_ok<=0; total16_ok<=0; fat16_ok<=0;
        ext_flags<=0; version_ok<=0; signature_ok<=0; bpb_spc<=0; fat_count<=0;
        total_sectors<=0; fat_size<=0; root_cluster<=0;
        overhead<=0; volume_end<=0; data_start<=0; active_fat_start<=0; cluster_count<=0;
        fat_base<=0; active_fat_offset<=0;
        fat_entries_needed<=0; geometry_ok<=0;
        dir_cluster<=0; next_cluster<=0; dir_hops<=0; dir_sector<=0; translated<=0;
        cluster_offset<=0;
        dir_end<=0; name_ok<=0; attr_ok<=0; name_slot<=0; entry_cluster<=0; entry_size<=0;
        entry_pending<=0; bpb_layout_ok<=0; bpb_geometry_ok<=0;
        entry_check<=0; cluster_ok<=0; bmp_size_ok<=0; audio_size_ok<=0; voice_size_ok<=0;
        dir_eoc<=0; dir_bad<=0;
        audio_name_ok<=0;audio_found<=0;audio_invalid<=0;audio_cluster<=0;audio_size<=0;
        voice_name_ok<=0;voice_found<=0;voice_invalid<=0;voice_cluster<=0;voice_size<=0;
    end else begin
        failed<=0; found<=0; entry_pending<=0; entry_check<=0;
        if(entry_check) begin
            entry_pending<=1;
            cluster_ok<=entry_cluster>=2 && entry_cluster<=max_cluster;
            bmp_size_ok<=entry_size>=54 && entry_size<=MAX_FILE_BYTES;
            audio_size_ok<=entry_size>=2 && entry_size<=MAX_AUDIO_BYTES && !entry_size[0];
            voice_size_ok<=entry_size>=1024 && entry_size<=MAX_VOICE_BYTES;
        end
        // 第6课时序：头字段先归纳成寄存的校验结果，再供状态机使用。
        // sector_done_q 在最后一次字节交付之后到达，BOOT_CHECK 使用已稳定的结果。
        bpb_layout_ok<=signature_ok && bytes_per_sector_ok && root_entries_ok &&
            total16_ok && fat16_ok && version_ok;
        bpb_geometry_ok<=reserved_sectors!=0 && (fat_count==1 || fat_count==2) &&
            fat_size!=0 && total_sectors!=0 && shift_value!=15 &&
            (!ext_flags[7] || ext_flags[3:0]<fat_count);
        // 目录项第32字节先锁存，下一拍检查；不把 BRAM 输出直接串到长度比较及目录写使能。
        if(entry_pending && name_ok && attr_ok && !valid_mask[name_slot] && cluster_ok && bmp_size_ok) begin
            file_clusters[name_slot*32 +: 32]<=entry_cluster;
            file_sizes[name_slot*32 +: 32]<=entry_size;
            valid_mask[name_slot]<=1; found<=1;
        end
        if(ENABLE_AUDIO && entry_pending && audio_name_ok && attr_ok && !audio_found) begin
            if(cluster_ok && audio_size_ok) begin
                audio_found<=1;audio_invalid<=0;audio_cluster<=entry_cluster;audio_size<=entry_size;
            end else audio_invalid<=1;
        end
        // 语音库至少包含头扇区和一个数据扇区；片段目录内容由 fat32_clip_reader 校验。
        if(ENABLE_VOICE && entry_pending && voice_name_ok && attr_ok && !voice_found) begin
            if(cluster_ok && voice_size_ok) begin
                voice_found<=1;voice_invalid<=0;voice_cluster<=entry_cluster;voice_size<=entry_size;
            end else voice_invalid<=1;
        end
        if(state==BOOT_WAIT && sector_valid_q) begin
            case(sector_index_q)
                11:bytes_per_sector_ok<=sector_data_q==0; 12:bytes_per_sector_ok<=bytes_per_sector_ok && sector_data_q==2;
                13:bpb_spc<=sector_data_q;
                14:reserved_sectors[7:0]<=sector_data_q; 15:reserved_sectors[15:8]<=sector_data_q;
                16:fat_count<=sector_data_q;
                17:root_entries_ok<=sector_data_q==0; 18:root_entries_ok<=root_entries_ok && sector_data_q==0;
                19:total16_ok<=sector_data_q==0; 20:total16_ok<=total16_ok && sector_data_q==0;
                22:fat16_ok<=sector_data_q==0; 23:fat16_ok<=fat16_ok && sector_data_q==0;
                32,33,34,35:total_sectors[{sector_index_q[1:0],3'b000} +: 8]<=sector_data_q;
                36,37,38,39:fat_size[{sector_index_q[1:0],3'b000} +: 8]<=sector_data_q;
                40:ext_flags[7:0]<=sector_data_q; 41:ext_flags[15:8]<=sector_data_q;
                42:version_ok<=sector_data_q==0; 43:version_ok<=version_ok && sector_data_q==0;
                44,45,46:root_cluster[{sector_index_q[1:0],3'b000} +: 8]<=sector_data_q;
                47:root_cluster[31:24]<={4'd0,sector_data_q[3:0]};
                510:signature_ok<=sector_data_q==8'h55; 511:signature_ok<=signature_ok && sector_data_q==8'haa;
            endcase
            if(!partitioned) begin
                for(n=0;n<4;n=n+1) begin
                    if(sector_index_q==450+n*16) part_type[n]<=sector_data_q;

                end
            end
        end
        if(state==DIR_WAIT && sector_valid_q && !dir_end) begin
            case(sector_index_q[4:0])
                0:audio_name_ok<=(sector_data_q=="A");
                1:if(sector_data_q!="U")audio_name_ok<=0;
                2:if(sector_data_q!="D")audio_name_ok<=0;
                3:if(sector_data_q!="I")audio_name_ok<=0;
                4:if(sector_data_q!="O")audio_name_ok<=0;
                5,6,7:if(sector_data_q!=" ")audio_name_ok<=0;
                8:if(sector_data_q!="P")audio_name_ok<=0;
                9:if(sector_data_q!="C")audio_name_ok<=0;
                10:if(sector_data_q!="M")audio_name_ok<=0;
            endcase
            case(sector_index_q[4:0])
                0:voice_name_ok<=(sector_data_q=="V");
                1:if(sector_data_q!="O")voice_name_ok<=0;
                2:if(sector_data_q!="I")voice_name_ok<=0;
                3:if(sector_data_q!="C")voice_name_ok<=0;
                4:if(sector_data_q!="E")voice_name_ok<=0;
                5,6,7:if(sector_data_q!=" ")voice_name_ok<=0;
                8:if(sector_data_q!="P")voice_name_ok<=0;
                9:if(sector_data_q!="C")voice_name_ok<=0;
                10:if(sector_data_q!="M")voice_name_ok<=0;
            endcase
            case(sector_index_q[4:0])
                0:begin
                    name_ok<=(sector_data_q=="C"); attr_ok<=0; entry_cluster<=0; entry_size<=0;
                    if(sector_data_q==0) dir_end<=1;
                end
                1:if(sector_data_q!="A") name_ok<=0;
                2:if(sector_data_q!="R") name_ok<=0;
                3:if(sector_data_q!="D") name_ok<=0;
                4:begin name_slot<=sector_data_q[2:0]-3'd1; if(sector_data_q<"1" || sector_data_q>"6") name_ok<=0; end
                5,6,7:if(sector_data_q!=" ") name_ok<=0;
                8:if(sector_data_q!="B") name_ok<=0;
                9:if(sector_data_q!="M") name_ok<=0;
                10:if(sector_data_q!="P") name_ok<=0;
                11:attr_ok<=((sector_data_q & 8'h18)==0); // 允许只读/隐藏/归档普通文件；排除目录、卷标和 LFN。
                20:entry_cluster[23:16]<=sector_data_q;
                21:entry_cluster[31:24]<={4'd0,sector_data_q[3:0]};
                26:entry_cluster[7:0]<=sector_data_q;
                27:entry_cluster[15:8]<=sector_data_q;
                28:entry_size[7:0]<=sector_data_q;
                29:entry_size[15:8]<=sector_data_q;
                30:entry_size[23:16]<=sector_data_q;
                31:begin entry_size[31:24]<=sector_data_q; entry_check<=1; end
            endcase
        end
        case(state)
            IDLE: if(start) begin
                mounted<=0; scan_done<=0; valid_mask<=0; error_code<=0;
                audio_found<=0;audio_invalid<=0;voice_found<=0;voice_invalid<=0;
                partitioned<=0; volume_lba<=0; partition_size<=0; request_lba<=0;
                dir_end<=0; dir_hops<=0; state<=BOOT_REQ;
            end
            BOOT_REQ: begin request<=1; if(grant) begin request<=0; state<=BOOT_WAIT; end end
            BOOT_WAIT: if(sector_done_q) begin if(sector_error_q) fail(4'd2); else state<=BOOT_CHECK; end
            BOOT_CHECK: begin
                if(bpb_shape) state<=GEOMETRY1;
                else if(!partitioned && signature_ok) begin part_index<=0; state<=PART_SELECT; end
                else fail(4'd7);
            end
            PART_SELECT: begin
                // 第6课时序：四选一、地址求和、边界检查分拍，避免 100MHz 长进位链。
                chosen_start<=0; chosen_size<=0;part_byte_index<=0;
                chosen_type<=part_type[part_index]; state<=PART_READ;
            end
            PART_READ: state<=PART_BYTE; // wait for synchronous MBR byte read
            PART_BYTE:begin
                case(part_byte_index)
                 0:chosen_start[7:0]<=part_data_q;
                 1:chosen_start[15:8]<=part_data_q;
                 2:chosen_start[23:16]<=part_data_q;
                 3:chosen_start[31:24]<=part_data_q;
                 4:chosen_size[7:0]<=part_data_q;
                 5:chosen_size[15:8]<=part_data_q;
                 6:chosen_size[23:16]<=part_data_q;
                 7:chosen_size[31:24]<=part_data_q;
                endcase
                if(part_byte_index==7)state<=PART_SUM;
                else begin part_byte_index<=part_byte_index+1'b1;state<=PART_READ;end
            end
            PART_SUM: begin
                chosen_end<={1'b0,chosen_start}+{1'b0,chosen_size};
                // The wide zero tests are registered here so that PART_CHECK, which loads the
                // volume registers, only sees a flag and the end-of-disk compare.
                chosen_ok<=(chosen_type==8'h0b || chosen_type==8'h0c) && chosen_start!=0 && chosen_size!=0;
                state<=PART_CHECK;
            end
            PART_CHECK: begin
                if(chosen_ok && chosen_end<=33'h100000000) begin
                    volume_lba<=chosen_start; partition_size<=chosen_size;
                    request_lba<=chosen_start; partitioned<=1; state<=BOOT_REQ;
                end else if(part_index==3) fail(4'd7);
                else begin part_index<=part_index+1'b1; state<=PART_SELECT; end
            end
            GEOMETRY1: begin
                overhead<={18'd0,reserved_sectors}+({2'b0,fat_size}<<(fat_count==2 ? 1:0));
                volume_end<={1'b0,volume_lba}+{1'b0,total_sectors};
                fat_base<={2'b0,volume_lba}+{18'd0,reserved_sectors};
                active_fat_offset<=(ext_flags[7] && ext_flags[3:0]==1) ? {2'b0,fat_size}:34'd0;
                sectors_per_cluster<=bpb_spc; cluster_shift<=shift_value; state<=GEOMETRY_FAT;
            end
            GEOMETRY_FAT: begin
                // Split selection and two additions across clocks. All 34 bits
                // survive until GEOMETRY_VALIDATE, including overflow checks.
                active_fat_start<=fat_base+active_fat_offset;
                state<=GEOMETRY2;
            end
            GEOMETRY2: begin
                data_start<={2'b0,volume_lba}+overhead;
                cluster_count<=({2'b0,total_sectors}-overhead)>>cluster_shift;
                state<=GEOMETRY3;
            end
            GEOMETRY3: begin
                max_cluster<=cluster_count+1'b1;
                fat_entries_needed<={1'b0,cluster_count}+33'd2;
                state<=GEOMETRY_VALIDATE;
            end
            GEOMETRY_VALIDATE: begin
                // 卷校验在数据通路启用之前完成；边界加法与比较分开，结果再寄存。
                geometry_ok<=overhead<total_sectors && volume_end<=33'h100000000 &&
                    data_start[33:32]==0 && active_fat_start[33:32]==0 &&
                    (!partitioned || total_sectors<=partition_size) && cluster_count>=65525 && cluster_count<=32'h0fffffee &&
                    ({8'd0,fat_size}<<7)>={7'd0,fat_entries_needed} && root_cluster>=2 && root_cluster<=max_cluster;
                state<=GEOMETRY_CHECK;
            end
            GEOMETRY_CHECK: begin
                if(!geometry_ok) fail(4'd7);
                else begin
                    fat_lba<=active_fat_start[31:0]; data_lba<=data_start[31:0];
                    dir_cluster<=root_cluster; dir_sector<=0; dir_hops<=1; state<=GEOMETRY4;
                end
            end
            GEOMETRY4: begin mounted<=1; state<=DIR_ADDR; end
            DIR_ADDR: begin
                cluster_offset<={1'b0,dir_cluster}-33'd2; state<=DIR_SHIFT;
            end
            DIR_SHIFT: begin cluster_offset<=cluster_offset<<cluster_shift[2:0]; state<=DIR_BASE; end
            DIR_BASE: begin translated<={1'b0,data_lba}+cluster_offset; state<=DIR_SECTOR; end
            DIR_SECTOR: begin translated<=translated+dir_sector; state<=DIR_REQ; end
            DIR_REQ: begin
                request_lba<=translated[31:0]; request<=1;
                if(translated>=volume_end || translated[32]) fail(4'd8);
                else if(grant) begin request<=0; state<=DIR_WAIT; end
            end
            DIR_WAIT: if(sector_done_q) begin if(sector_error_q) fail(4'd2); else state<=DIR_CHECK; end
            DIR_CHECK: begin
                // 图片齐全时仍要查找可能排在后续目录簇的音频文件。
                if(dir_end || (valid_mask==6'h3f && (!ENABLE_AUDIO || audio_found) &&
                               (!ENABLE_VOICE || voice_found))) state<=FINISH;
                else if(dir_sector+9'd1<sectors_per_cluster) begin dir_sector<=dir_sector+1'b1; state<=DIR_ADDR; end
                else begin request_lba<=fat_lba+(dir_cluster>>7); next_cluster<=0; state<=FAT_REQ; end
            end
            FAT_REQ: begin request<=1; if(grant) begin request<=0; state<=FAT_WAIT; end end
            FAT_WAIT: begin
                if(sector_valid_q && sector_index_q[8:2]==fat_offset[8:2]) begin
                    case(sector_index_q[1:0])
                        0:next_cluster[7:0]<=sector_data_q; 1:next_cluster[15:8]<=sector_data_q;
                        2:next_cluster[23:16]<=sector_data_q; 3:next_cluster[31:24]<={4'd0,sector_data_q[3:0]};
                    endcase
                end
                if(sector_done_q) begin if(sector_error_q) fail(4'd2); else state<=FAT_EVAL; end
            end
            FAT_EVAL: begin
                dir_eoc<=next_cluster>=32'h0ffffff8;
                dir_bad<=next_cluster<2 || next_cluster>max_cluster || next_cluster==dir_cluster || dir_hops>=MAX_DIR_CLUSTERS;
                state<=FAT_CHECK;
            end
            FAT_CHECK: begin
                if(dir_eoc) state<=FINISH;
                else if(dir_bad) fail(4'd8);
                else begin dir_cluster<=next_cluster; dir_hops<=dir_hops+1'b1; dir_sector<=0; state<=DIR_ADDR; end
            end
            FINISH: begin scan_done<=1; state<=IDLE; end
            default: state<=IDLE;
        endcase
    end
end
endmodule
