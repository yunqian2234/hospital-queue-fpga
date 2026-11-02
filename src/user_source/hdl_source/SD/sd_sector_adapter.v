// 第6课：完整接收一个物理扇区后再交付。ready 可暂停回放，不能暂停 SD SPI。
// 短读/超长读不交付数据；超时触发局部 SD 复位，清除迟到的旧事务。
module sd_sector_adapter #(
    parameter integer CLK_FREQ_HZ=100_000_000,
    parameter integer TIMEOUT_MS=1000
)(
    input clk, rst, media_ready,
    input request, input [31:0] request_lba, output request_ready,
    output reg valid, output reg [7:0] data, output [8:0] byte_index,
    input consume, output reg done, output reg error, output reg reset_req,
    output reg sd_read, output reg [31:0] sd_addr,
    input [7:0] sd_data, input sd_valid, sd_end
);
localparam IDLE=0, CAPTURE=1, FETCH=2, REPLAY=3, FINISH=4, RECOVER=5, ADVANCE=6;
localparam [63:0] LIMIT=(64'd1*CLK_FREQ_HZ/1000)*TIMEOUT_MS;
reg [2:0] state;
reg [7:0] buffer [0:511];
reg [9:0] count;
reg [8:0] cursor;
reg [31:0] timer;
wire [10:0] received={1'b0,count}+(sd_valid ? 11'd1:11'd0);
assign request_ready=(state==IDLE) && media_ready;
assign byte_index=cursor;
// 同步读写，适配片上块 RAM；不复位缓存内容，valid/count 决定有效范围。
always @(posedge clk) begin
    if(state==CAPTURE && sd_valid && count<512) buffer[count[8:0]]<=sd_data;
    if(state==FETCH) data<=buffer[cursor];
end
always @(posedge clk or posedge rst) begin
    if(rst) begin
        state<=IDLE; count<=0; cursor<=0; timer<=0; valid<=0;
        done<=0; error<=0; reset_req<=0; sd_read<=0; sd_addr<=0;
    end else begin
        done<=0; error<=0; reset_req<=0; sd_read<=0;
        if(!media_ready) begin state<=IDLE; valid<=0; timer<=0; end
        else case(state)
            IDLE: begin
                valid<=0; timer<=0; count<=0; cursor<=0;
                if(request) begin sd_addr<=request_lba; sd_read<=1; state<=CAPTURE; end
            end
            CAPTURE: begin
                if(sd_valid || sd_end) timer<=0; else timer<=timer+1'b1;
                if(sd_valid && count!=1023) count<=count+1'b1;
                if(sd_end) begin
                    if(received==512) state<=FETCH;
                    else begin done<=1; error<=1; state<=IDLE; end
                end else if({32'd0,timer}>=LIMIT) begin
                    done<=1; error<=1; reset_req<=1; state<=RECOVER;
                end
            end
            FETCH: begin valid<=1; state<=REPLAY; end
            // 10/05 时序：consume 来自多个读者的组合选择，路径较深；REPLAY 只据此清 valid、
            // 切到 ADVANCE，游标比较与递增放到下一拍，不再挂在 consume 路径上。每字节多 1 拍，
            // 回放仍远快于 SD 接收。
            REPLAY: if(consume) begin valid<=0; state<=ADVANCE; end
            ADVANCE: begin
                if(cursor==511) state<=FINISH;
                else begin cursor<=cursor+1'b1; state<=FETCH; end
            end
            FINISH: begin done<=1; state<=IDLE; end
            RECOVER: begin valid<=0; end // 等待驱动真正进入复位，禁止接受下一事务。
            default: state<=IDLE;
        endcase
    end
end
endmodule
