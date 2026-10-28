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
    parameter SCL_HZ        = 400_000,     // MERGE12/MERGE9: 传感器 I2C 400 kHz
    parameter SHT_PERIOD_MS = 1000,
    parameter IR_PERIOD_MS  = 125,      // MERGE12/MERGE9: 红外 8 Hz
    parameter [2:0] IR_REFRESH_CODE = 3'b100, // MERGE12/MERGE9: MLX90640 刷新率 8Hz(100)
    parameter HOLD_BITS     = 28,        // 报警保持 2^28/148.5M ≈ 1.8 s
    parameter DEB_BITS      = 22,        // 按键消抖 2^22/148.5M ≈ 28 ms
    parameter IR_K          = 3,         // 体温估算：Δ(0.1℃) = 升温计数*IR_K>>IR_SH（上板标定）
    parameter IR_SH         = 3,
    parameter AI_MODE       = 0,
    parameter signed [7:0] AI_TH = 8'sd1,    // TinyML 人体得分阈值（固件写 APB reg10 后生效；得分 >= 阈值 才算有人）         // 1 = 视觉输入改用 SoC 的 TinyML 人体判决(ai_person)
    parameter PROBE_SCL_HZ  = 50_000,    // 地址扫描的 SCL 频率
    parameter FREEZE_MAX    = 600,       // 连续"有运动"超过此帧数（~10 s@60Hz）→ 视觉背景自动重新学习
    parameter HOT_ON        = 24,        // MERGE13: 48->24（保留兼容；MERGE15 起 ir_hot 改用热像素计数）
    parameter HOT_CNT_TH    = 6,         // MERGE15: 本帧 heat>NOISE 的像素数 >= 此值才判 ir_hot
    parameter FREEZE_RECOVER_MS = 30000, // MERGE15: 冻结基线连续这么久后自动重学
    parameter REQUIRE_IR    = 1,         // 兼容旧参数（IR_GATE_MODE=1 时等效）
    parameter IR_GATE_MODE  = 0,         // MERGE14: 0=门控只看 ai_person；1=ir|ai；2=只看 ir_hot
    parameter IR_IN_FUSION  = 1,         // MERGE14: 1=红外仍参与 60/25/15 融合分数（默认）；0=仅实验用
    parameter PWR_IDLE_FRAMES = 900,     // 无人连续这么多视频帧（~15 s@60Hz）→ 低功耗模式
    parameter PWR_DIV         = 4        // 低功耗模式下视觉处理帧率降为 1/PWR_DIV
)(
    input  wire        clk, rst_n,
    // 视频像素流（OSD 之前，真红在 in_r）
    input  wire [7:0]  in_r, in_g, in_b,
    input  wire        in_de, in_hs, in_vs,
    // 按键（低有效）：key_night 切换 白天/夜间；key_learn 重新学习背景
    input  wire        ai_person,                // TinyML 人体判决（已同步到本时钟域；AI_MODE=0 时忽略）
    input  wire [7:0]  ai_score,                 // TinyML 人体原始得分（int8，已同步）
    input  wire        ai_alive,                 // 固件已写过得分（=0 时退回使用 ai_person）
    input  wire        key_night_n, key_learn_n,
    // MERGE11: ② RISC-V 决策（已同步到本时钟域；APB 字 15 bit0 / 字 14 bit0）
    input  wire [7:0]  fw_evt,                   // MERGE13: 固件事件类型（APB word14[23:16]）
    input  wire        fw_decision_enable,
    input  wire        fw_alarm_req,
    // 传感器 I2C
    input  wire        scl_i, sda_i,
    output wire        scl_o, scl_oe, sda_o, sda_oe,
    // 输出
    output wire        buzzer,
    output wire [1:0]  led,
    output wire        alarm_active,
    // MERGE11: 证据快照（送给 APB 字 11/12/13，均为本时钟域寄存器/组合）
    output wire [31:0] obs_evt,
    output wire [31:0] obs_env,
    output wire [31:0] obs_st,
    // OSD 写口
    output wire        txt_we, output wire [7:0] txt_wa, output wire [7:0] txt_wd,
    output wire        th_we,  output wire [9:0] th_wa,  output wire [7:0] th_wd,
    // MERGE16: OSD 热图信息条用
    output wire [7:0]  hot_cnt_o, output wire signed [15:0] body_x10_o
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
    wire        bg_freeze, auto_learn, fd_vs, low_pwr;
    v7_freeze_ctl #(.FREEZE_MAX(FREEZE_MAX)) u_fz (.clk(clk), .rst_n(rst_n), .frame_done(fd_done), .motion(fd_motion),
        .bg_freeze(bg_freeze), .auto_learn(auto_learn));
    v7_frame_diff u_fd (.clk(clk), .rst_n(rst_n), .pix_data(g_gray), .pix_de(g_de), .pix_vs(fd_vs),
        .threshold(8'd25), .min_area(16'd60), .bg_freeze(bg_freeze), .learn_req(learn_btn | auto_learn),
        .frame_done(fd_done), .area(fd_area), .motion(fd_motion));
    reg vis_valid; always @(posedge clk or negedge rst_n) if (!rst_n) vis_valid<=0; else if (fd_done) vis_valid<=1;
    wire [19:0] area_x13 = fd_area * 20'd13;
    reg  [7:0] vision_prob; wire [7:0] vp_c = !fd_motion ? 8'd0 : (area_x13[19:6] > 14'd255 ? 8'd255 : area_x13[13:6]);
    wire ai_p_eff = ai_alive ? ($signed(ai_score) >= AI_TH) : ai_person;   // 硬件阈值：改阈值无需重编固件
    always @(posedge clk) vision_prob <= (AI_MODE != 0) ? (ai_p_eff ? 8'd255 : {2'b00, vp_c[7:2]}) : vp_c;

    //---------------- 传感器 ----------------
    wire scl_o_w, scl_oe_w, sda_o_w, sda_oe_w;
    wire sht_valid, sht_crc_err, sht_bus_err, ir_fv, ir_bus_err;
    wire signed [15:0] sht_t; wire [15:0] sht_rh; wire [9:0] ir_ra; wire [15:0] ir_rd;
    mmt_sensor_subsystem #(.CLK_HZ(CLK_HZ), .SCL_HZ(SCL_HZ), .SHT30_PERIOD_MS(SHT_PERIOD_MS), .IR_PERIOD_MS(IR_PERIOD_MS), .MLX_REFRESH_CODE(IR_REFRESH_CODE)) u_sns (
        .clk(clk), .rst_n(rst_n), .scl_i(scl_i), .scl_o(scl_o_w), .scl_oe(scl_oe_w), .sda_i(sda_i), .sda_o(sda_o_w), .sda_oe(sda_oe_w),
        .sht_data_valid(sht_valid), .sht_temp_c_x100(sht_t), .sht_rh_x100(sht_rh), .sht_temp_raw(), .sht_rh_raw(),
        .sht_crc_err(sht_crc_err), .sht_bus_err(sht_bus_err),
        .ir_frame_cnt(), .ir_frame_valid(ir_fv), .ir_ta_raw(), .ir_bus_err(ir_bus_err),
        .ir_rd_addr(ir_ra), .ir_rd_data(ir_rd), .i2c_busy(), .i2c_owner());
    reg sht_seen; always @(posedge clk or negedge rst_n) if (!rst_n) sht_seen<=0; else if (sht_valid) sht_seen<=1;
    // 任务1 预处理：温湿度滑动平均(8点)+异常值剔除；时间戳对齐（视频帧为主时间基准）
    wire signed [15:0] sht_t_f; wire [15:0] sht_rh_f_s; wire sht_t_ok, sht_rh_ok, sht_t_rej, sht_rh_rej;
    v7_sns_filter #(.W(16), .TH(500)) u_ft (.clk(clk), .rst_n(rst_n), .valid(sht_valid), .din(sht_t),
        .dout(sht_t_f), .dout_valid(sht_t_ok), .rejected(sht_t_rej));
    v7_sns_filter #(.W(16), .TH(2000)) u_fr (.clk(clk), .rst_n(rst_n), .valid(sht_valid), .din(sht_rh),
        .dout(sht_rh_f_s), .dout_valid(sht_rh_ok), .rejected(sht_rh_rej));
    wire [15:0] sht_rh_f = sht_rh_f_s;
    wire [15:0] ts_frame, ts_age_sht, ts_age_ir; wire al_sht, al_ir;
    v7_ts_align #(.MAX_AGE_SHT(120), .MAX_AGE_IR(60)) u_ts (.clk(clk), .rst_n(rst_n), .vs_rise(vs_rise),
        .sht_new(sht_valid), .ir_new(ir_fv), .frame_cnt(ts_frame), .age_sht(ts_age_sht), .age_ir(ts_age_ir),
        .aligned_sht(al_sht), .aligned_ir(al_ir));
    wire [15:0] hot_delta; wire ir_valid; wire [7:0] hot_cnt;
    assign hot_cnt_o = hot_cnt;
    localparam IR_RECOVER_FRAMES = (FREEZE_RECOVER_MS + IR_PERIOD_MS - 1) / IR_PERIOD_MS;
    v7_ir_proc #(.RECOVER_FRAMES(IR_RECOVER_FRAMES)) u_ir (
        .clk(clk), .rst_n(rst_n), .frame_valid(ir_fv), .learn_req(learn_btn),
        .ai_person(ai_p_eff), .hot_cnt(hot_cnt),
        .rd_addr(ir_ra), .rd_data(ir_rd), .heat_we(th_we), .heat_wa(th_wa), .heat_wd(th_wd),
        .hot_delta(hot_delta), .valid(ir_valid));
    // 温度换算：每一级都打拍（148.5MHz 下 DSP 乘法 + 长加法不能挤在一拍里）
    reg  [15:0] t_pos;       always @(posedge clk) t_pos <= sht_t_f[15] ? 16'd0 : sht_t_f;
    reg  [31:0] amb_m;       always @(posedge clk) amb_m <= t_pos * 32'd13107;   // ×0.1 ≈ ×13107/2^17
    reg  [15:0] amb_x10;     always @(posedge clk) amb_x10 <= amb_m[31:17];
    reg  [31:0] dl;          always @(posedge clk) dl <= hot_delta * IR_K;
    reg  [15:0] dl_x10;      always @(posedge clk) dl_x10 <= dl[15+IR_SH:IR_SH];
    reg  [15:0] body_raw;    always @(posedge clk) body_raw <= amb_x10 + dl_x10;
    reg  signed [15:0] body_x10;
    always @(posedge clk) body_x10 <= (body_raw > 16'd450) ? 16'sd450 : $signed(body_raw);
    assign body_x10_o = body_x10;

    //---------------- 融合决策 ----------------
    wire [7:0] cv, ct, ce; wire [8:0] score; wire in_win, alarm_raw;
    mmt_fusion_vote u_fv (.clk(clk), .rst_n(rst_n), .vision_prob(vision_prob), .vision_valid(vis_valid),
        .body_max_c_x10(body_x10), .ir_valid(ir_valid & al_ir & IR_IN_FUSION), .ambient_c_x10($signed(amb_x10)), .rh_x100(sht_rh_f),
        .env_valid(sht_seen & sht_t_ok & al_sht), .hour(hour), .score_thresh(8'd154), .auth_start_h(5'd22), .auth_end_h(5'd6),
        .conf_vision(cv), .conf_temp(ct), .conf_env(ce), .score(score), .in_auth_window(in_win), .alarm(alarm_raw), .alarm_valid());
    // 人体证据门控：运动 + 红外热点（热点在上一拍已寄存，hot_delta 来自 ir_proc 的输出寄存器）
    // MERGE15: ir_hot = 有效帧 && 热像素数 >= HOT_CNT_TH（body_x10/APB_EVT 布局不变）
    reg ir_hot; always @(posedge clk) ir_hot <= ir_valid && (hot_cnt >= HOT_CNT_TH);
    v7_pwr_ctl #(.IDLE_FRAMES(PWR_IDLE_FRAMES), .DIV(PWR_DIV)) u_pwr (.clk(clk), .rst_n(rst_n), .vs_rise(vs_rise),
        .human(fd_motion | ir_hot), .low_pwr(low_pwr), .proc_vs(fd_vs));
    // MERGE13: 门控单列成模块，ir_hot 或 AI 人体判决任一成立即可
    wire alarm_gate;
    v7_alarm_gate #(.IR_GATE_MODE(IR_GATE_MODE), .REQUIRE_IR(REQUIRE_IR)) u_gate (
        .alarm_raw (alarm_raw),
        .motion    (fd_motion),
        .ir_hot    (ir_hot),
        .ai_person (ai_p_eff),
        .alarm_gate(alarm_gate));
    reg [HOLD_BITS-1:0] hold;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) hold <= 0;
        else if (alarm_gate) hold <= {HOLD_BITS{1'b1}};
        else if (hold != 0) hold <= hold - 1'b1;
    end
    wire alarm_hold = (hold != 0);
    // MERGE11: ② 固件决策使能时，最终报警 = 现有 RTL 报警 & 固件决策结果；
    //          默认 fw_decision_enable=0，行为与 MERGE10 完全一致。
    wire alarm_final;
    v7_alarm_sel u_alsel (
        .rtl_alarm          (alarm_hold),
        .fw_decision_enable (fw_decision_enable),
        .fw_alarm_req       (fw_alarm_req),
        .alarm_final        (alarm_final)
    );
    wire [3:0] led4;
    mmt_alarm_ctrl #(.CLK_HZ(CLK_HZ)) u_al (.clk(clk), .rst_n(rst_n), .alarm(alarm_final), .event_type(3'd1),
        .confidence(score[7:0]), .mute(1'b0), .led(led4), .buzzer(buzzer), .evt_type_out(), .conf_out(), .alarm_active(alarm_active));
    reg [29:0] slow_c; always @(posedge clk or negedge rst_n) if (!rst_n) slow_c <= 30'd0; else slow_c <= slow_c + 1'b1;            // 低功耗指示：LED0 慢闪（~0.28 Hz 翻转）
    assign led = {led4[1], low_pwr ? slow_c[29] : led4[0]};


    //---------------- I2C 诊断（SENSE6）----------------
    reg [1:0] dg_scl_s, dg_sda_s; always @(posedge clk) begin dg_scl_s <= {dg_scl_s[0], scl_i}; dg_sda_s <= {dg_sda_s[0], sda_i}; end
    reg [8:0] dg_rel_sda, dg_rel_scl;     // 主机释放线后的稳定计数（>=256 拍 ≈1.7us，远大于上拉上升时间）
    reg scl_oe_d, dg_slv_q, dg_slv, dg_stuck, dg_crc, dg_irseen;
    reg [15:0] dg_oe_cnt, dg_slv_cnt;
    wire dg_slv_now = dg_rel_sda[8] & ~dg_sda_s[1];       // 主机已释放 SDA 却为低 = 从机在拉低（ACK/数据）
    wire dg_stk_now = dg_rel_scl[8] & ~dg_scl_s[1];       // 主机已释放 SCL 却为低 = 被外部拉住
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin dg_rel_sda<=0; dg_rel_scl<=0; scl_oe_d<=0; dg_slv_q<=0; dg_slv<=0; dg_stuck<=0; dg_crc<=0; dg_irseen<=0; dg_oe_cnt<=0; dg_slv_cnt<=0; end
        else begin
            scl_oe_d <= scl_oe; dg_slv_q <= dg_slv_now;
            dg_rel_sda <= sda_oe ? 9'd0 : (dg_rel_sda[8] ? dg_rel_sda : dg_rel_sda + 1'b1);
            dg_rel_scl <= scl_oe ? 9'd0 : (dg_rel_scl[8] ? dg_rel_scl : dg_rel_scl + 1'b1);
            if (scl_oe & ~scl_oe_d & ~&dg_oe_cnt) dg_oe_cnt <= dg_oe_cnt + 1'b1;
            if (dg_slv_now & ~dg_slv_q & ~&dg_slv_cnt) dg_slv_cnt <= dg_slv_cnt + 1'b1;
            if (dg_slv_now) dg_slv <= 1'b1;
            if (dg_stk_now) dg_stuck <= 1'b1;
            if (sht_crc_err) dg_crc <= 1'b1;
            if (ir_fv) dg_irseen <= 1'b1;
        end
    end

    //---------------- I2C 地址扫描（SENSE7）：按住 KEY2 接管总线 ----------------
    wire probe_own = ~kl_q;
    wire pr_scl_o, pr_scl_oe, pr_sda_o, pr_sda_oe, pr_act; wire [7:0] pr_cnt, pr_scans; wire [6:0] pr_a0, pr_a1;
    v7_i2c_probe #(.CLK_HZ(CLK_HZ), .SCL_HZ(PROBE_SCL_HZ)) u_probe (.clk(clk), .rst_n(rst_n), .en(probe_own),
        .scl_i(scl_i), .sda_i(sda_i), .scl_o(pr_scl_o), .scl_oe(pr_scl_oe), .sda_o(pr_sda_o), .sda_oe(pr_sda_oe), .active(pr_act),
        .res_cnt(pr_cnt), .res_a0(pr_a0), .res_a1(pr_a1), .scans(pr_scans));
    assign scl_o  = probe_own ? pr_scl_o  : scl_o_w;
    assign scl_oe = probe_own ? pr_scl_oe : scl_oe_w;
    assign sda_o  = probe_own ? pr_sda_o  : sda_o_w;
    assign sda_oe = probe_own ? pr_sda_oe : sda_oe_w;
    // 回环：主机驱动低足够久后，引脚输入应读到 0（验证 FPGA 驱动/OE/约束）
    reg [8:0] dg_drv_scl, dg_drv_sda; reg dg_lb_scl, dg_lb_sda;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin dg_drv_scl<=0; dg_drv_sda<=0; dg_lb_scl<=0; dg_lb_sda<=0; end
        else begin
            dg_drv_scl <= (scl_oe & ~scl_o) ? (dg_drv_scl[8] ? dg_drv_scl : dg_drv_scl + 1'b1) : 9'd0;
            dg_drv_sda <= (sda_oe & ~sda_o) ? (dg_drv_sda[8] ? dg_drv_sda : dg_drv_sda + 1'b1) : 9'd0;
            if (dg_drv_scl[8] & ~dg_scl_s[1]) dg_lb_scl <= 1'b1;
            if (dg_drv_sda[8] & ~dg_sda_s[1]) dg_lb_sda <= 1'b1;
        end
    end

    //---------------- OSD 文字 ----------------
    reg  [15:0] conf_x100; always @(posedge clk) conf_x100 <= (score * 9'd25) >> 6;   // score/256*100
    wire sns_ok = sht_seen & ~sht_bus_err & ~ir_bus_err;
    wire [15:0] ir_x10 = body_raw;
    v7_txt_fmt u_fmt (.clk(clk), .rst_n(rst_n), .refresh(vs_rise),
        .temp_x100(t_pos), .rh_x100(sht_rh_f), .ir_x10(ir_x10), .area(fd_area), .conf_x100(conf_x100),
        .ai_score(ai_score), .ai_alive(ai_alive), .ai_person(ai_p_eff), .motion(fd_motion), .alarm_on(alarm_final), .evt_code(fw_evt), .night(night), .sns_ok(sns_ok), .low_pwr(low_pwr),
        .dg_lb_scl(dg_lb_scl), .dg_lb_sda(dg_lb_sda), .pr_scans(pr_scans), .pr_cnt(pr_cnt), .pr_a0(pr_a0), .pr_a1(pr_a1), .dg_scl(dg_scl_s[1]), .dg_sda(dg_sda_s[1]), .dg_slv(dg_slv), .dg_stuck(dg_stuck), .dg_sht_err(sht_bus_err), .dg_ir_err(ir_bus_err),
        .dg_sht_seen(sht_seen), .dg_irseen(dg_irseen), .dg_crc(dg_crc), .dg_oe_cnt(dg_oe_cnt), .dg_slv_cnt(dg_slv_cnt),
        .txt_we(txt_we), .txt_wa(txt_wa), .txt_wd(txt_wd));

    //---------------- MERGE11: 证据快照（APB 字 11/12/13，供 RISC-V 做历史决策） ----------------
    // 全部在本时钟域；顶层 v7_apb_ext 在 vs 上升沿锁存后跨到 core_clk 域。
    reg [7:0] vs_cnt;                               // 视频帧计数（帧率测量用，8 位回绕）
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) vs_cnt <= 8'd0;
        else if (vs_rise) vs_cnt <= vs_cnt + 8'd1;
    end

    // 字 11：motion / IR 摘要
    wire [11:0] body_x10_u = body_x10[15] ? 12'd0 : body_x10[11:0];  // 已钳位 0..450
    wire [3:0]  evt_flags  = {sht_seen, ir_valid, ir_hot, fd_motion};
    assign obs_evt = {fd_area, body_x10_u, evt_flags};
    //   [31:16]=帧差面积  [15:4]=最高体温×10  [3]=sht_seen [2]=ir_valid [1]=ir_hot [0]=motion

    // 字 12：环境（温度×10、湿度×10）
    wire [15:0] rh_x10 = sht_rh_f / 16'd10;
    assign obs_env = {rh_x10, amb_x10};
    //   [31:16]=湿度×10 %RH  [15:0]=环境温度×10 ℃（有符号）

    // 字 13：RTL 融合 / 低功耗 / 报警状态
    assign obs_st = {vs_cnt, 3'd0, 2'd0, alarm_final, low_pwr, conf_x100[7:0], score};
    //   [31:24]=视频帧计数  [18]=alarm_final  [17]=low_pwr  [16:9]=置信度  [8:0]=融合得分
    //   （[19]/[20] 由顶层 v7_apb_ext 填入固件状态回读）
endmodule




