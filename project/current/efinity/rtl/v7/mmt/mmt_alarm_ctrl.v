//==========================================================================
//  mmt_alarm_ctrl.v  —  本地报警输出（LED 闪烁 + 蜂鸣器）
//--------------------------------------------------------------------------
//  赛题任务2 原文：「本地报警与显示：检测到异常事件时，通过 LED 闪烁 + 蜂鸣器报警
//  + HDMI 画面红色边框提示 + 显示事件类型和置信度」
//
//  本模块负责其中的 **LED 闪烁 + 蜂鸣器** 两路；HDMI 红框与文字由 OSD 模块负责
//  （见 rtl\mmt\osd\）；"事件类型和置信度" 由本模块一并输出给 OSD/软核。
//
//  行为设计：
//    - 报警期间：LED 以 HF_BLINK_HZ（默认 2Hz）闪烁；蜂鸣器输出 BUZZ_HZ（默认 2kHz）
//      方波，并用"断续"方式（响 0.5s 停 0.5s）比长鸣更醒目、也更省电
//    - 未报警：LED 全灭（可选心跳灯，见 HEARTBEAT_EN），蜂鸣器静音
//    - `mute` 输入：现场可临时静音蜂鸣器（LED 仍闪），比如按下板上的 KEY
//
//  ⚠️ 蜂鸣器类型：赛题/采购清单里建议用**有源**蜂鸣器（自带振荡，给高电平就响）。
//     本模块输出的是**方波**，既能有源（当使能电平用，方波频率会被有源蜂鸣器自身
//     振荡频率覆盖，等效于通断），也能驱动无源蜂鸣器（直接给交流）。两种都兼容。
//
//  ⚠️ 引脚：板卡资料包显示板上有 4 个 LED 和 2 个 KEY，**没有蜂鸣器**，
//     需要外接（QSE 扩展口或用户 IO），拿板子后要确认具体引脚再补约束。
//==========================================================================
`timescale 1ns / 1ps

module mmt_alarm_ctrl #(
    parameter CLK_HZ         = 100_000_000,
    parameter HF_BLINK_HZ    = 2,          // LED 闪烁频率
    parameter BUZZ_HZ        = 2_000,      // 蜂鸣器方波频率
    parameter BUZZ_ON_MS     = 500,        // 蜂鸣器断续的"响"时长
    parameter BUZZ_OFF_MS    = 500,        // 断续的"停"时长
    parameter HEARTBEAT_EN   = 1           // 未报警时 LED[0] 做 1Hz 心跳
)(
    input  wire        clk,
    input  wire        rst_n,

    // ---- 决策输入（来自 mmt_fusion_vote / 软核）----
    input  wire        alarm,              // 1 = 报警中
    input  wire [2:0]  event_type,         // 事件类型编码，给 OSD/软核用
    input  wire [7:0]  confidence,         // Q8 置信度（就是 fusion 的 score）
    input  wire        mute,               // 1 = 静音蜂鸣器（LED 仍闪）

    // ---- 输出 ----
    output reg  [3:0]  led,                // 板载 4 个 LED
    output reg         buzzer,             // 蜂鸣器（方波）
    output reg  [2:0]  evt_type_out,       // 打拍后给 OSD
    output reg  [7:0]  conf_out,           // 打拍后给 OSD
    output wire        alarm_active        // 给 OSD 画红框用
);

    //----------------------------------------------------------------------
    // LED 闪烁：2Hz → 半周期 250ms
    //----------------------------------------------------------------------
    localparam integer HALF_TICKS = (CLK_HZ / (2 * HF_BLINK_HZ) < 1) ? 1 : (CLK_HZ / (2 * HF_BLINK_HZ));

    reg [31:0] blink_cnt;
    reg        blink_phase;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            blink_cnt   <= 32'd0;
            blink_phase <= 1'b0;
        end else if (blink_cnt >= HALF_TICKS[31:0] - 32'd1) begin
            blink_cnt   <= 32'd0;
            blink_phase <= ~blink_phase;
        end else begin
            blink_cnt <= blink_cnt + 32'd1;
        end
    end

    //----------------------------------------------------------------------
    // 蜂鸣器：2kHz 方波 + 500ms 响 / 500ms 停 的断续
    //----------------------------------------------------------------------
    localparam integer BUZZ_HALF = (CLK_HZ / (2 * BUZZ_HZ) < 1) ? 1 : (CLK_HZ / (2 * BUZZ_HZ));
    localparam integer ON_TICKS  = (CLK_HZ / 1000) * BUZZ_ON_MS;
    localparam integer OFF_TICKS = (CLK_HZ / 1000) * BUZZ_OFF_MS;

    reg [31:0] buzz_cnt;      // 方波半周期计数
    reg        buzz_phase;
    reg [31:0] gate_cnt;      // 断续计数
    reg        gate_on;       // 当前处于"响"的区间

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            buzz_cnt   <= 32'd0;
            buzz_phase <= 1'b0;
            gate_cnt   <= 32'd0;
            gate_on    <= 1'b1;
        end else begin
            // 方波
            if (buzz_cnt >= BUZZ_HALF[31:0] - 32'd1) begin
                buzz_cnt   <= 32'd0;
                buzz_phase <= ~buzz_phase;
            end else begin
                buzz_cnt <= buzz_cnt + 32'd1;
            end

            // 断续闸门
            if (gate_on) begin
                if (gate_cnt >= ON_TICKS[31:0] - 32'd1) begin
                    gate_cnt <= 32'd0;
                    gate_on  <= 1'b0;
                end else begin
                    gate_cnt <= gate_cnt + 32'd1;
                end
            end else begin
                if (gate_cnt >= OFF_TICKS[31:0] - 32'd1) begin
                    gate_cnt <= 32'd0;
                    gate_on  <= 1'b1;
                end else begin
                    gate_cnt <= gate_cnt + 32'd1;
                end
            end
        end
    end

    //----------------------------------------------------------------------
    // 输出组合
    //----------------------------------------------------------------------
    // 未报警时的心跳灯：1Hz，用 blink_phase 再分频一次（2Hz 的相位翻转两次 = 1Hz）
    reg hb_div;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) hb_div <= 1'b0;
        else if (blink_cnt == 32'd0 && blink_phase) hb_div <= ~hb_div;
    end

    always @(*) begin
        if (alarm) begin
            // 报警：4 个 LED 一起闪烁（红框由 OSD 画）
            led    = blink_phase ? 4'b1111 : 4'b0000;
            buzzer = (gate_on && !mute) ? buzz_phase : 1'b0;
        end else begin
            led    = HEARTBEAT_EN ? {3'b000, hb_div} : 4'b0000;
            buzzer = 1'b0;
        end
    end

    //----------------------------------------------------------------------
    // 事件类型/置信度打拍，给 OSD 用
    //----------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            evt_type_out <= 3'd0;
            conf_out     <= 8'd0;
        end else begin
            evt_type_out <= event_type;
            conf_out     <= confidence;
        end
    end

    assign alarm_active = alarm;

endmodule
