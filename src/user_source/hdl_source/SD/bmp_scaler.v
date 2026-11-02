`timescale 1ns/1ps
// 扩展要求3（10/21，方案A）：读卡时把不同分辨率的 BMP 缩放到 HDMI 输出分辨率 OUT_W×OUT_H。
//
// 位置：bmp_stream_decode（逐像素、自下而上逐行）与 media_frame_loader（固定 OUT_W×OUT_H 帧）
// 之间。帧缓存、轮播、淡入淡出、缩略图、亮度/对比度、OSD 均不变。
//
// 算法（“区域平均 + 双线性”）：
//   s = min(OUT_W/W, OUT_H/H)，保持宽高比；输出图 Wo×Ho 居中，其余用 FILL_RGB 填边。
//   1. 区域平均预滤波：k = floor(1/s)（1..3），k×k 像素求平均得到中间图 Wi×Hi（Wi = floor(W/k)，
//      右边/上边不足 k 的余数列/行舍去）。大倍率缩小（如 1920→640）时普通双线性只取相邻两点、
//      跳过中间像素，会出现锯齿和摩尔纹；先区域平均相当于先低通再采样。
//   2. 双线性插值：中间图 → Wo×Ho，步长 sx = Wi/Wo ∈ [1,2)（16 位小数，向下取整），像素中心对齐：
//      xi = (xo+0.5)·sx − 0.5；在中间列 j = ⌈xi⌉ 到达时输出 b[j−1] + (b[j]−b[j−1])·t，
//      t = xi − (j−1)，取 8 位权（xi 为整数时 t = 1）。纵向相同。
//   640×480 原图：k = 1、sx = sy = 1、t 恒为 1，输出逐位等于原像素。
//
// 流式实现：源像素一到即处理，不需要整帧缓存。行缓存（每个输出列、每个颜色通道一项：纵向区域累加
// + 上一中间行结果）放在 EG 的 32K 块 RAM 里；乘法用 DSP。一个源像素最多产生一个输出像素（步长 ≥ 1）。
// 资源与时序（大厅板 slice 已近满，布线拥挤）：
//   * R/G/B 三个通道分时共用一条运算流水线（每个输出像素 3×7 拍）；
//   * 每个源像素的判断（是否到达输出列/行、行尾等）提前两拍算好存进寄存器，接收像素那一拍
//     只用寄存器；设置阶段的除法器装载与迭代分开；行缓存读出加输出寄存器；填边输出两拍一个；
//   * 输入先进一个单元缓冲（in_ready 是寄存器输出，不再由本模块状态机组合给出），S_RUN 看到
//     缓冲有像素后下一拍（S_TAKE）再处理，接收那一拍只译码一个状态寄存器。
//   SD 卡 25 MHz SPI 约 96 拍才来一个源像素，这些都不影响加载速度。
// 输出顺序与 bmp_stream_decode 相同（自下而上、自左而右），共 OUT_W×OUT_H 个像素；填边像素不等
// 输入直接送出。源像素全部收完（src_done）且输出满一帧后发 done。failed 恒为 0：不会停住，
// 万一停住由 media_frame_loader 的停顿超时（错误 9）兜底。
// 像素打包与 bmp_stream_decode 相同：[7:0] B，[15:8] G，[23:16] R。
module bmp_scaler #(
    parameter integer OUT_W = 640,
    parameter integer OUT_H = 480,
    parameter [23:0] FILL_RGB = 24'hFAFAF9,       // 填边色（R G B），10/26 起与界面一致的暖白（原深蓝 1A2C4A）
    parameter integer DONE_TIMEOUT = 0            // unused (kept for compatibility)
)(
    input clk, rst,
    input start,                                  // 新的一次加载：清空，等待 cfg
    input abort,
    input cfg_valid,                              // 文件头已通过检查
    input [10:0] src_w, src_h,
    input in_valid, input [23:0] in_rgb, output in_ready,
    input src_done,                               // 源像素已全部交出
    output reg out_valid, output reg [23:0] out_rgb, input out_ready,
    output reg done, failed,
    output busy,
    output reg [10:0] fit_w, fit_h,               // 缩放后图像尺寸 Wo×Ho（测试用，顶层不接）
    output reg [1:0] box_k                        // 区域平均倍数 k（测试用，顶层不接）
);
    localparam integer AW = (OUT_W <= 2) ? 1 : $clog2(OUT_W);
    localparam [4:0] S_IDLE = 0, S_CFG = 1, S_K = 2, S_D1 = 3, S_D2 = 4, S_D3 = 5, S_D4 = 6, S_D5 = 7,
                     S_D6 = 8, S_FIN1 = 9, S_FIN2 = 10, S_RUN = 11, S_SETTLE = 12,
                     S_P2 = 13, S_P3 = 14, S_P4 = 15, S_P5 = 16, S_P6 = 17, S_P7 = 18, S_P8 = 19,
                     S_K2 = 21, S_SETTLE2 = 22, S_TAKE = 23;
    reg [4:0] st;
    // busy == (st != S_IDLE) at every clock edge, kept as a register: st only becomes S_IDLE
    // in the three places that also clear st_busy, and only leaves it through start.
    reg st_busy;
    assign busy = st_busy;

    // ---------------- set-up: one shared restoring divider (27-bit / 11-bit) ----------------
    // The FSM writes dv_num/dv_d and pulses dv_go; the divider loads and iterates on its own.
    reg [26:0] dv_q, dv_num;
    reg [10:0] dv_r, dv_d;
    reg [4:0] dv_n;
    reg dv_go;
    wire [11:0] dv_shift = {dv_r, dv_q[26]};
    wire [12:0] dv_trial = {1'b0, dv_shift} - {2'b00, dv_d};
    wire dv_idle = dv_n == 0 && !dv_go;

    reg [10:0] w, h, wi, hi, wo, ho, x0, y0, x1, y1, wlim, hlim;
    reg wide;
    reg [1:0] kk;
    reg [16:0] sx, sy;                  // step Wi/Wo in [1,2), 16 fractional bits
    reg [15:0] xi0, yi0;                // first sample position (sx-1)/2 in [0,0.5)
    wire [19:0] w_by_outh = w * OUT_H, h_by_outw = h * OUT_W;

    // ---------------- streaming state ----------------
    reg [10:0] c, r, j, i, xo, yo, cx, cy;
    reg [1:0] hc, vr;
    reg [26:0] xi, yi;
    wire [10:0] ceil_x = xi[26:16] + (xi[15:0] != 0);
    wire [10:0] ceil_y = yi[26:16] + (yi[15:0] != 0);
    wire [8:0] t_x = xi[15:0] == 0 ? 9'd256 : {1'b0, xi[15:8]};
    wire [8:0] t_y = yi[15:0] == 0 ? 9'd256 : {1'b0, yi[15:8]};

    // Per-pixel decisions, free running. After a taken pixel the FSM spends S_SETTLE (cx/cy
    // follow xi/yi) and S_SETTLE2 (these follow c/r/hc/vr/j/i/xo/yo and cx/cy) before S_RUN.
    reg f_row_active, f_last_row, f_box_done, f_hemit, f_vemit, f_row_end, f_first, f_i0, f_j0;
    always @(posedge clk) begin
        f_row_active <= r < hlim;
        f_last_row <= vr == kk - 2'd1;
        f_box_done <= c < wlim && hc == kk - 2'd1;
        f_hemit <= c < wlim && hc == kk - 2'd1 && r < hlim && cx == j && xo < wo;
        f_vemit <= vr == kk - 2'd1 && cy == i && yo < ho && r < hlim;
        f_row_end <= c == w - 1'b1;
        f_first <= vr == 0;
        f_i0 <= i == 0;
        f_j0 <= j == 0;
    end

    reg dp_valid;
    reg [23:0] dp_pix;
    // one-entry input buffer
    reg ib_valid;
    reg [23:0] ib_rgb;
    assign in_ready = !ib_valid;
    wire take = st == S_TAKE;                         // process the buffered pixel

    // context of the pixel in the S_P2..S_P8 passes (latched on take)
    reg [AW-1:0] xo_l;
    reg [8:0] th_l, tv_l;
    reg first_l, last_l, vemit_l, i0_l;
    reg [1:0] chs;                                    // channel of the current pass: 0 B, 1 G, 2 R

    // ---------------- horizontal box sums: per channel, updated on every taken pixel --------
    reg [9:0] hsum [0:2], bprev [0:2], ah [0:2], bh [0:2];
    integer q;
    always @(posedge clk) if (take) begin
        for (q = 0; q < 3; q = q + 1) begin
            hsum[q] <= (hc == 0 ? 10'd0 : hsum[q]) + {2'b00, ib_rgb[q*8 +: 8]};
            if (f_box_done) begin
                bprev[q] <= (hc == 0 ? 10'd0 : hsum[q]) + {2'b00, ib_rgb[q*8 +: 8]};
                ah[q] <= f_j0 ? (hc == 0 ? 10'd0 : hsum[q]) + {2'b00, ib_rgb[q*8 +: 8]} : bprev[q];
                bh[q] <= (hc == 0 ? 10'd0 : hsum[q]) + {2'b00, ib_rgb[q*8 +: 8]};
            end
        end
    end

    // ---------------- line buffer: {acc[12], prev[8]} per (channel, output column) -----------
    // Output register on the read port: data two cycles after the address (used from S_P4).
    wire [19:0] rd_word, wr_word;
    wire [AW+1:0] line_addr = {chs, xo_l};
    bmp_scaler_line_ram #(.WIDTH(20), .ADDR(AW + 2)) u_line(
        .clk(clk), .we(st == S_P8), .waddr(line_addr), .wdata(wr_word), .raddr(line_addr), .rdata(rd_word));

    // ---------------- one arithmetic pipeline, free running; each operand is stable for the
    // stage that uses it (S_P2..S_P8 below), one channel per pass ----------------------------
    wire [9:0] ah_s = ah[chs], bh_s = bh[chs];
    reg signed [20:0] hmul;
    wire signed [21:0] hsum_lerp = $signed({4'b0000, ah_s, 8'h80}) + hmul;   // ah + (bh-ah)·t/256
    reg [9:0] hval;
    wire [11:0] acc_old = rd_word[19:8];
    wire [7:0] prev_old = rd_word[7:0];
    reg [11:0] asum;
    reg [24:0] nmul;
    reg [7:0] c8;
    wire [7:0] pv = i0_l ? c8 : prev_old;
    reg signed [17:0] vmul;
    wire signed [18:0] v_lerp = $signed({3'b000, pv, 8'h80}) + vmul;
    always @(posedge clk) begin
        hmul <= ($signed({1'b0, bh_s}) - $signed({1'b0, ah_s})) * $signed({1'b0, th_l});
        hval <= hsum_lerp[17:8];
        asum <= (first_l ? 12'd0 : acc_old) + {2'b00, hval};
        nmul <= asum * 13'd7282;                             // ≈ asum/9 · 65536
        c8 <= kk == 2'd1 ? asum[7:0] :
              kk == 2'd2 ? (asum[9:0] + 10'd2) >> 2 :
                           (nmul[23:0] + 24'd32768) >> 16;
        vmul <= ($signed({1'b0, c8}) - $signed({1'b0, pv})) * $signed({1'b0, tv_l});
    end
    assign wr_word = {asum, last_l ? c8 : prev_old};
    reg [15:0] out_lo;                                // B, G results of the passes so far

    // ---------------- output emitter: OUT_W×OUT_H, fill outside [x0,x1)×[y0,y1) ----------------
    // At most one output every two cycles, so the inside/outside decision is a register.
    reg [10:0] ex, ey;
    reg emit_en, e_done, e_wait, in_img_q, src_done_l;
    always @(posedge clk) in_img_q <= ey >= y0 && ey < y1 && ex >= x0 && ex < x1;
    wire slot_free = !out_valid || out_ready;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            st <= S_IDLE; st_busy <= 1'b0; dv_q <= 0; dv_num <= 0; dv_r <= 0; dv_d <= 0; dv_n <= 0; dv_go <= 0;
            w <= 0; h <= 0; wi <= 0; hi <= 0; wo <= 0; ho <= 0; x0 <= 0; y0 <= 0; x1 <= 0; y1 <= 0;
            wlim <= 0; hlim <= 0; wide <= 0; kk <= 2'd1; sx <= 0; sy <= 0; xi0 <= 0; yi0 <= 0;
            c <= 0; r <= 0; j <= 0; i <= 0; xo <= 0; yo <= 0; cx <= 0; cy <= 0; hc <= 0; vr <= 0;
            xi <= 0; yi <= 0; dp_valid <= 0; dp_pix <= 0; ib_valid <= 0; ib_rgb <= 0;
            xo_l <= 0; th_l <= 0; tv_l <= 0; first_l <= 0; last_l <= 0; vemit_l <= 0; i0_l <= 0;
            chs <= 0; out_lo <= 0;
            out_valid <= 0; out_rgb <= 0; done <= 0; failed <= 0;
            fit_w <= 0; fit_h <= 0; box_k <= 0;
            ex <= 0; ey <= 0; emit_en <= 0; e_done <= 0; e_wait <= 0; src_done_l <= 0;
        end else begin
            done <= 0; failed <= 0;
            cx <= ceil_x; cy <= ceil_y;                       // settled one cycle after xi/yi change
            dv_go <= 0;
            if (dv_go) begin
                dv_q <= dv_num; dv_r <= 0; dv_n <= 5'd27;
            end else if (dv_n != 0) begin
                dv_n <= dv_n - 1'b1;
                dv_q <= {dv_q[25:0], !dv_trial[12]};
                dv_r <= dv_trial[12] ? dv_shift[10:0] : dv_trial[10:0];
            end
            if (src_done && busy) src_done_l <= 1'b1;
            if (in_valid && !ib_valid) begin ib_valid <= 1'b1; ib_rgb <= in_rgb; end
            if (take) ib_valid <= 1'b0;

            // ---- emitter ----
            if (out_valid && out_ready) out_valid <= 1'b0;
            e_wait <= 1'b0;
            if (emit_en && !e_done && !e_wait && slot_free && (!in_img_q || dp_valid)) begin
                out_valid <= 1'b1;
                out_rgb <= in_img_q ? dp_pix : FILL_RGB;
                if (in_img_q) dp_valid <= 1'b0;
                e_wait <= 1'b1;
                if (ex == OUT_W - 1) begin
                    ex <= 0; ey <= ey + 1'b1;
                    if (ey == OUT_H - 1) e_done <= 1'b1;
                end else ex <= ex + 1'b1;
            end

            case (st)
                S_IDLE: ;
                S_CFG: if (cfg_valid) begin
                    w <= src_w; h <= src_h; st <= S_K;
                end
                S_K: begin                                   // wide: limited by the output width
                    wide <= w_by_outh >= h_by_outw;
                    if (w_by_outh >= h_by_outw) kk <= w >= 3 * OUT_W ? 2'd3 : w >= 2 * OUT_W ? 2'd2 : 2'd1;
                    else kk <= h >= 3 * OUT_H ? 2'd3 : h >= 2 * OUT_H ? 2'd2 : 2'd1;
                    st <= S_K2;
                end
                S_K2: begin                                  // round(other side · OUT / this side)
                    dv_num <= wide ? h_by_outw + (w >> 1) : w_by_outh + (h >> 1);
                    dv_d <= wide ? w : h;
                    dv_go <= 1'b1; st <= S_D1;
                end
                S_D1: if (dv_idle) begin
                    if (wide) begin wo <= OUT_W; ho <= dv_q[10:0]; end
                    else begin ho <= OUT_H; wo <= dv_q[10:0]; end
                    dv_num <= {16'd0, w}; dv_d <= {9'd0, kk}; dv_go <= 1'b1; st <= S_D2;
                end
                S_D2: if (dv_idle) begin
                    wi <= dv_q[10:0];
                    dv_num <= {16'd0, h}; dv_d <= {9'd0, kk}; dv_go <= 1'b1; st <= S_D3;
                end
                S_D3: if (dv_idle) begin
                    hi <= dv_q[10:0];
                    // never larger than the intermediate image: keeps the steps >= 1
                    if (wo > wi) wo <= wi;
                    if (ho > dv_q[10:0]) ho <= dv_q[10:0];
                    st <= S_D4;
                end
                S_D4: begin
                    dv_num <= {wi, 16'd0}; dv_d <= wo; dv_go <= 1'b1; st <= S_D5;
                end
                S_D5: if (dv_idle) begin                     // sx = Wi/Wo
                    sx <= dv_q[16:0];
                    dv_num <= {hi, 16'd0}; dv_d <= ho; dv_go <= 1'b1; st <= S_D6;
                end
                S_D6: if (dv_idle) begin                     // sy = Hi/Ho
                    sy <= dv_q[16:0]; st <= S_FIN1;
                end
                S_FIN1: begin
                    x0 <= (OUT_W - wo) >> 1; y0 <= (OUT_H - ho) >> 1;
                    xi0 <= sx[16:1] - 16'd32768; yi0 <= sy[16:1] - 16'd32768;
                    wlim <= kk == 2'd1 ? wi : kk == 2'd2 ? {wi[9:0], 1'b0} : {wi[9:0], 1'b0} + wi;
                    hlim <= kk == 2'd1 ? hi : kk == 2'd2 ? {hi[9:0], 1'b0} : {hi[9:0], 1'b0} + hi;
                    fit_w <= wo; fit_h <= ho; box_k <= kk;
                    st <= S_FIN2;
                end
                S_FIN2: begin
                    x1 <= x0 + wo; y1 <= y0 + ho;
                    xi <= {11'd0, xi0}; yi <= {11'd0, yi0};
                    c <= 0; r <= 0; j <= 0; i <= 0; xo <= 0; yo <= 0; hc <= 0; vr <= 0;
                    emit_en <= 1'b1; e_wait <= 1'b1;         // in_img_q follows x1/y1 first
                    st <= S_SETTLE;
                end
                S_RUN: begin
                    if (ib_valid && !dp_valid) st <= S_TAKE;
                    else if (src_done_l && e_done && !dp_valid && !out_valid && !ib_valid) begin
                        done <= 1'b1; st <= S_IDLE; st_busy <= 1'b0;
                    end
                end
                S_TAKE: begin
                    begin
                        if (f_box_done) j <= j + 1'b1;
                        if (f_hemit) begin
                            xo_l <= xo[AW-1:0]; th_l <= t_x; tv_l <= t_y; chs <= 2'd0;
                            first_l <= f_first; last_l <= f_last_row; vemit_l <= f_vemit; i0_l <= f_i0;
                            xi <= xi + {10'd0, sx}; xo <= xo + 1'b1;
                        end
                        hc <= hc == kk - 2'd1 ? 2'd0 : hc + 1'b1;
                        if (f_row_end) begin                     // end of a source row
                            c <= 0; hc <= 0; j <= 0; xo <= 0; xi <= {11'd0, xi0};
                            if (f_row_active) begin
                                vr <= f_last_row ? 2'd0 : vr + 1'b1;
                                if (f_last_row) begin
                                    i <= i + 1'b1;
                                    if (f_vemit) begin yi <= yi + {10'd0, sy}; yo <= yo + 1'b1; end
                                end
                            end
                            r <= r + 1'b1;
                        end else c <= c + 1'b1;
                        st <= f_hemit ? S_P2 : S_SETTLE;
                    end
                end
                S_SETTLE: st <= S_SETTLE2;                   // cx/cy follow xi/yi
                S_SETTLE2: st <= S_RUN;                      // decision flags follow
                S_P2: st <= S_P3;                            // horizontal product; line buffer read
                S_P3: st <= S_P4;                            // horizontal result
                S_P4: st <= S_P5;                            // vertical box sum
                S_P5: st <= S_P6;                            // ·1/9
                S_P6: st <= S_P7;                            // normalised value
                S_P7: st <= S_P8;                            // vertical product
                S_P8: begin                                  // line buffer write, channel result
                    if (chs == 2'd2) begin
                        if (last_l && vemit_l) begin dp_valid <= 1'b1; dp_pix <= {v_lerp[15:8], out_lo}; end
                        st <= S_RUN;                         // flags settled long ago
                    end else begin
                        out_lo <= {v_lerp[15:8], out_lo[15:8]};
                        chs <= chs + 1'b1; st <= S_P2;
                    end
                end
                default: begin st <= S_IDLE; st_busy <= 1'b0; end
            endcase

            if (start || abort) begin
                st <= start ? S_CFG : S_IDLE; st_busy <= start;
                emit_en <= 0; e_done <= 0; ex <= 0; ey <= 0; src_done_l <= 0;
                dp_valid <= 0; out_valid <= 0; dv_n <= 0; dv_go <= 0; ib_valid <= 0;
            end
        end
    end
endmodule

// Simple dual-port line buffer (write port A, read port B). The read port has an output
// register: data for an address appears two clock edges later.
// Synthesis: EG_LOGIC_BRAM placed in the 32K block RAMs (all 9K blocks are used by the UI).
// Simulation: TD's BRAM model is encrypted, so benches define BMP_SCALER_BEHAVIORAL_RAM.
module bmp_scaler_line_ram #(
    parameter integer WIDTH = 60,
    parameter integer ADDR = 10
)(
    input clk, we,
    input [ADDR-1:0] waddr, input [WIDTH-1:0] wdata,
    input [ADDR-1:0] raddr, output [WIDTH-1:0] rdata
);
`ifdef BMP_SCALER_BEHAVIORAL_RAM
    reg [WIDTH-1:0] mem [0:(1<<ADDR)-1];
    reg [WIDTH-1:0] q, q2;
    always @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        q <= mem[raddr];
        q2 <= q;
    end
    assign rdata = q2;
`else
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(WIDTH), .DATA_WIDTH_B(WIDTH), .ADDR_WIDTH_A(ADDR), .ADDR_WIDTH_B(ADDR),
        .DATA_DEPTH_A(1 << ADDR), .DATA_DEPTH_B(1 << ADDR), .MODE("DP"),
        .REGMODE_A("NOREG"), .REGMODE_B("OUTREG"), .WRITEMODE_A("NORMAL"), .WRITEMODE_B("NORMAL"),
        .RESETMODE("SYNC"), .IMPLEMENT("32K")
    ) u_ram(
        .dia(wdata), .addra(waddr), .cea(we), .ocea(1'b0), .clka(clk), .wea(we), .rsta(1'b0), .bea(1'b0),
        .dib({WIDTH{1'b0}}), .addrb(raddr), .ceb(1'b1), .oceb(1'b1), .clkb(clk), .web(1'b0), .rstb(1'b0),
        .beb(1'b0), .doa(), .dob(rdata));
`endif
endmodule
