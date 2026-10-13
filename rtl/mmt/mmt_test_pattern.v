//===========================================================================
//  mmt_test_pattern.v — 测试图案发生器（M0：无摄像头时自证“写 DDR→读 DDR→显示”）
//--------------------------------------------------------------------------
//  用途
//    在没有摄像头（或摄像头不出图）时，往 frame_buffer（checker0）的输入端
//    注入一条**与 CSI 摄像头同构**的视频流，从而把“DDR 写/读/显示”这条链路
//    与“摄像头”彻底解耦：
//        测试图案 ──▶ checker0(frame_buffer) ──▶ DDR ──▶ 读出 ──▶ debayer ──▶ HDMI
//
//  为什么不能用现成的 color_bar.v / color_bar_rgb.v
//    那两个模块输出的是 **24 位 RGB（1 像素/拍）**，而 checker0 的输入是
//    **32 位 = 4 个 8bit 像素/拍**（见下），接口不同构，直接接会得到错误数据。
//
//  与 checker0 输入严格同构（对照 rtl\mmt\mmt_top.v:710-713）
//    .i_clk  ← 本模块时钟（**自带时钟**，不能用 i_mipi_rx_pclk：没摄像头时它不跳）
//    .i_vs   ← o_vs
//    .i_de   ← o_de & o_hs        （顶层原样保留 “de & hs” 的与法）
//    .vin    ← o_vin[31:0]
//       o_vin[31:24] = 本拍第 0 个像素（x = 4c+0）
//       o_vin[23:16] = 第 1 个像素（x = 4c+1）
//       o_vin[15:8]  = 第 2 个像素（x = 4c+2）
//       o_vin[7:0]   = 第 3 个像素（x = 4c+3）
//    字节序依据：mmt_top.v:713 的拼接是 {lane0,lane1,lane2,lane3}，lane0 占最高字节。
//    ⚠️ 若上板发现颜色水平错位一像素，把这里 4 个字节的先后顺序整体反过来即可
//       （见 docs\测试图案注入.md 的排查表）。
//
//  图案内容（Bayer 编码）
//    生成标准 8 色彩条 + 一个横向平滑移动的白色方块；**按 RGGB 相位编码成
//    Bayer 马赛克**再输出，这样下游 debayer 才能正确还原成彩色：
//        (x 偶, y 偶)=R   (x 奇, y 偶)=G
//        (x 偶, y 奇)=G   (x 奇, y 奇)=B
//    （相位依据见 docs\去马赛克Bayer相位分析.md：raw_to_rgb 实测是 RGGB，
//      且要求偶列进 _0 通道。）
//
//  i_mode 方便上板做一次“红是红蓝是蓝”的判断：
//    0 = 8 色彩条 + 移动方块（默认）      1 = 纯红场
//    2 = 纯绿场                        3 = 纯蓝场
//
//  默认行为
//    i_en = 0 时所有输出恒 0（de/hs/vs 全低）⇒ 顶层默认选摄像头，**不影响现有行为**。
//    只有固件把 CFG_TEST_PATTERN 置 1，顶层多路选择器才会切到本模块。
//
//  资源
//    纯组合比较 + 几个计数器，无 RAM/无 DSP，几十个 LUT。
//===========================================================================
`timescale 1ns/1ps

module mmt_test_pattern #(
    // ---- 视频几何（默认=真实摄像头 1920x1080 RAW8、4 像素/拍）----
    parameter H_ACTIVE  = 1920,   // 每行有效像素数
    parameter V_ACTIVE  = 1080,   // 每帧有效行数
    parameter H_FRONT   = 120,    // 水平前肩（像素）
    parameter H_SYNC    = 2,      // 水平同步（像素）
    parameter H_BACK    = 88,     // 水平后肩（像素）
    parameter V_FRONT   = 20,     // 垂直前肩（行）
    parameter V_SYNC    = 2,      // 垂直同步（行）
    parameter V_BACK    = 20,     // 垂直后肩（行）
    parameter PPC       = 4,      // 每拍像素数（必须=4，与 checker0 输入一致）
    // ---- 移动方块 ----
    parameter SQ_W      = 160,    // 方块边长（像素）
    parameter SQ_STEP   = 32,     // 每帧右移像素数
    parameter BAR_LEVEL = 8'd235  // 彩条电平（不溢出，留余量）
)(
    input  wire        i_clk,     // 本模块时钟（顶层另给，例如 vid_clk_dvi2）
    input  wire        i_rstn,
    input  wire        i_en,      // 1=输出图案；0=输出全 0（默认）
    input  wire [1:0]  i_mode,    // 0=彩条+方块 1=纯红 2=纯绿 3=纯蓝

    output reg         o_vs,
    output reg         o_hs,
    output reg         o_de,
    output reg  [31:0] o_vin,

    // ---- 给仿真/上板观测用（不影响功能）----
    output reg  [15:0] o_frame_cnt,  // 已经过的帧数
    output reg  [15:0] o_line_cnt,   // 本帧已经过的行数
    output reg  [15:0] o_pix_cnt,    // 本行已经过的 de 拍数

    // ---- 视频时序测量（★ 摄像头模式下也一直在测，供上板判据用）----
    //   把**多路选择后的**三根视频线接进来（即 checker0 实际看到的 de/vs 与 hs）：
    //     摄像头模式 → 测的是摄像头真实的 LINES_PER_FRAME / PIXELS_PER_LINE
    //     图案模式   → 测的是图案自己的（应为 V_ACTIVE / H_ACTIVE/PPC）
    //   为什么必须在本模块（像素域）计数，而不是在 mmt_soc_regs（core_clk 域）：
    //     像素时钟 i_mipi_rx_pclk 是 PLL 输出、可能**快于** core_clk(100MHz)，
    //     在 core_clk 域采 de 电平会**漏掉**窄脉冲 ⇒ 计数偏小。
    //     在像素域数完再送出去，结果才是准的。
    input  wire        i_vid_de,
    input  wire        i_vid_hs,
    input  wire        i_vid_vs,
    output reg  [15:0] o_lines_per_frame,   // 一帧内 hs 上升沿个数
    output reg  [15:0] o_pixels_per_line,   // 一行内 de 拍数
    output reg  [15:0] o_vid_frame_cnt      // 上电以来检测到的 vs 个数
);

    localparam integer H_ACT_CLK = H_ACTIVE / PPC;                 // 每行 de 拍数
    localparam integer H_TOTAL   = H_SYNC + H_BACK + H_ACT_CLK + H_FRONT;
    localparam integer V_TOTAL   = V_SYNC + V_BACK + V_ACTIVE + V_FRONT;
    localparam integer XW        = 12;                             // x 计数器位宽
    localparam integer YW        = 12;                             // y 计数器位宽

    reg [XW-1:0] h_cnt;      // 行内计数（单位：de 拍）
    reg [YW-1:0] v_cnt;      // 帧内计数（单位：行）
    reg [XW-1:0] sq_x;       // 方块左上角 x（像素）

    // 有效窗口
    wire h_active = (h_cnt >= H_SYNC + H_BACK) &&
                    (h_cnt <  H_SYNC + H_BACK + H_ACT_CLK);
    wire v_active = (v_cnt >= V_SYNC + V_BACK) &&
                    (v_cnt <  V_SYNC + V_BACK + V_ACTIVE);

    wire line_end  = (h_cnt == H_TOTAL - 1);
    wire frame_end = line_end && (v_cnt == V_TOTAL - 1);

    // 当前行在帧内的有效行号（0..V_ACTIVE-1）
    wire [YW-1:0] v_act_idx = v_cnt - (V_SYNC + V_BACK);
    // 本拍 4 个像素的列坐标
    wire [XW-1:0] h_base = h_cnt - (H_SYNC + H_BACK);
    // ★ 2026-10-13：Verific 不接受对窄信号做 [15:0] 越界切片（VERI-1216），
    //   所以先零扩展成 16 位再赋给 o_line_cnt/o_pix_cnt。
    wire [15:0] v_act_idx16 = v_act_idx;   // 零扩展（YW<=16）
    wire [15:0] h_base16    = h_base;      // 零扩展（XW<=16）

        wire [XW:0]   x0 = {1'b0, h_base} * PPC;      // 4c+0
    wire [XW:0]   x1 = x0 + 1'b1;
    wire [XW:0]   x2 = x0 + 2'd2;
    wire [XW:0]   x3 = x0 + 2'd3;

    //------------------------------------------------------------------
    //  像素值：先算“想要什么颜色”，再按 RGGB 相位取对应通道
    //------------------------------------------------------------------
    function [7:0] px_val;
        input [XW:0]    x;        // 列（像素）
        input [YW-1:0]  y;        // 行（像素，有效区内）
        input [1:0]     mode;
        input [XW-1:0]  sqx;      // 方块左上角
        reg [7:0]       cr, cg, cb;
        reg [XW:0]      xq;
        begin
            // ---- 1. 想显示的颜色 ----
            if (mode == 2'd1) begin                 // 纯红场
                cr = BAR_LEVEL; cg = 8'd0; cb = 8'd0;
            end else if (mode == 2'd2) begin        // 纯绿场
                cr = 8'd0; cg = BAR_LEVEL; cb = 8'd0;
            end else if (mode == 2'd3) begin        // 纯蓝场
                cr = 8'd0; cg = 8'd0; cb = BAR_LEVEL;
            end else begin                          // 8 色彩条
                xq = (x * 8) / H_ACTIVE;            // 0..7
                case (xq)
                4'd0: begin cr = BAR_LEVEL; cg = BAR_LEVEL; cb = BAR_LEVEL; end // 白
                4'd1: begin cr = BAR_LEVEL; cg = BAR_LEVEL; cb = 8'd0;      end // 黄
                4'd2: begin cr = 8'd0;      cg = BAR_LEVEL; cb = BAR_LEVEL; end // 青
                4'd3: begin cr = 8'd0;      cg = BAR_LEVEL; cb = 8'd0;      end // 绿
                4'd4: begin cr = BAR_LEVEL; cg = 8'd0;      cb = BAR_LEVEL; end // 品红
                4'd5: begin cr = BAR_LEVEL; cg = 8'd0;      cb = 8'd0;      end // 红
                4'd6: begin cr = 8'd0;      cg = 8'd0;      cb = BAR_LEVEL; end // 蓝
                default: begin cr = 8'd0;   cg = 8'd0;      cb = 8'd0;       end // 黑
                endcase
            end

            // ---- 2. 移动白色方块覆盖其上 ----
            if (x >= sqx && x < sqx + SQ_W &&
                y >= (V_ACTIVE/2 - SQ_W/2) && y < (V_ACTIVE/2 + SQ_W/2)) begin
                if (mode == 2'd0) begin
                    cr = BAR_LEVEL; cg = BAR_LEVEL; cb = BAR_LEVEL;
                end
            end

            // ---- 3. 按 RGGB 相位取该 Bayer 位置对应的通道 ----
            if (y[0] == 1'b0)
                px_val = x[0] ? cg : cr;     // 偶行：偶列=R，奇列=G
            else
                px_val = x[0] ? cb : cg;     // 奇行：偶列=G，奇列=B
        end
    endfunction

    wire [7:0] p0 = px_val(x0, v_act_idx, i_mode, sq_x);
    wire [7:0] p1 = px_val(x1, v_act_idx, i_mode, sq_x);
    wire [7:0] p2 = px_val(x2, v_act_idx, i_mode, sq_x);
    wire [7:0] p3 = px_val(x3, v_act_idx, i_mode, sq_x);

    //------------------------------------------------------------------
    //  时序与计数器
    //------------------------------------------------------------------
    always @(posedge i_clk or negedge i_rstn) begin
        if (!i_rstn) begin
            h_cnt <= {XW{1'b0}};
            v_cnt <= {YW{1'b0}};
            sq_x  <= {XW{1'b0}};
            o_frame_cnt <= 16'd0;
        end else if (!i_en) begin
            // 关闭时把内部相位复位，保证打开时从帧首开始，图案稳定可预期
            h_cnt <= {XW{1'b0}};
            v_cnt <= {YW{1'b0}};
        end else begin
            if (line_end) begin
                h_cnt <= {XW{1'b0}};
                if (v_cnt == V_TOTAL - 1) begin
                    v_cnt <= {YW{1'b0}};
                    o_frame_cnt <= o_frame_cnt + 16'd1;
                    // 方块每帧右移，越界回 0
                    sq_x <= (sq_x + SQ_STEP > H_ACTIVE - SQ_W) ? {XW{1'b0}}
                                                              : sq_x + SQ_STEP[XW-1:0];
                end else begin
                    v_cnt <= v_cnt + 1'b1;
                end
            end else begin
                h_cnt <= h_cnt + 1'b1;
            end
        end
    end

    //------------------------------------------------------------------
    //  输出（i_en=0 时全部拉低，顶层默认仍是摄像头）
    //------------------------------------------------------------------
    always @(posedge i_clk or negedge i_rstn) begin
        if (!i_rstn) begin
            o_vs  <= 1'b0;
            o_hs  <= 1'b0;
            o_de  <= 1'b0;
            o_vin <= 32'h0;
            o_line_cnt <= 16'd0;
            o_pix_cnt  <= 16'd0;
        end else if (!i_en) begin
            o_vs  <= 1'b0;
            o_hs  <= 1'b0;
            o_de  <= 1'b0;
            o_vin <= 32'h0;
            o_line_cnt <= 16'd0;
            o_pix_cnt  <= 16'd0;
        end else begin
            o_vs  <= v_active;
            // hs 在行内为高（含消隐），但**只在垂直有效区内**：这样
            //   ① 顶层 “de & hs” 恒等于 de；
            //   ② hs 上升沿数 = 每帧行数，LINES_PER_FRAME 计数干净。
            o_hs  <= v_active & ~(h_cnt < H_SYNC);
            // de 必须**同时**受行有效与垂直有效约束！
            // （仿真踩过的坑：只写 h_active 会让垂直消隐期也发 de，
            //   于是出现 “de=1 且 vs=0”，把 frame_info_det 的 negtive_sync
            //   打成 0 → w_frame_start 永不产生 → 打包器不启动 → AW 恒 0。）
            o_de  <= h_active & v_active;
            // 字节序：o_vin[31:24] 是**本拍第 0 个像素**（x=4c+0），与文件头约定一致。
            // （仿真 T5 曾抓到这里写成 {p3,p2,p1,p0}，导致红场相位左右颠倒。）
            o_vin <= {p0, p1, p2, p3};
            // 观测计数
            o_line_cnt <= v_active ? v_act_idx16 : 16'd0;
            o_pix_cnt  <= h_active ? h_base16    : 16'd0;
        end
    end

    //------------------------------------------------------------------
    //  视频时序测量：LINES_PER_FRAME / PIXELS_PER_LINE
    //    PIXELS_PER_LINE = 相邻两个 hs 上升沿之间的 de 拍数
    //    LINES_PER_FRAME = 相邻两个 vs 沿之间的 hs 上升沿数
    //    用 (* preserve, syn_keep = 1 *) 防止被优化掉（与既有遥测寄存器同风格）
    //------------------------------------------------------------------
    reg  vid_de_d, vid_hs_d, vid_vs_d;
    reg  [15:0] pix_acc, lines_cur;

    wire vid_hs_rise = i_vid_hs & ~vid_hs_d;
    wire vid_vs_fall = ~i_vid_vs & vid_vs_d;

    (* preserve, syn_keep = 1 *) reg [15:0] lines_per_frame_r;
    (* preserve, syn_keep = 1 *) reg [15:0] pixels_per_line_r;
    (* preserve, syn_keep = 1 *) reg [15:0] vid_frame_cnt_r;

    always @(posedge i_clk or negedge i_rstn) begin
        if (!i_rstn) begin
            vid_de_d <= 1'b0; vid_hs_d <= 1'b0; vid_vs_d <= 1'b0;
            pix_acc <= 16'd0; lines_cur <= 16'd0;
            lines_per_frame_r <= 16'd0; pixels_per_line_r <= 16'd0;
            vid_frame_cnt_r <= 16'd0;
        end else begin
            vid_de_d <= i_vid_de;
            vid_hs_d <= i_vid_hs;
            vid_vs_d <= i_vid_vs;

            if (vid_hs_rise) begin
                pixels_per_line_r <= pix_acc;      // 上一整行数出来的 de 拍数
                pix_acc <= i_vid_de ? 16'd1 : 16'd0;
                if (i_vid_vs) lines_cur <= lines_cur + 16'd1;
            end else if (i_vid_de) begin
                pix_acc <= pix_acc + 16'd1;
            end

            if (vid_vs_fall) begin
                lines_per_frame_r <= lines_cur;
                lines_cur <= 16'd0;
                vid_frame_cnt_r <= vid_frame_cnt_r + 16'd1;
            end
        end
    end

    always @(*) begin
        o_lines_per_frame = lines_per_frame_r;
        o_pixels_per_line = pixels_per_line_r;
        o_vid_frame_cnt   = vid_frame_cnt_r;
    end

endmodule
