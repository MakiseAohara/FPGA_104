`timescale 1ns / 1ps
//==========================================================================
//  v7_mmt_core.v — 无 RISC-V 的"多模态感知+决策"核心（单时钟 hdmi_tx_slow_clk）
//    视觉：像素流 → 灰度降采样(160×120) → 帧差运动检测 → 面积 → vision_prob
//    红外：MLX90640 原始帧 → 基线相减 → 相对升温(热点增量) → 估算体温
//    环境：SHT30 温湿度
//    决策：mmt_fusion_vote（视觉60%+体温25%+环境15% 加权，且处于非授权时段）
//    输出：报警(含 ~1.8s 保持)、蜂鸣器、LED、OSD 文字/热力图写口
//==========================================================================
module v7_mmt_core #(
    parameter CLK_HZ        = 148_500_000,
    parameter SCL_HZ        = 100_000,
    parameter SHT_PERIOD_MS = 1000,
    parameter IR_PERIOD_MS  = 500,
    parameter HOLD_BITS     = 28,        // 报警保持 2^28/148.5M ≈ 1.8 s
    parameter DEB_BITS      = 22,        // 按键消抖 2^22/148.5M ≈ 28 ms
    parameter IR_K          = 3,         // 体温估算：Δ(0.1℃) = 升温计数*IR_K>>IR_SH（上板标定）
    parameter IR_SH         = 3,
    parameter AI_MODE       = 0,         // 1 = 视觉输入改用 SoC 的 TinyML 人体判决(ai_person)
    parameter FREEZE_MAX    = 600,       // 连续"有运动"超过此帧数（~10 s@60Hz）→ 视觉背景自动重新学习
    parameter HOT_ON        = 48,        // 红外热点阈值（原始计数，≈1.8℃，同 ir_proc FREEZE_TH）
    parameter REQUIRE_IR    = 1          // 1 = 报警必须同时看到红外热点（排除纯光照/曝光变化误报）
)(
    input  wire        clk, rst_n,
    // 视频像素流（OSD 之前，真红在 in_r）
    input  wire [7:0]  in_r, in_g, in_b,
    input  wire        in_de, in_hs, in_vs,
    // 按键（低有效）：key_night 切换 白天/夜间；key_learn 重新学习背景
    input  wire        ai_person,                // TinyML 人体判决（已同步到本时钟域；AI_MODE=0 时忽略）
    input  wire        key_night_n, key_learn_n,
    // 传感器 I2C
    input  wire        scl_i, sda_i,
    output wire        scl_o, scl_oe, sda_o, sda_oe,
    // 输出
    output wire        buzzer,
    output wire [1:0]  led,
    output wire        alarm_active,
    // OSD 写口
    output wire        txt_we, output wire [7:0] txt_wa, output wire [7:0] txt_wd,
    output wire        th_we,  output wire [9:0] th_wa,  output wire [7:0] th_wd
);
    //---------------- 按键 ----------------
    reg [1:0] kn_s, kl_s; reg [DEB_BITS-1:0] kn_c, kl_c; reg kn_q, kl_q, kn_prev, kl_prev;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin kn_s<=2'b11; kl_s<=2'b11; kn_c<=0; kl_c<=0; kn_q<=1; kl_q<=1; kn_prev<=1; kl_prev<=1; end
        else begin
            kn_s <= {kn_s[0], key_night_n}; kl_s <= {kl_s[0], key_learn_n};
            if (kn_s[1] == kn_q) kn_c <= 0; else begin kn_c <= kn_c + 1'b1; if (&kn_c) begin kn_q <= kn_s[1]; kn_c<=0; end end
            if (kl_s[1] == kl_q) kl_c <= 0; else begin kl_c <= kl_c + 1'b1; if (&kl_c) begin kl_q <= kl_s[1]; kl_c<=0; end end
            kn_prev <= kn_q; kl_prev <= kl_q;
        end
    end
    wire kn_press = kn_prev & ~kn_q;
    wire learn_btn = kl_prev & ~kl_q;
    reg night;                              // 默认夜间（演示：夜间有人=入侵）
    always @(posedge clk or negedge rst_n) if (!rst_n) night <= 1'b1; else if (kn_press) night <= ~night;
    wire [4:0] hour = night ? 5'd23 : 5'd12;

    //---------------- 帧/vs 边沿 ----------------
    reg vs_d; always @(posedge clk) vs_d <= in_vs;
    wire vs_rise = in_vs & ~vs_d;

    //---------------- 视觉 ----------------
    wire [7:0] g_gray; wire g_de, g_vs;
    mmt_video_downscale u_ds (.clk(clk), .rst_n(rst_n), .in_r(in_r), .in_g(in_g), .in_b(in_b),
        .in_de(in_de), .in_vs(in_vs), .out_gray(g_gray), .out_de(g_de), .out_vs(g_vs), .frame_cnt());
    wire        fd_done, fd_motion; wire [15:0] fd_area;
    wire        bg_freeze, auto_learn;
    v7_freeze_ctl #(.FREEZE_MAX(FREEZE_MAX)) u_fz (.clk(clk), .rst_n(rst_n), .frame_done(fd_done), .motion(fd_motion),
        .bg_freeze(bg_freeze), .auto_learn(auto_learn));
    v7_frame_diff u_fd (.clk(clk), .rst_n(rst_n), .pix_data(g_gray), .pix_de(g_de), .pix_vs(vs_rise),
        .threshold(8'd25), .min_area(16'd60), .bg_freeze(bg_freeze), .learn_req(learn_btn | auto_learn),
        .frame_done(fd_done), .area(fd_area), .motion(fd_motion));
    reg vis_valid; always @(posedge clk or negedge rst_n) if (!rst_n) vis_valid<=0; else if (fd_done) vis_valid<=1;
    wire [19:0] area_x13 = fd_area * 20'd13;
    reg  [7:0] vision_prob; wire [7:0] vp_c = !fd_motion ? 8'd0 : (area_x13[19:6] > 14'd255 ? 8'd255 : area_x13[13:6]);
    always @(posedge clk) vision_prob <= (AI_MODE != 0) ? (ai_person ? 8'd255 : {2'b00, vp_c[7:2]}) : vp_c;

    //---------------- 传感器 ----------------
    wire sht_valid, sht_crc_err, sht_bus_err, ir_fv, ir_bus_err;
    wire signed [15:0] sht_t; wire [15:0] sht_rh; wire [9:0] ir_ra; wire [15:0] ir_rd;
    mmt_sensor_subsystem #(.CLK_HZ(CLK_HZ), .SCL_HZ(SCL_HZ), .SHT30_PERIOD_MS(SHT_PERIOD_MS), .IR_PERIOD_MS(IR_PERIOD_MS)) u_sns (
        .clk(clk), .rst_n(rst_n), .scl_i(scl_i), .scl_o(scl_o), .scl_oe(scl_oe), .sda_i(sda_i), .sda_o(sda_o), .sda_oe(sda_oe),
        .sht_data_valid(sht_valid), .sht_temp_c_x100(sht_t), .sht_rh_x100(sht_rh), .sht_temp_raw(), .sht_rh_raw(),
        .sht_crc_err(sht_crc_err), .sht_bus_err(sht_bus_err),
        .ir_frame_cnt(), .ir_frame_valid(ir_fv), .ir_ta_raw(), .ir_bus_err(ir_bus_err),
        .ir_rd_addr(ir_ra), .ir_rd_data(ir_rd), .i2c_busy(), .i2c_owner());
    reg sht_seen; always @(posedge clk or negedge rst_n) if (!rst_n) sht_seen<=0; else if (sht_valid) sht_seen<=1;
    wire [15:0] hot_delta; wire ir_valid;
    v7_ir_proc u_ir (.clk(clk), .rst_n(rst_n), .frame_valid(ir_fv), .learn_req(learn_btn),
        .rd_addr(ir_ra), .rd_data(ir_rd), .heat_we(th_we), .heat_wa(th_wa), .heat_wd(th_wd),
        .hot_delta(hot_delta), .valid(ir_valid));
    // 温度换算：每一级都打拍（148.5MHz 下 DSP 乘法 + 长加法不能挤在一拍里）
    reg  [15:0] t_pos;       always @(posedge clk) t_pos <= sht_t[15] ? 16'd0 : sht_t;
    reg  [31:0] amb_m;       always @(posedge clk) amb_m <= t_pos * 32'd13107;   // ×0.1 ≈ ×13107/2^17
    reg  [15:0] amb_x10;     always @(posedge clk) amb_x10 <= amb_m[31:17];
    reg  [31:0] dl;          always @(posedge clk) dl <= hot_delta * IR_K;
    reg  [15:0] dl_x10;      always @(posedge clk) dl_x10 <= dl[15+IR_SH:IR_SH];
    reg  [15:0] body_raw;    always @(posedge clk) body_raw <= amb_x10 + dl_x10;
    reg  signed [15:0] body_x10;
    always @(posedge clk) body_x10 <= (body_raw > 16'd450) ? 16'sd450 : $signed(body_raw);

    //---------------- 融合决策 ----------------
    wire [7:0] cv, ct, ce; wire [8:0] score; wire in_win, alarm_raw;
    mmt_fusion_vote u_fv (.clk(clk), .rst_n(rst_n), .vision_prob(vision_prob), .vision_valid(vis_valid),
        .body_max_c_x10(body_x10), .ir_valid(ir_valid), .ambient_c_x10($signed(amb_x10)), .rh_x100(sht_rh),
        .env_valid(sht_seen), .hour(hour), .score_thresh(8'd154), .auth_start_h(5'd22), .auth_end_h(5'd6),
        .conf_vision(cv), .conf_temp(ct), .conf_env(ce), .score(score), .in_auth_window(in_win), .alarm(alarm_raw), .alarm_valid());
    // 人体证据门控：运动 + 红外热点（热点在上一拍已寄存，hot_delta 来自 ir_proc 的输出寄存器）
    reg ir_hot; always @(posedge clk) ir_hot <= ir_valid && (hot_delta >= HOT_ON);
    wire alarm_gate = alarm_raw & fd_motion & ((REQUIRE_IR == 0) ? 1'b1 : ir_hot);
    reg [HOLD_BITS-1:0] hold;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) hold <= 0;
        else if (alarm_gate) hold <= {HOLD_BITS{1'b1}};
        else if (hold != 0) hold <= hold - 1'b1;
    end
    wire alarm_hold = (hold != 0);
    wire [3:0] led4;
    mmt_alarm_ctrl #(.CLK_HZ(CLK_HZ)) u_al (.clk(clk), .rst_n(rst_n), .alarm(alarm_hold), .event_type(3'd1),
        .confidence(score[7:0]), .mute(1'b0), .led(led4), .buzzer(buzzer), .evt_type_out(), .conf_out(), .alarm_active(alarm_active));
    assign led = led4[1:0];

    //---------------- OSD 文字 ----------------
    reg  [15:0] conf_x100; always @(posedge clk) conf_x100 <= (score * 9'd25) >> 6;   // score/256*100
    wire sns_ok = sht_seen & ~sht_bus_err & ~ir_bus_err;
    wire [15:0] ir_x10 = body_raw;
    v7_txt_fmt u_fmt (.clk(clk), .rst_n(rst_n), .refresh(vs_rise),
        .temp_x100(t_pos), .rh_x100(sht_rh), .ir_x10(ir_x10), .area(fd_area), .conf_x100(conf_x100),
        .motion(fd_motion), .alarm_on(alarm_hold), .night(night), .sns_ok(sns_ok),
        .txt_we(txt_we), .txt_wa(txt_wa), .txt_wd(txt_wd));
endmodule
