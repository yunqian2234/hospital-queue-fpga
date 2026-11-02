// 第6课：目录长度限定输出；跨簇查 FAT。末簇也查链尾，防循环链伪装完整文件。
module fat32_file_streamer #(
    parameter [31:0] MAX_FILE_BYTES=32'd16_777_216
)(
    input clk, rst, start, abort,
    input [31:0] first_cluster, file_size, fat_lba, data_lba, max_cluster,
    input [7:0] sectors_per_cluster, input [3:0] cluster_shift,
    output busy, output reg done, output reg failed,
    output reg request, output reg [31:0] request_lba, input grant,
    input sector_valid, input [7:0] sector_data, input [8:0] sector_index,
    input sector_done, sector_error, output sector_consume,
    output file_valid, output [7:0] file_data, input file_ready
);
localparam IDLE=0, ADDR=1, DATA_REQ=2, DATA_WAIT=3, DATA_CHECK=4,
           FAT_ADDR=5, FAT_REQ=6, FAT_WAIT=7, FAT_CHECK=8, DRAIN=9,
           ADDR_SHIFT=10, ADDR_BASE=11, ADDR_SECTOR=12, CHECK_START=13, FAT_EVAL=14, CHECK_START_RESULT=15;
reg [3:0] state;
reg [31:0] cluster, remaining, next_cluster;
reg [7:0] sector_in_cluster;
reg [32:0] translated;
reg [32:0] cluster_offset;
reg has_bytes;
// FAT 链比较结果先寄存一拍，再驱动 cluster/sector_in_cluster 写使能（100MHz 余量）。
reg fat_eoc, fat_bad;
reg start_bad;
// FAT 表项字节先寄存一拍再写 next_cluster：扇区游标比较 + 通道归属门控直接驱动
// 32 位 CE 时，100MHz 下以布线为主的路径余量为负（-0.099ns）。适配器最后一个字节
// 之后至少隔一拍才给 sector_done，所以寄存后的写入在 FAT_EVAL 之前完成。
reg fat_hit_q;
reg [1:0] fat_lane_q;
reg [7:0] fat_data_q;
wire [8:0] fat_offset={cluster[6:0],2'b00};
assign busy=(state!=IDLE);
// 第6课时序：字节有效信号使用同步维护的一位标志，不串联32位归零判断到 BMP 头寄存器。
assign file_valid=(state==DATA_WAIT) && sector_valid && has_bytes && !abort;
assign file_data=sector_data;
assign sector_consume=(state!=DATA_WAIT || !has_bytes || abort) ? 1'b1:file_ready;
task fail;
    begin failed<=1; done<=1; request<=0; state<=IDLE; end
endtask
always @(posedge clk or posedge rst) begin
    if(rst) begin
        state<=IDLE; request<=0; request_lba<=0; done<=0; failed<=0;
        cluster<=0; remaining<=0; next_cluster<=0; sector_in_cluster<=0; translated<=0;
        cluster_offset<=0;
        has_bytes<=0; fat_eoc<=0; fat_bad<=0; start_bad<=0;
        fat_hit_q<=0; fat_lane_q<=0; fat_data_q<=0;
    end else begin
        fat_hit_q<=(state==FAT_WAIT) && sector_valid && sector_index[8:2]==fat_offset[8:2];
        fat_lane_q<=sector_index[1:0]; fat_data_q<=sector_data;
        done<=0; failed<=0;
        if(abort && state!=IDLE && state!=DRAIN) begin
            request<=0;
            // 已获授权的整扇区必须收尾，才可交还通道；未授权请求直接取消。
            if((state==DATA_WAIT || state==FAT_WAIT || grant) && !sector_done) state<=DRAIN;
            else state<=IDLE;
        end else case(state)
            IDLE: if(start) begin
                remaining<=file_size; cluster<=first_cluster; sector_in_cluster<=0;
                has_bytes<=(file_size!=0);
                // 四个文件槽位的选择与合法性比较分拍；本次元数据先锁存。
                state<=CHECK_START;
            end
            CHECK_START: begin
                // Metadata is already frozen. Register the wide range result
                // before it fans out to state/request/done/failed controls.
                start_bad<=!has_bytes || remaining>MAX_FILE_BYTES || cluster<2 || cluster>max_cluster;
                state<=CHECK_START_RESULT;
            end
            CHECK_START_RESULT: begin
                if(start_bad) fail;
                else state<=ADDR;
            end
            ADDR: begin
                // 第6课：减法、可变移位和两次加法分拍，保证实际 SD 100MHz 时序。
                cluster_offset<={1'b0,cluster}-33'd2; state<=ADDR_SHIFT;
            end
            ADDR_SHIFT: begin cluster_offset<=cluster_offset<<cluster_shift[2:0]; state<=ADDR_BASE; end
            ADDR_BASE: begin translated<={1'b0,data_lba}+cluster_offset; state<=ADDR_SECTOR; end
            ADDR_SECTOR: begin translated<=translated+sector_in_cluster; state<=DATA_REQ; end
            DATA_REQ: begin
                request_lba<=translated[31:0]; request<=1;
                if(translated[32]) fail;
                else if(grant) begin request<=0; state<=DATA_WAIT; end
            end
            DATA_WAIT: begin
                if(file_valid && file_ready) begin
                    remaining<=remaining-1'b1;
                    if(remaining==1) has_bytes<=0;
                end
                if(sector_done) begin
                    if(sector_error) fail; else state<=DATA_CHECK;
                end
            end
            DATA_CHECK: begin
                // 第11讲：has_bytes 与 remaining 同步维护，使用一位标志避免
                // 32 位归零判断串联 FAT 链校验/簇地址写使能，保持 100MHz 余量。
                if(!has_bytes || sector_in_cluster+9'd1>=sectors_per_cluster) state<=FAT_ADDR;
                else begin sector_in_cluster<=sector_in_cluster+1'b1; state<=ADDR; end
            end
            FAT_ADDR: begin
                request_lba<=fat_lba+(cluster>>7); next_cluster<=0; state<=FAT_REQ;
            end
            FAT_REQ: begin request<=1; if(grant) begin request<=0; state<=FAT_WAIT; end end
            FAT_WAIT: begin
                if(fat_hit_q) begin
                    case(fat_lane_q)
                        0:next_cluster[7:0]<=fat_data_q;
                        1:next_cluster[15:8]<=fat_data_q;
                        2:next_cluster[23:16]<=fat_data_q;
                        3:next_cluster[31:24]<={4'd0,fat_data_q[3:0]};
                    endcase
                end
                if(sector_done) begin if(sector_error) fail; else state<=FAT_EVAL; end
            end
            FAT_EVAL: begin
                fat_eoc<=next_cluster>=32'h0ffffff8;
                fat_bad<=next_cluster<2 || next_cluster>max_cluster || next_cluster==cluster;
                state<=FAT_CHECK;
            end
            FAT_CHECK: begin
                if(!has_bytes) begin
                    if(fat_eoc) begin done<=1; state<=IDLE; end
                    else fail;
                end else if(fat_bad) fail;
                else begin cluster<=next_cluster; sector_in_cluster<=0; state<=ADDR; end
            end
            DRAIN: if(sector_done) state<=IDLE;
            default: state<=IDLE;
        endcase
    end
end
endmodule
