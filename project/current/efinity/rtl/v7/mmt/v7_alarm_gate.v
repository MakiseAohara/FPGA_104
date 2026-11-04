`timescale 1ns / 1ps
//==========================================================================
// v7_alarm_gate.v — MERGE14: 报警门控（参数化）
//   IR_GATE_MODE = 0 : alarm_raw & motion & ai_person        （默认，MERGE14）
//                = 1 : alarm_raw & motion & (ir_hot|ai_person) （MERGE13 行为）
//                = 2 : alarm_raw & motion & ir_hot
//   注意：红外仍参与 mmt_fusion_vote 的 60/25/15 融合得分（IR_IN_FUSION=1），
//         本模块只决定"门控"是否使用 ir_hot；热图/温度显示/irhot 日志不受影响。
//==========================================================================
module v7_alarm_gate #(
    parameter IR_GATE_MODE = 0,
    parameter REQUIRE_IR   = 1
)(
    input  wire alarm_raw,
    input  wire motion,
    input  wire ir_hot,
    input  wire ai_person,
    output wire alarm_gate
);
    wire ir_ok = (IR_GATE_MODE == 0) ? 1'b0 :
                 (IR_GATE_MODE == 2) ? ir_hot : (ir_hot | ai_person);
    wire ai_ok = (IR_GATE_MODE == 2) ? 1'b0 : ai_person;
    wire evid  = (REQUIRE_IR == 0) ? 1'b1 : (ir_ok | ai_ok);
    assign alarm_gate = alarm_raw & motion & evid;
endmodule
