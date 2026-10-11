//==========================================================================
//  mmt_video_downscale.v  —  视频降采样 + 灰度化（给帧差法/AI 用的小图）
//--------------------------------------------------------------------------
//  作用：把 HDMI 那条链路上的 1920×1080 彩色视频流，抽成 **160×120 的 8bit 灰度流**，
//        喂给 mmt_frame_diff（帧差法）和以后的 AI 输入。
//
//  为什么需要它：帧差法只需要看"有没有东西在动"，用全分辨率毫无意义，
//  反而要一块 1920×1080 的背景 RAM（2 MB，不可能放进 BRAM）。
//  降到 160×120 后背景帧只有 19200 字节 ≈ 20 块 BRAM，完全可以接受。
//
//  实现：**抽取（decimation）而不是平均**——每 X_DEC 个像素取 1 个、每 Y_DEC 行取 1 行。
//        1920/160 = 12，1080/120 = 9，所以默认 X_DEC=12、Y_DEC=9。
//  为什么不平均：平均需要行缓存 + 累加器；抽取只要一个计数器和几个比较器，
//  占用极小，而帧差法对这点噪声不敏感。**这是有意的简化，不是偷懒。**
//
//  灰度公式：Y = (77·R + 150·G + 29·B) >> 8   （ITU-R BT.601 的定点近似）
//  用乘法器会吃 DSP；三个系数可以用移位加实现，但 8bit×8bit 的乘法在 Titanium 上
//  会被推断成 DSP 或 LUT，代价很小，这里直接用乘法写，让工具自己决定。
//
//  ⚠️ 输入像素格式：本模块按 **RGB888** 处理（每个通道 8bit），
//     输入的是 r/g/b 三路独立信号。若上游是 RGB565 或 YUV，需要先转换。
//     板卡包 10 号 demo 的 HDMI 通路给的是 `hdmi_tx_rdata/gdata/bdata`（各 8bit），
//     正好匹配。
//==========================================================================
`timescale 1ns / 1ps

module mmt_video_downscale #(
    parameter OUT_W = 160,            // 输出宽
    parameter OUT_H = 120,            // 输出高
    parameter X_DEC = 12,             // 水平抽取比（1920/160 = 12）
    parameter Y_DEC = 9,              // 垂直抽取比（1080/120 = 9）
    parameter XW    = 8,              // 输出 x 计数位宽
    parameter YW    = 8               // 输出 y 计数位宽
)(
    input  wire        clk,
    input  wire        rst_n,

    // ---- 输入：视频像素流（RGB888）----
    input  wire [7:0]  in_r,
    input  wire [7:0]  in_g,
    input  wire [7:0]  in_b,
    input  wire        in_de,         // 数据有效
    input  wire        in_vs,         // 帧起始（极性由上游决定，这里只做边沿检测）

    // ---- 输出：降采样灰度流（每帧恰好 OUT_W × OUT_H 个 de）----
    output reg  [7:0]  out_gray,
    output reg         out_de,
    output reg         out_vs,        // 每帧第一个像素位置给一个脉冲，给帧差法当帧起始

    // ---- 观测 ----
    output reg  [15:0] frame_cnt
);

    // 输入侧的行/列计数（用 de 计数，与 hs/vs 极性无关）
    reg [15:0] in_x;                  // 行内像素序号（0 起）
    reg [15:0] in_y;                  // 行号（0 起，按 de 换行，需要知道输入行宽）

    // 为了不依赖输入行宽参数，这里用"每 OUT_W 个输出像素算一行"的间接办法：
    // 直接用输入 x/y 计数 + 模运算更直观，但模 1920 会吃资源。
    // 折中：引入一个可配的输入行宽参数，用比较器换行（只用一个减法器）。
    // 1920 = 0x780
    localparam IN_W = 1920;
    localparam IN_H = 1080;

    reg [15:0] x_cnt;                 // 输入行内计数
    reg [15:0] y_cnt;                 // 输入行号
    reg [3:0]  x_ph;                  // 水平抽取相位
    reg [3:0]  y_ph;                  // 垂直抽取相位

    // 灰度计算（对当前输入像素）
    wire [15:0] y_sum = in_r * 16'd77 + in_g * 16'd150 + in_b * 16'd29;
    wire [7:0]  gray  = y_sum[15:8];

    // 输出侧计数
    reg [XW-1:0] out_x;
    reg [YW-1:0] out_y;

    // 帧计数器（★ 注意：不要在第二个 always 块里再给它赋值 ——
    //   我第一版写了个 `always @(posedge clk) frame_cnt_r <= frame_cnt;` 的流水块，
    //   而主块复位里也赋了 frame_cnt_r，结果综合报 VDB-1000 "constantly driven
    //   from multiple places"。这个流水寄存器本来就没必要，直接删掉。）
    reg [15:0] frame_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_cnt      <= 16'd0;
            y_cnt      <= 16'd0;
            x_ph       <= 4'd0;
            y_ph       <= 4'd0;
            out_x      <= {XW{1'b0}};
            out_y      <= {YW{1'b0}};
            out_gray   <= 8'd0;
            out_de     <= 1'b0;
            out_vs     <= 1'b0;
            frame_cnt  <= 16'd0;
        end else begin
            out_de <= 1'b0;
            out_vs <= 1'b0;

            // 帧起始：复位计数
            if (in_vs) begin
                x_cnt     <= 16'd0;
                y_cnt     <= 16'd0;
                x_ph      <= 4'd0;
                y_ph      <= 4'd0;
                out_x     <= {XW{1'b0}};
                out_y     <= {YW{1'b0}};
                frame_cnt <= frame_cnt + 16'd1;
            end else if (in_de) begin
                // 行内计数推进
                if (x_cnt == IN_W - 1) begin
                    x_cnt <= 16'd0;
                    y_cnt <= (y_cnt == IN_H - 1) ? 16'd0 : (y_cnt + 16'd1);
                    // 垂直抽取相位
                    if (y_ph == Y_DEC - 1) y_ph <= 4'd0; else y_ph <= y_ph + 4'd1;
                    out_x <= {XW{1'b0}};
                end else begin
                    x_cnt <= x_cnt + 16'd1;
                end

                // 水平抽取相位
                if (x_ph == X_DEC - 1) x_ph <= 4'd0; else x_ph <= x_ph + 4'd1;

                // 命中抽取点（x_ph 与 y_ph 都为 0）→ 输出一个灰度像素
                if ((x_ph == 4'd0) && (y_ph == 4'd0) && (out_y < OUT_H)) begin
                    out_gray <= gray;
                    out_de   <= 1'b1;
                    if ((out_x == 0) && (out_y == 0)) out_vs <= 1'b1;   // 帧首
                    if (out_x == OUT_W - 1) begin
                        out_x <= {XW{1'b0}};
                        out_y <= out_y + 1'b1;
                    end else begin
                        out_x <= out_x + 1'b1;
                    end
                end
            end
        end
    end


endmodule
