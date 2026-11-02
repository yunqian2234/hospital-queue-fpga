`timescale 1ns/1ps
// 第5课：保持型单比特状态；不能用于脉冲或多位总线。
module cdc_level(input clk, input rst, input async_in, output level_out);
    reg stage0; /* synthesis keep */
    reg stage1; /* synthesis keep */
    always @(posedge clk or posedge rst) begin
        if(rst) begin stage0<=0; stage1<=0; end
        else begin stage0<=async_in; stage1<=stage0; end
    end
    assign level_out=stage1;
endmodule

// 第5课：完整状态字握手。源数据冻结到接收确认，接收端等待三级请求同步。
// 用于图片编号/诊断状态，忙时合并到最新值，不作为逐条事件队列。
// 两端必须共同复位（允许各域同步释放的延迟不同）。
// timing.sdc 对 hold_data->dst_data 加最大数据延时，不能只逐位打两拍。
module cdc_status #(parameter WIDTH=4)(
    input src_clk, input src_rst, input [WIDTH-1:0] src_data,
    input dst_clk, input dst_rst, output reg [WIDTH-1:0] dst_data
);
    reg [WIDTH-1:0] hold_data; /* synthesis keep */
    reg req_toggle, ack_toggle;
    reg ack0, ack1, ack2; /* synthesis keep */
    reg req0, req1, req2; /* synthesis keep */
    always @(posedge src_clk or posedge src_rst) begin
        if(src_rst) begin
            hold_data<=0; req_toggle<=0; ack0<=0; ack1<=0; ack2<=0;
        end else begin
            ack0<=ack_toggle; ack1<=ack0; ack2<=ack1;
            if(ack2==req_toggle && src_data!=hold_data) begin
                hold_data<=src_data;
                req_toggle<=~req_toggle;
            end
        end
    end
    always @(posedge dst_clk or posedge dst_rst) begin
        if(dst_rst) begin
            req0<=0; req1<=0; req2<=0; dst_data<=0; ack_toggle<=0;
        end else begin
            req0<=req_toggle; req1<=req0; req2<=req1;
            if(req2!=ack_toggle) begin dst_data<=hold_data; ack_toggle<=req2; end
        end
    end
endmodule
