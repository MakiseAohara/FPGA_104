`timescale 1ns / 1ps
//==========================================================================
//  v7_freeze_ctl.v — 视觉背景冻结控制（防"永久误判运动"死锁）
//  原设计：有运动就冻结背景。若场景发生永久变化（开机曝光未稳、相机被挪动、
//  开灯），运动永远为真 → 背景永远不更新 → 永远报运动。
//  改法：连续有运动的帧数达到 FREEZE_MAX 就脉冲一次 auto_learn（背景直写重学），
//  冻结同时解除；运动消失则计数清零。
//==========================================================================
module v7_freeze_ctl #(parameter FREEZE_MAX = 600)(
    input  wire clk, rst_n,
    input  wire frame_done,
    input  wire motion,
    output reg  bg_freeze,
    output reg  auto_learn
);
    reg [15:0] cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin cnt <= 0; bg_freeze <= 1'b0; auto_learn <= 1'b0; end
        else begin
            auto_learn <= 1'b0;
            bg_freeze  <= motion && (cnt < FREEZE_MAX[15:0]);
            if (frame_done) begin
                if (!motion) cnt <= 0;
                else if (cnt >= FREEZE_MAX[15:0]) begin cnt <= 0; auto_learn <= 1'b1; end
                else cnt <= cnt + 16'd1;
            end
        end
    end
endmodule
