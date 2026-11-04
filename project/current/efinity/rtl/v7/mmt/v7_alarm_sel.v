`timescale 1ns / 1ps
//==========================================================================
// v7_alarm_sel.v — MERGE11: 报警路径选择（② RISC-V 决策控制的执行点）
//
//   fw_decision_enable = 0（复位默认）：
//       alarm_final = rtl_alarm                       ← 与 MERGE10 完全一致
//   fw_decision_enable = 1：
//       alarm_final = rtl_alarm & fw_alarm_req        ← 最终报警 = 固件决策结果
//                                                       与现有 RTL 门控相与
//
//   两个输入均来自 APB（word15 bit0 / word14 bit0），已在顶层同步到视频时钟域。
//==========================================================================
module v7_alarm_sel (
    input  wire rtl_alarm,           // 现有 RTL 报警（融合门限 + 运动/红外门控 + 保持）
    input  wire fw_decision_enable,  // APB word15 bit0
    input  wire fw_alarm_req,        // APB word14 bit0（固件决策结果）
    output wire alarm_final
);

    assign alarm_final = fw_decision_enable ? (rtl_alarm & fw_alarm_req) : rtl_alarm;

endmodule
