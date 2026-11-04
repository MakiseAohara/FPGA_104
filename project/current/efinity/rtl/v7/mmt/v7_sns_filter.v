`timescale 1ns / 1ps
//==========================================================================
//  v7_sns_filter.v — 任务1 预处理：滑动平均滤波 + 异常值剔除
//  每来一个有效样本 (valid)：
//    1) 窗口里已有 >=2 个样本时，若 |x - 当前均值| > TH，视为异常值，丢弃；
//       连续丢弃 REJ_MAX 次则认为是真实阶跃，清窗口并接受（防止锁死在旧值）。
//    2) 否则写入 N=8 点环形窗口，输出 = 窗口和 >> 3（未满时按已有点数求平均）。
//  纯加减+移位，无乘除；只用寄存器，不占 BRAM/DSP。
//==========================================================================
module v7_sns_filter #(
    parameter W      = 16,      // 样本位宽（有符号）
    parameter TH     = 500,     // 异常阈值（与样本同单位；温度×100 → 5.00℃）
    parameter REJ_MAX = 3
)(
    input  wire                 clk, rst_n,
    input  wire                 valid,
    input  wire signed [W-1:0]  din,
    output reg  signed [W-1:0]  dout,
    output reg                  dout_valid,   // 至少有 1 个样本后为 1
    output reg                  rejected      // 本次样本被剔除（单拍脉冲）
);
    reg signed [W-1:0] win [0:7];
    reg [2:0] wp; reg [3:0] cnt; reg [1:0] rej;
    reg signed [W+3:0] sum;
    integer i;
    // avg = (sum * ceil(2^18/cnt)) >>> 18, no divider; 2-stage pipeline (valid spacing >> 3 clk)
    reg [18:0] recip;
    always @* case (cnt)
        4'd1: recip = 19'd262144; 4'd2: recip = 19'd131072; 4'd3: recip = 19'd87382;
        4'd4: recip = 19'd65536;  4'd5: recip = 19'd52429;  4'd6: recip = 19'd43691;
        4'd7: recip = 19'd37450;  4'd8: recip = 19'd32768;  default: recip = 19'd0;
    endcase
    reg signed [W+3:0] sum_q; reg [18:0] recip_q;
    reg signed [W+3+20:0] prod;
    reg signed [W+3:0] avg_c;
    always @(posedge clk) begin
        sum_q <= sum; recip_q <= recip;
        prod  <= sum_q * $signed({1'b0, recip_q});
        avg_c <= prod >>> 18;
    end
    wire signed [W+4:0] diff = din - avg_c;
    wire [W+4:0] adiff = diff[W+4] ? -diff : diff;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wp<=0; cnt<=0; rej<=0; sum<=0; dout<=0; dout_valid<=0; rejected<=0;
            for (i=0;i<8;i=i+1) win[i] <= 0;
        end else begin
            rejected <= 1'b0;
            if (valid) begin
                if (cnt >= 4'd2 && adiff > TH && rej < REJ_MAX) begin
                    rej <= rej + 1'b1; rejected <= 1'b1;               // 异常值：丢弃
                end else begin
                    if (cnt >= 4'd2 && adiff > TH) begin               // 连续异常 → 真实阶跃：重置窗口
                        for (i=0;i<8;i=i+1) win[i] <= din;
                        sum <= {{4{din[W-1]}}, din} <<< 3; cnt <= 4'd8; wp <= 0; rej <= 0; dout <= din;
                    end else begin
                        rej <= 0;
                        sum <= sum + {{4{din[W-1]}}, din} - ((cnt == 4'd8) ? {{4{win[wp][W-1]}}, win[wp]} : 0);
                        win[wp] <= din; wp <= wp + 1'b1;
                        if (cnt != 4'd8) cnt <= cnt + 1'b1;
                        // 输出：用更新后的均值（组合结果下一拍稳定，这里取近似：先出原样本，下一次 valid 前由 avg 刷新）
                    end
                    dout_valid <= 1'b1;
                end
            end
            // 输出始终跟随当前均值（每拍刷新，一拍延迟）
            if (cnt != 0) dout <= avg_c[W-1:0];
        end
    end
endmodule
