`timescale 1ns / 1ps
//==========================================================================
//  v7_ts_align.v — 任务1 多传感器时间戳对齐（以视频帧为主时间基准）
//  frame_cnt 每个视频帧 +1（vs 上升沿）。每个传感器新样本到来时锁存当时的帧号（时间戳）。
//  age = frame_cnt - stamp（以帧为单位，饱和）。决策使用"最近样本保持 + 年龄门限"：
//    样本年龄 <= MAX_AGE_x 才视为"与当前视频帧对齐"，否则该模态置信度应归零。
//  输出 aligned_* 给融合门控，age_* 给 OSD 显示。
//==========================================================================
module v7_ts_align #(
    parameter MAX_AGE_SHT = 120,   // 帧（~2 s @60Hz；SHT30 周期 1 s）
    parameter MAX_AGE_IR  = 60     // 帧（~1 s；MLX90640 周期 0.5 s）
)(
    input  wire        clk, rst_n,
    input  wire        vs_rise,        // 视频帧边沿（主时间基准）
    input  wire        sht_new, ir_new,// 新样本脉冲
    output reg  [15:0] frame_cnt,
    output reg  [15:0] age_sht, age_ir,
    output wire        aligned_sht, aligned_ir
);
    reg [15:0] ts_sht, ts_ir; reg seen_sht, seen_ir;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin frame_cnt<=0; ts_sht<=0; ts_ir<=0; seen_sht<=0; seen_ir<=0; age_sht<=16'hFFFF; age_ir<=16'hFFFF; end
        else begin
            if (vs_rise) frame_cnt <= frame_cnt + 1'b1;
            if (sht_new) begin ts_sht <= frame_cnt; seen_sht <= 1'b1; end
            if (ir_new)  begin ts_ir  <= frame_cnt; seen_ir  <= 1'b1; end
            age_sht <= seen_sht ? (frame_cnt - ts_sht) : 16'hFFFF;
            age_ir  <= seen_ir  ? (frame_cnt - ts_ir)  : 16'hFFFF;
        end
    end
    assign aligned_sht = seen_sht && (age_sht <= MAX_AGE_SHT);
    assign aligned_ir  = seen_ir  && (age_ir  <= MAX_AGE_IR);
endmodule
