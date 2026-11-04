`timescale 1ns / 1ps
//==========================================================================
// v7_apb_ext.v — MERGE11: APB 字 11..15（② RISC-V 决策控制 / ⑤ 低功耗 的软硬件接口）
//
// 字 11 (0x2C) 只读：运动 / 红外摘要
//     [0]     fd_motion          帧差检测到运动
//     [1]     ir_hot             红外热点（相对升温 >= HOT_ON）
//     [2]     ir_valid           MLX90640 新帧有效
//     [3]     sht_seen           SHT30 曾经读到有效数据
//     [15:4]  body_temp_x10[11:0] 估算最高体温 ×10 ℃（0..450，无符号）
//     [31:16] fd_area            帧差变化像素数（0..19200）
//
// 字 12 (0x30) 只读：环境
//     [15:0]  ambient_temp_x10   环境温度 ×10 ℃（有符号 int16）
//     [31:16] rh_x10             相对湿度 ×10 %RH（0..1000）
//
// 字 13 (0x34) 只读：RTL 融合 / 低功耗 / 报警状态
//     [8:0]   score              RTL 融合得分（0..511）
//     [16:9]  conf               置信度 0..100
//     [17]    low_pwr            v7_pwr_ctl 低功耗状态
//     [18]    alarm_final        当前最终报警状态（含固件决策门控）
//     [19]    fw_decision_enable 回读（字 15 bit0）
//     [20]    fw_ai_infer_en     回读（字 15 bit1，仅状态量，RTL 不使用）
//     [23:21] 保留 0
//     [31:24] vid_frame_cnt[7:0] 视频帧计数（vs 上升沿 +1，用于帧率测量）
//
// 字 14 (0x38) 只写：固件决策结果
//     [0]     alarm_req          固件报警请求
//     [15:8]  confidence         固件置信度 0..100
//     [23:16] event_type         0=无 1=入侵 2=趋势预警 3=其他（由固件定义）
//     [31:24] 保留
//
// 字 15 (0x3C) 只写：固件控制
//     [0]     fw_decision_enable 1 = 最终报警与固件决策结果相与（默认 0 = MERGE10 行为）
//     [1]     fw_ai_infer_en     1 = 固件本周期执行了 AI 推理（仅观测）
//
// 跨时钟域：
//   证据（视频域 evt/env/st）→ core 域：每帧 vs 上升沿在视频域锁存快照并翻转 toggle，
//   core 域检测 toggle 边沿后整字锁存（数据在 toggle 前已稳定一整帧，属握手式传输）。
//   fw_decision_enable / fw_alarm_req（core 域）→ 视频域：两级触发器。
//==========================================================================
module v7_apb_ext (
    // ---- core_clk（APB）域 ----
    input  wire        core_clk,
    input  wire        core_rst_n,
    input  wire [31:0] paddr,
    input  wire [31:0] pwdata,
    input  wire        psel,
    input  wire        penable,
    input  wire        pwrite,
    output wire [31:0] prdata,               // 字 11/12/13 读数据（hit=1 时有效）
    output wire        hit,                  // 本次读命中本模块的字
    // ---- vid_clk（hdmi_tx_slow_clk）域 ----
    input  wire        vid_clk,
    input  wire        vid_rst_n,
    input  wire        vs_rise,              // 视频帧起始单拍脉冲
    input  wire [31:0] evt_v,                // 字 11 原始证据
    input  wire [31:0] env_v,                // 字 12 原始证据
    input  wire [31:0] st_v,                 // 字 13 原始证据
    output wire [7:0]  fw_evt_v,             // MERGE13: 固件事件类型（视频域）
    output wire        fw_decision_enable_v, // 同步到视频域的控制
    output wire        fw_alarm_req_v,       // 同步到视频域的决策
    // ---- core 域回读（调试/状态） ----
    output wire        fw_decision_enable,
    output wire        fw_alarm_req
);

    localparam [4:0] W_EVT  = 5'd11;
    localparam [4:0] W_ENV  = 5'd12;
    localparam [4:0] W_ST   = 5'd13;
    localparam [4:0] W_DEC  = 5'd14;
    localparam [4:0] W_CTRL = 5'd15;

    wire [4:0] word = paddr[6:2];
    wire       wr   = psel & penable & pwrite;

    // ------------------------------------------------------------------
    // core 域：固件写入的字 14 / 15
    // ------------------------------------------------------------------
    reg [31:0] w14_q, w15_q;
    always @(posedge core_clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            w14_q <= 32'd0;
            w15_q <= 32'd0;
        end else begin
            if (wr && (word == W_DEC))  w14_q <= pwdata;
            if (wr && (word == W_CTRL)) w15_q <= pwdata;
        end
    end

    // MERGE13: word14 事件类型（[23:16]）用 toggle 握手送到视频域
    reg [7:0] evt_q_core;
    reg       evt_tgl_core;
    always @(posedge core_clk or negedge core_rst_n) begin
        if (!core_rst_n) begin evt_q_core <= 8'd0; evt_tgl_core <= 1'b0; end
        else if (wr && (word == W_DEC)) begin
            evt_q_core  <= pwdata[23:16];
            evt_tgl_core<= ~evt_tgl_core;
        end
    end
    assign fw_decision_enable = w15_q[0];
    assign fw_alarm_req       = w14_q[0];
    wire   fw_ai_infer_en     = w15_q[1];

    // ------------------------------------------------------------------
    // 视频域：每帧锁存证据快照 + 翻转 toggle
    // ------------------------------------------------------------------
    reg [31:0] evt_q, env_q, st_q;
    reg        tgl;
    always @(posedge vid_clk or negedge vid_rst_n) begin
        if (!vid_rst_n) begin
            evt_q <= 32'd0;
            env_q <= 32'd0;
            st_q  <= 32'd0;
            tgl   <= 1'b0;
        end else if (vs_rise) begin
            evt_q <= evt_v;
            env_q <= env_v;
            st_q  <= st_v;
            tgl   <= ~tgl;
        end
    end

    // ------------------------------------------------------------------
    // core 域：检测 toggle 边沿后整字锁存（toggle 同步链）
    // ------------------------------------------------------------------
    reg [2:0]  tgl_s;
    reg [31:0] evt_c, env_c, st_c;
    always @(posedge core_clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            tgl_s <= 3'd0;
            evt_c <= 32'd0;
            env_c <= 32'd0;
            st_c  <= 32'd0;
        end else begin
            tgl_s <= {tgl_s[1:0], tgl};
            if (tgl_s[1] ^ tgl_s[2]) begin
                evt_c <= evt_q;
                env_c <= env_q;
                st_c  <= st_q;
            end
        end
    end

    // ------------------------------------------------------------------
    // core 域 → 视频域：两个控制位用两级触发器
    // ------------------------------------------------------------------
    reg [1:0] en_s, req_s;
    always @(posedge vid_clk or negedge vid_rst_n) begin
        if (!vid_rst_n) begin
            en_s  <= 2'd0;
            req_s <= 2'd0;
        end else begin
            en_s  <= {en_s[0],  fw_decision_enable};
            req_s <= {req_s[0], fw_alarm_req};
        end
    end

    // MERGE13: 视频域检测 evt toggle 边沿后锁存 8 位事件类型
    reg [2:0] evt_tgl_s;
    reg [7:0] evt_v_q;
    always @(posedge vid_clk or negedge vid_rst_n) begin
        if (!vid_rst_n) begin evt_tgl_s <= 3'd0; evt_v_q <= 8'd0; end
        else begin
            evt_tgl_s <= {evt_tgl_s[1:0], evt_tgl_core};
            if (evt_tgl_s[1] ^ evt_tgl_s[2]) evt_v_q <= evt_q_core;
        end
    end
    assign fw_evt_v = evt_v_q;

    assign fw_decision_enable_v = en_s[1];
    assign fw_alarm_req_v      = req_s[1];

    // ------------------------------------------------------------------
    // 读多路
    // ------------------------------------------------------------------
    assign hit = (word == W_EVT) || (word == W_ENV) || (word == W_ST);

    assign prdata = (word == W_EVT) ? evt_c :
                    (word == W_ENV) ? env_c :
                    (word == W_ST)  ? { st_c[31:24], 3'd0,
                                        fw_ai_infer_en, fw_decision_enable,
                                        st_c[18:0] } :
                                      32'd0;

endmodule
