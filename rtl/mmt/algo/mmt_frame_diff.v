//==========================================================================
//  mmt_frame_diff.v  —  帧差法运动检测（赛题任务2「运动分析」的规则算法）
//--------------------------------------------------------------------------
//  算法链（与赛题技术要点原文一致，也与我方已验证的 Python 原型
//  工作区\02_传感器与算法原型\frame_diff.py 一致）：
//      当前帧 − 背景帧 → 阈值分割 → 面积/质心统计 → 运动判据
//
//  设计取舍（都写清楚理由）：
//  1) 【不做完整连通域标注】。Python 原型用 scipy.ndimage.label 做 4 邻域连通域，
//     RTL 里做等价的全功能 union-find 代价很高。赛题只要求"连通域面积和质心位移"，
//     这里用**逐像素累加掩码统计**替代：面积 = Σmask、质心 = (Σx·mask, Σy·mask)/面积。
//     对"一个人体在画面里"这种单目标场景，两者结论一致。
//     ⚠️ 已知简化：多目标并排时本实现会算成一个整体（面积相加、质心居中），
//        而连通域标注会分成两块。要区分多目标需升级为行游程 + 逐行合并。
//  2) 【除法不做在硬件里】。质心要除以面积（最大 160×120=19200）。
//     这里只输出 sum_x / sum_y / area，由 RISC-V 做除法（它反正要在）。省一个除法器。
//  3) 【背景更新用移位】bg += (cur − bg) >> BG_SHIFT，即 α=1/32，避免乘法器。
//     有运动时冻结更新（否则会把运动物体吸进背景，Python 原型已验证）。
//
//  ★ 存储实现（这条是踩坑换来的，别改）：
//     背景帧放在 **mmt_dpram** 里，不用裸 reg 数组。原因：
//     - 裸数组 + for 循环初值 → 综合器推断成触发器（19200×8 → 15 万个 FF，综合爆炸）
//     - 裸数组 + 读写混在一个 always 块 → Efinity 报 EFX-0657，把 RAM 映射成逻辑单元
//     mmt_dpram 的写法（读写分两个独立 always 块、读口无条件寄存读）实测能正确推断 BRAM。
//     背景清零也**走写端口逐拍写**（PIX_NUM 拍），不用 for 循环。
//
//  像素流假设：上游（降采样/灰度化）每帧发出**恰好 IMG_W × IMG_H 个** pix_de 有效像素；
//  本模块按 de 计数，与 hs/vs 极性无关（避免踩极性坑）。
//  一帧处理完后 frame_done 拉高一拍并停止处理，等 pix_vs 上升沿开始下一帧。
//==========================================================================
`timescale 1ns / 1ps

module mmt_frame_diff #(
    parameter IMG_W    = 160,
    parameter IMG_H    = 120,
    parameter BG_SHIFT = 5,               // 背景更新系数 α = 1/2^BG_SHIFT
    parameter XW       = 8,               // x 坐标位宽
    parameter YW       = 8,               // y 坐标位宽
    parameter AW       = 15               // 背景 RAM 地址位宽（2^15 = 32768 >= 19200）
)(
    input  wire        clk,
    input  wire        rst_n,

    // ---- 像素输入流（下采样后的 8bit 灰度）----
    input  wire [7:0]  pix_data,
    input  wire        pix_de,
    input  wire        pix_vs,            // 帧起始标志

    // ---- 可配置参数（对应 Python 原型里的三个可调参数）----
    input  wire [7:0]  threshold,         // 帧差阈值，原型默认 25
    input  wire [15:0] min_area,          // 最小面积，原型默认 60
    input  wire        enable,            // 0 = 整体旁路
    input  wire        bg_freeze,         // 1 = 冻结背景更新

    // ---- 帧结果（保持到下一帧结束）----
    output reg         frame_done,
    output reg  [31:0] sum_area,
    output reg  [31:0] sum_x,
    output reg  [31:0] sum_y,
    output reg         motion,
    output reg  [15:0] diff_cnt,

    // ---- 清空背景（上电/场景切换时用，需保持到清完）----
    input  wire        bg_clear
);

    localparam PIX_NUM = IMG_W * IMG_H;

    //----------------------------------------------------------------------
    // 背景帧存储（mmt_dpram：写口做更新/清零，读口取旧背景）
    //----------------------------------------------------------------------
    reg  [31:0] pix_cnt;                  // 帧内像素计数（也当 RAM 地址）
    reg  [XW-1:0] x_cnt;
    reg  [YW-1:0] y_cnt;
    reg         frame_active;

    reg  [7:0]  bg_q;                     // 读口输出（天然延迟一拍）
    reg  [7:0]  pix_q;
    reg  [XW-1:0] x_q;
    reg  [YW-1:0] y_q;
    reg         de_q;
    reg  [31:0] addr_q;

    reg  [31:0] acc_area, acc_x, acc_y;

    // 差分与掩码（对已延迟一拍的像素与背景做）
    wire [8:0]  diff_raw = (pix_q > bg_q) ? ({1'b0, pix_q} - {1'b0, bg_q})
                                          : ({1'b0, bg_q} - {1'b0, pix_q});
    wire        mask     = (diff_raw > {1'b0, threshold});

    // 背景更新值：bg += (cur − bg) >> BG_SHIFT
    wire signed [9:0] delta  = $signed({1'b0, pix_q}) - $signed({1'b0, bg_q});
    wire signed [9:0] step   = delta >>> BG_SHIFT;
    wire [7:0]        bg_new = bg_q + step[7:0];

    // 清零控制（走写端口逐拍写，不用 for 循环）
    reg  [31:0] clear_cnt;
    reg         clearing;

    // 写口信号：清零优先
    wire        bg_we    = clearing ? 1'b1 : (de_q && !bg_freeze);
    wire [AW-1:0] bg_waddr = clearing ? clear_cnt[AW-1:0] : addr_q[AW-1:0];
    wire [7:0]  bg_wdata = clearing ? 8'd0 : bg_new;

    mmt_dpram #(
        .DW    (8),
        .AW    (AW),
        .DEPTH (PIX_NUM)
    ) u_bg_ram (
        .clk   (clk),
        .we    (bg_we),
        .waddr (bg_waddr),
        .wdata (bg_wdata),
        .raddr (pix_cnt[AW-1:0]),
        .rdata (bg_q)
    );

    reg  [15:0] frame_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pix_cnt      <= 32'd0;
            x_cnt        <= {XW{1'b0}};
            y_cnt        <= {YW{1'b0}};
            frame_active <= 1'b0;
            pix_q        <= 8'd0;
            x_q          <= {XW{1'b0}};
            y_q          <= {YW{1'b0}};
            de_q         <= 1'b0;
            addr_q       <= 32'd0;
            acc_area     <= 32'd0;
            acc_x        <= 32'd0;
            acc_y        <= 32'd0;
            frame_done   <= 1'b0;
            sum_area     <= 32'd0;
            sum_x        <= 32'd0;
            sum_y        <= 32'd0;
            motion       <= 1'b0;
            diff_cnt     <= 16'd0;
            clear_cnt    <= 32'd0;
            clearing     <= 1'b0;
            frame_cnt    <= 16'd0;
        end else begin
            frame_done <= 1'b0;

            // ---------------- 背景清零 ----------------
            if (bg_clear && !clearing) begin
                clearing     <= 1'b1;
                clear_cnt    <= 32'd0;
                frame_active <= 1'b0;
            end else if (clearing) begin
                if (clear_cnt == PIX_NUM - 1) begin
                    clearing  <= 1'b0;
                    clear_cnt <= 32'd0;
                end else begin
                    clear_cnt <= clear_cnt + 32'd1;
                end
            end

            // ---------------- 像素计数的推进 ----------------
            if (pix_vs) begin
                pix_cnt      <= 32'd0;
                x_cnt        <= {XW{1'b0}};
                y_cnt        <= {YW{1'b0}};
                frame_active <= enable && !clearing;
                acc_area     <= 32'd0;
                acc_x        <= 32'd0;
                acc_y        <= 32'd0;
            end else if (pix_de && frame_active && (pix_cnt < PIX_NUM)) begin
                pix_cnt <= pix_cnt + 32'd1;
                if (x_cnt == IMG_W - 1) begin
                    x_cnt <= {XW{1'b0}};
                    y_cnt <= y_cnt + 1'b1;
                end else begin
                    x_cnt <= x_cnt + 1'b1;
                end
            end

            // ---------------- 与 RAM 读口对齐的打拍 ----------------
            pix_q  <= pix_data;
            x_q    <= x_cnt;
            y_q    <= y_cnt;
            de_q   <= (pix_de && frame_active && (pix_cnt < PIX_NUM));
            addr_q <= pix_cnt;

            // ---------------- 掩码累加 ----------------
            if (de_q) begin
                if (mask) begin
                    acc_area <= acc_area + 32'd1;
                    acc_x    <= acc_x + {{(32-XW){1'b0}}, x_q};
                    acc_y    <= acc_y + {{(32-YW){1'b0}}, y_q};
                end
            end

            // ---------------- 帧结束 ----------------
            if (frame_active && de_q && (addr_q == PIX_NUM - 1)) begin
                frame_active <= 1'b0;
                frame_done   <= 1'b1;
                frame_cnt    <= frame_cnt + 16'd1;
                sum_area     <= acc_area;
                sum_x        <= acc_x;
                sum_y        <= acc_y;
                motion       <= (acc_area >= {16'd0, min_area});
                diff_cnt     <= acc_area[15:0];
            end
        end
    end

endmodule
