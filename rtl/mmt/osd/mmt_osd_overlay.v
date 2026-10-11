//==========================================================================
//  mmt_osd_overlay.v  —  显示叠加（OSD）：温度热力图小窗 + 参数文字 + 报警红框
//--------------------------------------------------------------------------
//  赛题任务1 原文：「通过 HDMI/LCD 显示各传感器实时数据（视频画面 + 温度热力图
//                    + 环境参数叠加显示）」
//  技术要点原文：「显示叠加：在 HDMI 画面上分区域显示 —— 主区域视频画面、
//                  侧边温度热力图小窗、底部环境参数文字」
//  赛题任务2 原文：「HDMI 画面红色边框提示 + 显示事件类型和置信度」
//
//  => 本模块把上面三条一次做齐，画面分三块：
//       ┌──────────────────────────────┬──────────┐
//       │                              │ 温度热力图 │  ← 32×24 MLX90640 放大 8 倍
//       │        主区域视频画面          │   小窗    │     放在右上角
//       │      （原样透传，不处理）      │ 256×192  │
//       │                              └──────────┘
//       │  T=25.3C RH=48.2% ENV=24.5C            │  ← 底部三行文字（软核格式化后写进来）
//       │  IR=35.2C MOTION=1 AREA=1234           │
//       │  EVT=INTRUDE CONF=0.92                 │
//       └────────────────────────────────────────┘
//        报警时整屏加一圈 8 像素红框（任务2 要求）
//
//  ── 数据从哪来 ────────────────────────────────────────────────────────
//   · 文字：软核把格式化好的 ASCII 写进 txt_ram（3 行 × 48 字符 = 144 字节），
//           本模块从字模 ROM 取点阵渲染。**文字内容完全由软核决定**，
//           所以改显示内容不用动 RTL。
//   · 热力图：软核把 32×24 个像素的色阶值（0..255）写进 th_ram（768 字节）。
//           逐点温度仍是软核算的（要跑 Melexis 官方库）。
//   · 报警：来自融合模块的 alarm，以及软核给的事件类型/置信度（用于第三行文字，
//           但第三行文字本身也是软核写的，这里只用 alarm 画红框）。
//
//  ── 流水线 ───────────────────────────────────────────────────────────
//  读 RAM / 读字模都有延迟，所以整个叠加做了 **4 级流水**：
//      S0 算坐标与区域判定  → S1 发起 txt_ram / th_ram 读
//      → S2 拿到字符码，发起字模读 → S3 拿到字模字节，输出像素
//  原始 de/hs/vs 与 x/y 随之打 4 拍，保证像素对齐。
//
//  ── 字模 ─────────────────────────────────────────────────────────────
//  8×16 点阵，覆盖 ASCII 32..126（95 个字符），共 1520 字节，
//  由 `工作区\_工具\gen_font.py` 从系统等宽字体渲染生成，$readmemh 载入。
//  ⚠️ 这也是为什么整个工程必须放在纯 ASCII 路径下（$readmemh 的相对路径
//     在中文路径下会被 Verific 转成乱码打不开）。
//==========================================================================
`timescale 1ns / 1ps

module mmt_osd_overlay #(
    parameter H_ACTIVE   = 1920,
    parameter V_ACTIVE   = 1080,
    parameter XW         = 11,          // x 坐标位宽（0..1919）
    parameter YW         = 11,          // y 坐标位宽（0..1079）
    // ---- 温度热力图小窗 ----
    parameter TH_SCALE   = 8,           // 每个温度像素放大倍数
    parameter TH_X0      = 1632,        // 窗口左上角 x（右侧留 32 边距）
    parameter TH_Y0      = 32,
    // ---- 文字 ----
    parameter FONT_W     = 8,
    parameter FONT_H     = 16,
    parameter TXT_SCALE  = 2,           // 文字放大倍数 → 字符格 16×32
    parameter TXT_COLS   = 48,          // 每行字符数
    parameter TXT_LINES  = 3,
    parameter TXT_X0     = 40,
    parameter TXT_Y0     = 960,         // 第一行左上角 y
    parameter BORDER     = 8            // 报警红框厚度
)(
    input  wire        vclk,            // 视频像素时钟（与输入像素流同域）
    input  wire        vrst_n,

    // ---- 输入：原始视频（来自 HDMI 通路，active high 时序）----
    input  wire [7:0]  i_r,
    input  wire [7:0]  i_g,
    input  wire [7:0]  i_b,
    input  wire        i_de,
    input  wire        i_hs,
    input  wire        i_vs,

    // ---- 输出：叠加后的视频（比输入晚 4 拍）----
    output reg  [7:0]  o_r,
    output reg  [7:0]  o_g,
    output reg  [7:0]  o_b,
    output reg         o_de,
    output reg         o_hs,
    output reg         o_vs,

    // ---- 热力图数据（软核写好的 32×24 色阶）----
    output wire [9:0]  th_rd_addr,
    input  wire [7:0]  th_rd_data,

    // ---- 文字数据（软核格式化好的 ASCII）----
    output wire [7:0]  txt_rd_addr,
    input  wire [7:0]  txt_rd_data,

    // ---- 报警（只用来画红框）----
    input  wire        alarm
);

    //====================================================================
    // 字模 ROM：8×16 × 95 字符 = 1520 字节
    //====================================================================
    reg [7:0] font_rom [0:1519];
    initial begin
        $readmemh("font8x16.hex", font_rom);
    end

    //====================================================================
    // 视频坐标提取（de 上升沿 = 新行，vs 上升沿 = 新帧）
    //====================================================================
    reg [XW-1:0] x_cnt;
    reg [YW-1:0] y_cnt;
    reg          de_d, vs_d;
    reg          in_frame;

    wire vs_rise   = i_vs & ~vs_d;
    wire de_rise   = i_de & ~de_d;

    // y 用 -1 起始技巧：vs 时置为全 1，第一次 de 上升沿加 1 得 0
    always @(posedge vclk or negedge vrst_n) begin
        if (!vrst_n) begin
            x_cnt    <= {XW{1'b0}};
            y_cnt    <= {YW{1'b1}};      // -1
            de_d     <= 1'b0;
            vs_d     <= 1'b0;
            in_frame <= 1'b0;
        end else begin
            de_d <= i_de;
            vs_d <= i_vs;

            if (vs_rise) begin
                y_cnt    <= {YW{1'b1}};
                x_cnt    <= {XW{1'b0}};
                in_frame <= 1'b1;
            end else if (de_rise && in_frame) begin
                x_cnt <= {XW{1'b0}};
                y_cnt <= y_cnt + 1'b1;
            end else if (i_de && in_frame) begin
                x_cnt <= x_cnt + 1'b1;
            end
        end
    end

    //====================================================================
    // S0：区域判定
    //====================================================================
    // 热力图窗口范围
    localparam TH_W = 32 * TH_SCALE;
    localparam TH_H = 24 * TH_SCALE;

    wire in_therm = (x_cnt >= TH_X0) && (x_cnt < TH_X0 + TH_W) &&
                    (y_cnt >= TH_Y0) && (y_cnt < TH_Y0 + TH_H);

    // 文字区域
    localparam TXT_W = TXT_COLS * FONT_W * TXT_SCALE;
    localparam TXT_H = TXT_LINES * FONT_H * TXT_SCALE;

    wire in_text = (x_cnt >= TXT_X0) && (x_cnt < TXT_X0 + TXT_W) &&
                   (y_cnt >= TXT_Y0) && (y_cnt < TXT_Y0 + TXT_H);

    // 报警红框
    wire in_border = (x_cnt < BORDER) || (x_cnt >= H_ACTIVE - BORDER) ||
                     (y_cnt < BORDER) || (y_cnt >= V_ACTIVE - BORDER);

    wire show_border = alarm & in_border;

    // ---- 热力图源坐标 ----
    wire [XW-1:0] th_sx = (x_cnt - TH_X0) >> 3;   // /TH_SCALE，TH_SCALE=8
    wire [YW-1:0] th_sy = (y_cnt - TH_Y0) >> 3;
    wire [9:0]    th_addr = {th_sy[4:0], th_sx[4:0]};   // 32×24 → 10 位

    // ---- 文字源坐标 ----
    wire [XW-1:0] tx = x_cnt - TXT_X0;
    wire [YW-1:0] ty = y_cnt - TXT_Y0;
    wire [5:0]    txt_col  = tx / (FONT_W * TXT_SCALE);          // 列号 0..47
    wire [5:0]    txt_line = ty / (FONT_H * TXT_SCALE);          // 行号 0..2
    wire [3:0]    font_row = ty[4:1];                            // 行内像素（16 行 / 放大2 = [4:1]）
    wire [2:0]    font_col = tx[3:1];                            // 列内像素（8 列 / 放大2 = [3:1]）
    wire [7:0]    txt_addr = {txt_line, txt_col};                // 3×48 → 用 8 位地址（行在高位）

    // 这些在 S0 拍有效，需随流水一起打拍
    assign th_rd_addr  = th_addr;
    assign txt_rd_addr = txt_addr;

    //====================================================================
    // 4 级流水
    //====================================================================
    // S1：热力图数据 / 字符码返回
    reg [7:0] s1_th_data;
    reg [7:0] s1_txt_char;
    reg [3:0] s1_font_row;
    reg [2:0] s1_font_col;
    reg       s1_in_text, s1_show_border;
    reg [7:0] s1_r, s1_g, s1_b;
    reg       s1_de, s1_hs, s1_vs;

    // S2：字模数据返回
    reg       s2_font_bit;
    reg [7:0] s2_th_data;
    reg       s2_in_text, s2_show_border;
    reg [7:0] s2_r, s2_g, s2_b;
    reg       s2_de, s2_hs, s2_vs;

    // S3：输出
    always @(posedge vclk or negedge vrst_n) begin
        if (!vrst_n) begin
            s1_th_data <= 8'd0; s1_txt_char <= 8'd0;
            s1_font_row <= 4'd0; s1_font_col <= 3'd0;
            s1_in_text <= 1'b0; s1_show_border <= 1'b0;
            s1_r <= 8'd0; s1_g <= 8'd0; s1_b <= 8'd0;
            s1_de <= 1'b0; s1_hs <= 1'b0; s1_vs <= 1'b0;
        end else begin
            s1_th_data      <= th_rd_data;
            s1_txt_char     <= txt_rd_data;
            s1_font_row     <= font_row;
            s1_font_col     <= font_col;
            s1_in_text      <= in_text;
            s1_show_border  <= show_border;
            s1_r            <= i_r;
            s1_g            <= i_g;
            s1_b            <= i_b;
            s1_de           <= i_de;
            s1_hs           <= i_hs;
            s1_vs           <= i_vs;
        end
    end

    // S2：把字符码换成字模地址，读出点阵字节
    // 字符码 < 32 或 > 126 时按空格处理，避免地址越界
    wire [7:0] ch = (s1_txt_char >= 8'd32 && s1_txt_char <= 8'd126) ? (s1_txt_char - 8'd32) : 8'd0;
    wire [10:0] font_addr = {ch, s1_font_row};      // ch*16 + row  → 最大 94*16+15 = 1519 ✓
    reg  [7:0]  font_byte;
    always @(posedge vclk) font_byte <= font_rom[font_addr];

    wire s2_font_bit_w = font_byte[3'd7 - s1_font_col];   // bit7 = 最左

    always @(posedge vclk or negedge vrst_n) begin
        if (!vrst_n) begin
            s2_font_bit <= 1'b0; s2_th_data <= 8'd0;
            s2_in_text <= 1'b0; s2_show_border <= 1'b0;
            s2_r <= 8'd0; s2_g <= 8'd0; s2_b <= 8'd0;
            s2_de <= 1'b0; s2_hs <= 1'b0; s2_vs <= 1'b0;
        end else begin
            s2_font_bit    <= s2_font_bit_w;
            s2_th_data     <= s1_th_data;
            s2_in_text     <= s1_in_text;
            s2_show_border <= s1_show_border;
            s2_r           <= s1_r;
            s2_g           <= s1_g;
            s2_b           <= s1_b;
            s2_de          <= s1_de;
            s2_hs          <= s1_hs;
            s2_vs          <= s1_vs;
        end
    end

    //====================================================================
    // 热力图伪彩色映射：0..85 黑→红，86..170 红→黄，171..255 黄→白
    // （经典 heat 渐变；用比较 + 移位实现，不用乘法器/查表）
    //====================================================================
    reg [7:0] heat_r, heat_g, heat_b;
    always @(*) begin
        if (s2_th_data < 8'd86) begin
            heat_r = s2_th_data * 3;            // 0 → 255
            heat_g = 8'd0;
            heat_b = 8'd0;
        end else if (s2_th_data < 8'd171) begin
            heat_r = 8'd255;
            heat_g = (s2_th_data - 8'd86) * 3;  // 0 → 255
            heat_b = 8'd0;
        end else begin
            heat_r = 8'd255;
            heat_g = 8'd255;
            heat_b = (s2_th_data - 8'd171) * 3; // 0 → 252
        end
    end

    //====================================================================
    // S3：合成最终像素
    // 优先级：报警红框 > 文字 > 热力图 > 原始视频
    //====================================================================
    always @(posedge vclk or negedge vrst_n) begin
        if (!vrst_n) begin
            o_r <= 8'd0; o_g <= 8'd0; o_b <= 8'd0;
            o_de <= 1'b0; o_hs <= 1'b0; o_vs <= 1'b0;
        end else begin
            o_de <= s2_de;
            o_hs <= s2_hs;
            o_vs <= s2_vs;

            if (s2_show_border) begin
                // 报警红框
                o_r <= 8'hFF; o_g <= 8'h00; o_b <= 8'h00;
            end else if (s2_in_text) begin
                // 文字：点阵为 1 处画亮绿，其余透出原视频（半透明效果靠这个实现）
                if (s2_font_bit) begin
                    o_r <= 8'h00; o_g <= 8'hFF; o_b <= 8'h00;
                end else begin
                    // 文字区背景压暗，让字更清楚
                    o_r <= {1'b0, s2_r[7:1]};
                    o_g <= {1'b0, s2_g[7:1]};
                    o_b <= {1'b0, s2_b[7:1]};
                end
            end else if (s2_th_data != 8'd0) begin
                // 热力图窗口内（色阶为 0 的像素透出原视频，避免一个大黑块挡住画面）
                o_r <= heat_r; o_g <= heat_g; o_b <= heat_b;
            end else begin
                // 主区域视频原样透传
                o_r <= s2_r; o_g <= s2_g; o_b <= s2_b;
            end
        end
    end

endmodule
