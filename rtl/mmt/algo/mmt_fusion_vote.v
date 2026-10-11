//==========================================================================
//  mmt_fusion_vote.v  —  多模态加权投票融合决策 + 事件判定
//--------------------------------------------------------------------------
//  赛题任务2 原文：「多模态融合策略：加权投票法 —— 视觉置信度 60% + 温度置信度 25%
//  + 环境置信度 15%，综合得分超过阈值触发事件」
//  赛题任务2 场景三之三：「入侵检测：非授权时段人体出现 + 体温正常（排除热源干扰），触发报警」
//
//  逻辑与参数**逐条对齐**已自测通过的 Python 原型
//  工作区\02_传感器与算法原型\multimodal_fusion.py（同一套公式/阈值）：
//    vision_conf = person 概率，截到 [0,1]
//    temp_conf   = 画面内最高温落在人体区间 [30,38]°C → 1.0；
//                  超出则每偏离 10°C 置信度归零 → max(0, 1 - d/10)
//    env_conf    = 环境温度在 [10,35]°C 且湿度在 [20,80]% → 1.0，否则 0.5；无数据 → 0
//    score       = 0.60*v + 0.25*t + 0.15*e
//    alarm       = (score >= 阈值) && 处于非授权时段
//
//  ── 定点约定（全部 Q8，即 1.0 = 256）──────────────────────────────────
//    权重用整数 154 / 64 / 38 —— 恰好合计 256，右移 8 位即得加权和，
//    不需要除法器：score = (v*154 + t*64 + e*38) >> 8
//    （0.60*256=153.6→154，0.25*256=64，0.15*256=38.4→38，权重误差 <0.2%）
//
//    temp_conf 的衰减：精确式是 256 − (d*256)/100。
//    这里用 256 − ((d*41)>>4) 近似，41/16 = 2.5625 ≈ 2.56，误差 <0.1%，
//    只用一个乘法 + 移位，省掉除法器。
//
//  ── 与 Python 原型的已知差异（如实标注）────────────────────────────
//    原型用浮点；RTL 用 Q8 定点。阈值比较处可能有 ±1 LSB（≈0.4%）的边界抖动。
//    在 0.60 阈值附近 ±0.004 内的得分，两边结论可能不一致 —— 这是定点化的固有代价。
//==========================================================================
`timescale 1ns / 1ps

module mmt_fusion_vote (
    input  wire        clk,
    input  wire        rst_n,

    // ---- 视觉（来自 TinyML 人检的二分类概率）----
    input  wire [7:0]  vision_prob,      // Q8，0..255 表示 0.0..1.0
    input  wire        vision_valid,

    // ---- 红外（MLX90640，RISC-V 算完后写进来的"画面内最高体温"）----
    input  wire signed [15:0] body_max_c_x10,   // 0.1°C 为单位，如 352 = 35.2°C
    input  wire        ir_valid,

    // ---- 环境（SHT30）----
    input  wire signed [15:0] ambient_c_x10,    // 0.1°C
    input  wire [15:0] rh_x100,                 // 0.01% 为单位，如 5200 = 52.00%
    input  wire        env_valid,

    // ---- 时间（RISC-V 维护的实时时钟，只要小时）----
    input  wire [4:0]  hour,                    // 0..23

    // ---- 可配置（映射到寄存器/软核变量）----
    input  wire [7:0]  score_thresh,            // Q8 阈值，默认 154 = 0.60
    input  wire [4:0]  auth_start_h,            // 非授权时段起点，默认 22
    input  wire [4:0]  auth_end_h,              // 非授权时段终点，默认 6

    // ---- 结果 ----
    output reg  [7:0]  conf_vision,             // Q8
    output reg  [7:0]  conf_temp,               // Q8
    output reg  [7:0]  conf_env,                // Q8
    output reg  [8:0]  score,                   // Q8 综合得分（0..256）
    output reg         in_auth_window,          // 当前是否非授权时段
    output reg         alarm,                   // 最终报警：得分过阈 且 在非授权时段
    output reg         alarm_valid              // 评估完成的脉冲
);

    //----------------------------------------------------------------------
    // 1. 视觉置信度：直接取概率（原型里的 clamp 在 [0,1]，8bit 天然满足）
    //----------------------------------------------------------------------
    always @(*) begin
        conf_vision = vision_valid ? vision_prob : 8'd0;
    end

    //----------------------------------------------------------------------
    // 2. 温度置信度（"排除热源干扰"的判据所在）
    //    区间内 → 256；超出 → 256 − ((d*41)>>4)；d 达到 100(即 10.0°C) 时归零
    //----------------------------------------------------------------------
    localparam signed [15:0] BODY_MIN = 16'sd300;   // 30.0°C
    localparam signed [15:0] BODY_MAX = 16'sd380;   // 38.0°C

    reg  [15:0] t_dev;        // 偏离量 d，0.1°C 单位
    wire        t_in_band = (body_max_c_x10 >= BODY_MIN) && (body_max_c_x10 <= BODY_MAX);

    always @(*) begin
        if (body_max_c_x10 < BODY_MIN)      t_dev = BODY_MIN - body_max_c_x10;
        else if (body_max_c_x10 > BODY_MAX) t_dev = body_max_c_x10 - BODY_MAX;
        else                                t_dev = 16'd0;
    end

    wire [23:0] t_mul  = t_dev * 16'd41;            // 最大 1000*41 = 41000，24 位足够
    wire [7:0]  t_conf_calc = (t_dev >= 16'd100) ? 8'd0
                                                 : (8'd255 - t_mul[19:4]);   // 256−… ，用 255 防止下溢

    always @(*) begin
        if (!ir_valid)           conf_temp = 8'd0;
        else if (t_in_band)      conf_temp = 8'd255;   // 1.0（用 255 而非 256，8bit 装不下 256）
        else                     conf_temp = t_conf_calc;
    end

    //----------------------------------------------------------------------
    // 3. 环境置信度：温湿度都在舒适区间 → 1.0；否则 0.5；无数据 → 0
    //----------------------------------------------------------------------
    localparam signed [15:0] ENV_T_MIN = 16'sd100;   // 10.0°C
    localparam signed [15:0] ENV_T_MAX = 16'sd350;   // 35.0°C
    wire env_t_ok = (ambient_c_x10 >= ENV_T_MIN) && (ambient_c_x10 <= ENV_T_MAX);
    wire env_h_ok = (rh_x100 >= 16'd2000) && (rh_x100 <= 16'd8000);

    always @(*) begin
        if (!env_valid)                 conf_env = 8'd0;
        else if (env_t_ok && env_h_ok)  conf_env = 8'd255;   // 1.0
        else                            conf_env = 8'd128;   // 0.5
    end

    //----------------------------------------------------------------------
    // 4. 加权投票：权重 154/64/38（合计 256），右移 8 位
    //----------------------------------------------------------------------
    wire [31:0] wsum = conf_vision * 16'd154
                     + conf_temp   * 16'd64
                     + conf_env    * 16'd38;

    always @(*) begin
        score = wsum[16:8];          // >>8，最大 256 需要 9 位
    end

    //----------------------------------------------------------------------
    // 5. 非授权时段判定（跨零点：22:00 ~ 次日 06:00）
    //----------------------------------------------------------------------
    always @(*) begin
        if (auth_start_h <= auth_end_h)         // 同日区间
            in_auth_window = (hour >= auth_start_h) && (hour < auth_end_h);
        else                                    // 跨零点
            in_auth_window = (hour >= auth_start_h) || (hour < auth_end_h);
    end

    //----------------------------------------------------------------------
    // 6. 报警判定（打分 + 时段），打一拍输出
    //----------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            alarm       <= 1'b0;
            alarm_valid <= 1'b0;
        end else begin
            alarm_valid <= 1'b0;
            // 每拍评估一次；上层只要在数据更新后读 alarm 即可
            alarm       <= (score >= {1'b0, score_thresh}) && in_auth_window;
            alarm_valid <= 1'b1;
        end
    end

endmodule
