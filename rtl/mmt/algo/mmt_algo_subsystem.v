//==========================================================================
//  mmt_algo_subsystem.v  —  算法与决策子系统（任务2 的运动分析 + 融合决策）
//--------------------------------------------------------------------------
//  把两个算法模块接成一个可独立综合/验证的整体：
//      mmt_frame_diff   帧差法运动检测（像素流 → 面积/质心/运动标志）
//      mmt_fusion_vote  60/25/15 加权投票 + 非授权时段 → 报警
//
//  数据来源说明（谁喂什么）：
//    - 像素流    ← 降采样+灰度化模块（从视频链路取 96×96 或 160×120 的小图）
//    - vision_prob ← TinyML 人检的二分类概率（RISC-V 写寄存器）
//    - body_max_c  ← MLX90640 原始帧经 RISC-V 算温度后取画面内最高值
//    - ambient/rh  ← SHT30（RISC-V 从 mmt_sensor_subsystem 读）
//    - hour        ← RISC-V 维护的实时时钟
//
//  分工理由：温度逐点计算与视觉推理都在软核侧，硬件只做"搬运 + 规则判据"，
//  这样硬件简单可靠，且算法参数可以随时由软核改写（不用重综合）。
//
//  注：frame_diff 的"运动"与 TinyML 的"有人"是两个互补证据：
//      静止的人 → 帧差法看不到，但人检能看到；
//      快速晃动 → 帧差法有反应，人检可能漏。
//  这里把两者都输出给软核/融合层，由融合层按需使用（当前 fusion 模块只用视觉概率，
//  运动标志作为独立输出保留，供后续"跌倒检测"这类需要运动类型的场景使用）。
//==========================================================================
`timescale 1ns / 1ps

module mmt_algo_subsystem #(
    parameter IMG_W = 160,
    parameter IMG_H = 120,
    parameter XW    = 8,
    parameter YW    = 8
)(
    input  wire        clk,
    input  wire        rst_n,

    // ---- 降采样灰度像素流 ----
    input  wire [7:0]  pix_data,
    input  wire        pix_de,
    input  wire        pix_vs,

    // ---- 帧差法配置 ----
    input  wire [7:0]  diff_threshold,      // 默认 25
    input  wire [15:0] diff_min_area,       // 默认 60
    input  wire        diff_enable,
    input  wire        bg_freeze,
    input  wire        bg_clear,

    // ---- 帧差法结果 ----
    output wire        motion_frame_done,
    output wire [31:0] motion_sum_area,
    output wire [31:0] motion_sum_x,
    output wire [31:0] motion_sum_y,
    output wire        motion_flag,

    // ---- 融合决策输入 ----
    input  wire [7:0]  vision_prob,
    input  wire        vision_valid,
    input  wire signed [15:0] body_max_c_x10,
    input  wire        ir_valid,
    input  wire signed [15:0] ambient_c_x10,
    input  wire [15:0] rh_x100,
    input  wire        env_valid,
    input  wire [4:0]  hour,

    // ---- 融合决策配置 ----
    input  wire [7:0]  score_thresh,
    input  wire [4:0]  auth_start_h,
    input  wire [4:0]  auth_end_h,

    // ---- 决策结果 ----
    output wire [7:0]  conf_vision,
    output wire [7:0]  conf_temp,
    output wire [7:0]  conf_env,
    output wire [8:0]  score,
    output wire        in_auth_window,
    output wire        alarm
);

    //======================================================================
    // 帧差法运动检测
    //======================================================================
    mmt_frame_diff #(
        .IMG_W    (IMG_W),
        .IMG_H    (IMG_H),
        .BG_SHIFT (5),
        .XW       (XW),
        .YW       (YW)
    ) u_frame_diff (
        .clk        (clk),
        .rst_n      (rst_n),
        .pix_data   (pix_data),
        .pix_de     (pix_de),
        .pix_vs     (pix_vs),
        .threshold  (diff_threshold),
        .min_area   (diff_min_area),
        .enable     (diff_enable),
        .bg_freeze  (bg_freeze),
        .frame_done (motion_frame_done),
        .sum_area   (motion_sum_area),
        .sum_x      (motion_sum_x),
        .sum_y      (motion_sum_y),
        .motion     (motion_flag),
        .diff_cnt   (),
        .bg_clear   (bg_clear)
    );

    //======================================================================
    // 多模态加权融合决策
    //======================================================================
    mmt_fusion_vote u_fusion (
        .clk             (clk),
        .rst_n           (rst_n),
        .vision_prob     (vision_prob),
        .vision_valid    (vision_valid),
        .body_max_c_x10  (body_max_c_x10),
        .ir_valid        (ir_valid),
        .ambient_c_x10   (ambient_c_x10),
        .rh_x100         (rh_x100),
        .env_valid       (env_valid),
        .hour            (hour),
        .score_thresh    (score_thresh),
        .auth_start_h    (auth_start_h),
        .auth_end_h      (auth_end_h),
        .conf_vision     (conf_vision),
        .conf_temp       (conf_temp),
        .conf_env        (conf_env),
        .score           (score),
        .in_auth_window  (in_auth_window),
        .alarm           (alarm),
        .alarm_valid     ()
    );

endmodule
