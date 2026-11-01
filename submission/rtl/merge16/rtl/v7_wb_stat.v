`timescale 1ns / 1ps
//==========================================================================
//  v7_wb_stat.v — MERGE16：白平衡前的通道统计（画面中心 1/3 宽 × 1/3 高）
//
//  位置：debayer 内、rgb_gain 之前（raw Bayer 域，2 像素/拍）
//  通道归属：与 MERGE15 修正后的 rgb_gain 接线一致
//      （r_gain 信号 -> 端口 gain_b -> 行 B 的 high；b_gain 信号 -> 端口 gain_r -> 行 A 的 low）
//      line_parity=0（行 A）：high(x 偶)=G, low(x 奇)=B
//      line_parity=1（行 B）：high(x 偶)=R, low(x 奇)=G
//  统计内容（每帧）：
//      sum_r/sum_g/sum_b  中心区域三通道像素和
//      pix_cnt            中心区域像素数
//      sat_cnt            任一通道 >=250 的像素数（过曝剔除用）
//  帧结束（vs 上升沿）整组锁存到 out_*，并翻转 frame_tgl 供跨时钟域读取。
//==========================================================================
module v7_wb_stat #(
    parameter H_ACTIVE = 1920,
    parameter V_ACTIVE = 1080,
    parameter SAT_TH   = 250
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        vs,
    input  wire        hs,
    input  wire        de,
    input  wire        valid,
    input  wire [15:0] data,          // 2 像素/拍：high = x 偶，low = x 奇
    input  wire        line_parity,   // 与 rgb_gain_v1 的 r_line_cnt 同源（0 = 行 A）
    // 帧内累加（调试用）
    output reg  [31:0] sum_r, sum_g, sum_b,
    output reg  [31:0] pix_cnt,
    output reg  [31:0] sat_cnt,
    // 帧结束锁存（跨域读取）
    output reg  [31:0] out_sum_r, out_sum_g, out_sum_b,
    output reg  [31:0] out_pix,
    output reg  [31:0] out_sat,
    output reg         frame_tgl
);
    localparam X0 = H_ACTIVE / 3;
    localparam X1 = (2 * H_ACTIVE) / 3;
    localparam Y0 = V_ACTIVE / 3;
    localparam Y1 = (2 * V_ACTIVE) / 3;

    reg [11:0] x_cnt;
    reg [11:0] y_cnt;
    reg        de_d, vs_d;
    wire       de_rise = de & ~de_d;
    wire       vs_rise = vs & ~vs_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_cnt <= 12'd0;
            y_cnt <= 12'hFFF;
            de_d  <= 1'b0;
            vs_d  <= 1'b0;
        end else begin
            de_d <= de;
            vs_d <= vs;
            if (vs_rise) begin
                x_cnt <= 12'd0;
                y_cnt <= 12'hFFF;
            end else if (de_rise) begin
                x_cnt <= 12'd0;
                y_cnt <= y_cnt + 12'd1;
            end else if (de) begin
                x_cnt <= x_cnt + 12'd2;
            end
        end
    end

    // 中心区域判定（每拍覆盖 x_cnt 与 x_cnt+1 两个像素）
    wire y_in  = (y_cnt >= Y0) && (y_cnt < Y1);
    wire x0_in = (x_cnt >= X0) && (x_cnt < X1);                        // high：x 偶
    wire x1_in = ((x_cnt + 12'd1) >= X0) && ((x_cnt + 12'd1) < X1);    // low ：x 奇
    wire use_hi = de & valid & y_in & x0_in;
    wire use_lo = de & valid & y_in & x1_in;

    wire [7:0] pix_hi = data[15:8];
    wire [7:0] pix_lo = data[7:0];
    wire [1:0] pix_inc = {1'b0, use_hi} + {1'b0, use_lo};
    wire [1:0] sat_inc = {1'b0, (use_hi && (pix_hi >= SAT_TH))} + {1'b0, (use_lo && (pix_lo >= SAT_TH))};

    // 通道归属（MERGE15 修正后的实际接线）
    wire hi_is_g = (line_parity == 1'b0);   // 行 A：high = G
    wire lo_is_g = (line_parity == 1'b1);   // 行 B：low  = G
    // 行 A 的 low = B；行 B 的 high = R

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sum_r <= 32'd0; sum_g <= 32'd0; sum_b <= 32'd0;
            pix_cnt <= 32'd0; sat_cnt <= 32'd0;
            out_sum_r <= 32'd0; out_sum_g <= 32'd0; out_sum_b <= 32'd0;
            out_pix <= 32'd0; out_sat <= 32'd0; frame_tgl <= 1'b0;
        end else if (vs_rise) begin
            out_sum_r <= sum_r; out_sum_g <= sum_g; out_sum_b <= sum_b;
            out_pix   <= pix_cnt; out_sat <= sat_cnt;
            frame_tgl <= ~frame_tgl;
            sum_r <= 32'd0; sum_g <= 32'd0; sum_b <= 32'd0;
            pix_cnt <= 32'd0; sat_cnt <= 32'd0;
        end else begin
            // 同一拍可能同时用到 high/low：计数用"增量相加"，避免两次非阻塞赋值互相覆盖
            if (use_hi) begin
                if (hi_is_g) sum_g <= sum_g + {24'd0, pix_hi};
                else         sum_r <= sum_r + {24'd0, pix_hi};   // 行 B high = R
            end
            if (use_lo) begin
                if (lo_is_g) sum_g <= sum_g + {24'd0, pix_lo};
                else         sum_b <= sum_b + {24'd0, pix_lo};   // 行 A low = B
            end
            if (use_hi || use_lo) begin
                pix_cnt <= pix_cnt + {30'd0, pix_inc};
                sat_cnt <= sat_cnt + {30'd0, sat_inc};
            end
        end
    end
endmodule
