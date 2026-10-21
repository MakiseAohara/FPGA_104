`timescale 1ns / 1ps
//==========================================================================
//  v7_pwr_ctl.v — 低功耗场景管理（赛题任务3 ⑤，无 SoC 的 v7 线最小实现）
//  无人（无运动且无红外热点）连续 IDLE_FRAMES 个视频帧 → LOW 模式：
//      视觉处理只在每 DIV 帧中取 1 帧（视觉处理帧率降为 1/DIV）；
//      温湿度、红外监测保持不变（"保留温度监测"）。
//  任一处理帧检出运动 或 红外热点 → 立即回到 ACTIVE（每帧都处理）。
//  诚实说明：这里降低的是"视觉处理帧率"，不是摄像头传感器的输出帧率；
//            v7 线没有神经网络，所以没有"关闭神经网络推理"可做（合并 SoC 后可做）。
//==========================================================================
module v7_pwr_ctl #(parameter IDLE_FRAMES = 900, parameter DIV = 4)(
    input  wire clk, rst_n,
    input  wire vs_rise,        // 每个视频帧一个单拍脉冲
    input  wire human,          // 有人证据：运动 或 红外热点
    output reg  low_pwr,
    output wire proc_vs         // 送给帧差的帧起始脉冲（LOW 时被抽稀）
);
    reg [15:0] idle; reg [2:0] ph;
    assign proc_vs = vs_rise & (~low_pwr | (ph == 3'd0));
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin idle <= 0; ph <= 0; low_pwr <= 1'b0; end
        else if (vs_rise) begin
            ph <= (ph == DIV-1) ? 3'd0 : ph + 3'd1;
            if (human) begin idle <= 0; low_pwr <= 1'b0; end
            else if (!low_pwr) begin
                if (idle >= IDLE_FRAMES) low_pwr <= 1'b1; else idle <= idle + 16'd1;
            end
        end
    end
endmodule
