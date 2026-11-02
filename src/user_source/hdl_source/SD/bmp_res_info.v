`timescale 1ns/1ps
// 10/26 扩展要求3 演示：板子自己从 BMP 文件头读到的分辨率，显示在大厅屏底行（SW4 拨上）。
//
// SD 域：每张图加载成功（frame_commit）时锁存该图的原始宽高 src_w×src_h（bmp_stream_decode 解析
// 的文件头）和缩放后尺寸 fit_w×fit_h（bmp_scaler 算出），用 11 拍移位加三法（double dabble）转成
// 十进制，排好显示用的数字格，写进一块双时钟块 RAM 的第 index 项。
// 像素域：读端口地址 = 当前显示的图片号（顶层在帧起点锁存），读出的数字格直接作为
// hospital_screen 的数字字段（不需要再跨时钟域同步：一项只在该图加载成功时写一次，图片完整标志
// 经 cdc_status 到达像素域、该图才可能被显示时，这一项早已写好）。
// 数字格（每格 4 位，hospital_screen 字段 54..68）：
//   cells[35:0]  原图“宽×高”9 格，左对齐（10/27：后面不再接“→ 显示”，改回左对齐，紧跟“原图”）：
//                千位为 0 不占格，后面补空格。10 = 空格，12 = '×'。
//                例：1920×1080 -> 1 9 2 0 × 1 0 8 0；800×600 -> 8 0 0 × 6 0 0 空 空
//   cells[47:36] 显示宽度 3 位（百 十 个），cells[59:48] 显示高度 3 位。缩放后宽 284..640、
//                高 160..480，总是 3 位。
// 资源：大厅板 slice 紧张，所以表放在块 RAM（9K）里，像素域没有新增寄存器。
module bmp_res_info (
    input wire clk, rst,                       // SD 域（sd_card_clk）
    input wire commit,                         // sd_card_bmp.frame_commit：本次加载成功
    input wire [1:0] index,                    // 本次加载的图片号（PIC1..PIC4 = 0..3）
    input wire [10:0] src_w, src_h,            // 文件头宽高
    input wire [10:0] fit_w, fit_h,            // 缩放后尺寸
    input wire rd_clk,                         // 像素域
    input wire [1:0] rd_index,
    output wire [59:0] cells
);
    // ---------------- double dabble: four numbers in parallel, 11 shifts ----------------
    reg [10:0] bw, bh, bfw, bfh;               // binary, shifted out MSB first
    reg [15:0] dw, dh, dfw, dfh;               // BCD, 4 digits
    reg [3:0] n;
    reg busy, we;
    reg [1:0] idx;
    function [15:0] add3; input [15:0] d;
        integer k;
        begin
            for (k = 0; k < 4; k = k + 1)
                add3[4*k +: 4] = d[4*k +: 4] >= 4'd5 ? d[4*k +: 4] + 4'd3 : d[4*k +: 4];
        end
    endfunction
    wire [15:0] aw = add3(dw), ah = add3(dh), afw = add3(dfw), afh = add3(dfh);
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            bw <= 0; bh <= 0; bfw <= 0; bfh <= 0; dw <= 0; dh <= 0; dfw <= 0; dfh <= 0;
            n <= 0; busy <= 0; we <= 0; idx <= 0;
        end else begin
            we <= 1'b0;
            if (commit) begin
                bw <= src_w; bh <= src_h; bfw <= fit_w; bfh <= fit_h;
                dw <= 0; dh <= 0; dfw <= 0; dfh <= 0;
                idx <= index; n <= 0; busy <= 1'b1;
            end else if (busy) begin
                dw <= {aw[14:0], bw[10]}; bw <= {bw[9:0], 1'b0};
                dh <= {ah[14:0], bh[10]}; bh <= {bh[9:0], 1'b0};
                dfw <= {afw[14:0], bfw[10]}; bfw <= {bfw[9:0], 1'b0};
                dfh <= {afh[14:0], bfh[10]}; bfh <= {bfh[9:0], 1'b0};
                if (n == 4'd10) begin busy <= 1'b0; we <= 1'b1; end
                n <= n + 1'b1;
            end
        end
    end

    // ---------------- pack the source "W×H" into 9 left-aligned cells (cell 0 in bits [3:0]) -----
    localparam [3:0] SP = 4'd10, X = 4'd12;
    wire wbig = dw[15:12] != 0, hbig = dh[15:12] != 0;
    reg [35:0] src_cells;
    always @* begin
        case ({wbig, hbig})
            2'b11: src_cells = {dh[3:0], dh[7:4], dh[11:8], dh[15:12], X, dw[3:0], dw[7:4], dw[11:8], dw[15:12]};
            2'b10: src_cells = {SP, dh[3:0], dh[7:4], dh[11:8], X, dw[3:0], dw[7:4], dw[11:8], dw[15:12]};
            2'b01: src_cells = {SP, dh[3:0], dh[7:4], dh[11:8], dh[15:12], X, dw[3:0], dw[7:4], dw[11:8]};
            default: src_cells = {SP, SP, dh[3:0], dh[7:4], dh[11:8], X, dw[3:0], dw[7:4], dw[11:8]};
        endcase
    end
    wire [59:0] wdata = {dfh[3:0], dfh[7:4], dfh[11:8], dfw[3:0], dfw[7:4], dfw[11:8], src_cells};

`ifdef BMP_SCALER_BEHAVIORAL_RAM
    reg [59:0] mem [0:3];
    reg [59:0] q;
    integer i;
    initial for (i = 0; i < 4; i = i + 1) mem[i] = 60'd0;
    always @(posedge clk) if (we) mem[idx] <= wdata;
    always @(posedge rd_clk) q <= mem[rd_index];
    assign cells = q;
`else
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(60), .DATA_WIDTH_B(60), .ADDR_WIDTH_A(2), .ADDR_WIDTH_B(2),
        .DATA_DEPTH_A(4), .DATA_DEPTH_B(4), .MODE("DP"),
        .REGMODE_A("NOREG"), .REGMODE_B("NOREG"), .WRITEMODE_A("NORMAL"), .WRITEMODE_B("NORMAL"),
        .RESETMODE("SYNC"), .IMPLEMENT("9K")
    ) u_ram(
        .dia(wdata), .addra(idx), .cea(we), .ocea(1'b0), .clka(clk), .wea(we), .rsta(1'b0), .bea(1'b0),
        .dib(60'd0), .addrb(rd_index), .ceb(1'b1), .oceb(1'b0), .clkb(rd_clk), .web(1'b0), .rstb(1'b0),
        .beb(1'b0), .doa(), .dob(cells));
`endif
endmodule
