`timescale 1ns/1ps
// 第5课：异步置位、三级同步释放；每个接收时钟域独立实例化。
// keep 采用 TD 自带 FIFO 同样的属性写法，防止同步链被折叠。
module reset_sync(input clk, input arst, output rst);
    reg stage0 = 1'b1; /* synthesis keep */
    reg stage1 = 1'b1; /* synthesis keep */
    reg stage2 = 1'b1; /* synthesis keep */
    always @(posedge clk or posedge arst) begin
        if (arst) begin stage0<=1'b1; stage1<=1'b1; stage2<=1'b1; end
        else begin stage0<=1'b0; stage1<=stage0; stage2<=stage1; end
    end
    assign rst=stage2;
endmodule

// 第5课：50MHz 常运行参考时钟监督上电和锁定；PLL 复位与业务复位分开。
// FPGA 配置初始化值保证未按复位键的冷启动也有 100us PLL 复位脉冲。
// 任一 PLL 失锁会立即复位业务，重新连续锁定 20ms 后才允许恢复。
// 失锁不反向复位 PLL，避免“等待锁定才能退出 PLL 复位”的死锁。
module clock_reset_ctrl #(
    parameter integer POR_CYCLES=5000,
    parameter integer LOCK_CYCLES=1000000
)(
    input ref_clk, input ext_rst_n, input [2:0] pll_locked,
    output pll_rst, output system_arst
);
    localparam PW=(POR_CYCLES<2)?1:$clog2(POR_CYCLES);
    localparam LW=(LOCK_CYCLES<2)?1:$clog2(LOCK_CYCLES);
    reg [PW-1:0] por_count=0;
    reg por_hold=1'b1;
    wire lock_wait_reset;
    reg [LW-1:0] lock_count=0;
    reg run_ready=1'b0;
    always @(posedge ref_clk or negedge ext_rst_n) begin
        if(!ext_rst_n) begin por_count<=0; por_hold<=1'b1; end
        else if(por_hold) begin
            if(por_count==POR_CYCLES-1) por_hold<=1'b0;
            else por_count<=por_count+1'b1;
        end
    end
    reset_sync u_ref_reset(.clk(ref_clk),.arst(por_hold | ~ext_rst_n),.rst(pll_rst));
    reset_sync u_lock_reset(.clk(ref_clk),.arst(pll_rst | ~(&pll_locked)),.rst(lock_wait_reset));
    always @(posedge ref_clk or posedge lock_wait_reset) begin
        if(lock_wait_reset) begin lock_count<=0; run_ready<=1'b0; end
        else if(!run_ready) begin
            if(lock_count==LOCK_CYCLES-1) run_ready<=1'b1;
            else lock_count<=lock_count+1'b1;
        end
    end
    assign system_arst=lock_wait_reset | ~run_ready;
endmodule
