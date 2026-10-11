//==========================================================================
//  mmt_soc_regs.v  —  RISC-V 软核与 FPGA 硬件之间的寄存器桥（APB3 从机）
//--------------------------------------------------------------------------
//  作用：Sapphire SoC 通过它的 APB Slave 0 口（16 位地址 / 32 位数据）访问本模块，
//        从而：
//          · 读走传感器与算法的结果（SHT30 温湿度、红外帧、帧差面积/质心、融合得分、报警）
//          · 写入配置与中间结果（帧差阈值、融合阈值、授权时段、当前小时、
//            视觉概率、红外最高体温、背景清空/冻结）
//
//  APB3 时序（标准）：
//      建立相: PSEL=1, PENABLE=0
//      访问相: PSEL=1, PENABLE=1  → PREADY=1 表示完成
//  本模块 0 等待周期：PREADY 恒 1，PSLVERROR 恒 0。
//
//  寄存器映射（地址为 APB 字节地址，SoC 侧基址见 settings.json 的 APBSlave0_M_Addr = 0x100000）
//  ─────────────────────────────────────────────────────────────────────
//   偏移   读写  名称              内容
//   0x00   R     ID                固定 0x4D4D5401 ("MMT" + 版本 1)，用于软核自检
//   0x04   R     SHT30_A           [31:16]=temp_c_x100(有符号) [15:0]=rh_x100
//   0x08   R     SHT30_B           [31:16]=temp_raw             [15:0]=rh_raw
//   0x0C   R     SHT30_ST          [0]=data_valid [1]=crc_err [2]=bus_err
//   0x10   R     IR_ST             [31:16]=frame_cnt [0]=frame_valid [1]=bus_err
//   0x14   R     IR_TA             [15:0]=ta_raw(Ptat)
//   0x18   R     MOTION_AREA       [31:0]=sum_area
//   0x1C   R     MOTION_SUMX       [31:0]=sum_x
//   0x20   R     MOTION_SUMY       [31:0]=sum_y
//   0x24   R     MOTION_ST         [0]=motion_flag [1]=frame_done
//   0x28   R     FUSION_SCORE      [31:24]=conf_vision [23:16]=conf_temp [15:8]=conf_env
//                                   [0]=score(9 位, 放 [8:0])   → 实际：[8:0]=score
//   0x2C   R     ALARM_ST          [0]=alarm [1]=in_auth_window [4:2]=evt_type
//   0x30   W     CFG_DIFF          [15:8]=diff_threshold [7:0]=(保留)  ... 见实现
//   0x34   W     CFG_MINAREA       [15:0]=diff_min_area
//   0x38   W     CFG_FUSION        [15:8]=score_thresh [7:0]=auth_end_h[4:0]
//   0x3C   W     CFG_AUTH          [4:0]=auth_start_h [12:8]=hour  (软核写当前小时)
//   0x40   W     VISION            [7:0]=vision_prob [8]=vision_valid
//   0x44   W     BODY_TEMP         [15:0]=body_max_c_x10(有符号) [16]=ir_valid
//   0x48   W     CTRL              [0]=diff_enable [1]=bg_freeze [2]=bg_clear [3]=alarm_mute
//   0x4C   R     IR_FRAME_RD       [15:0]=红外帧 RAM 在 IR_FRAME_ADDR 处的数据
//   0x50   W     IR_FRAME_ADDR     [9:0]=要读的红外帧 RAM 地址(0..831)
//   0x54   W     AMBIENT           [15:0]=ambient_c_x10(有符号) [16]=env_valid
//  ─────────────────────────────────────────────────────────────────────
//
//  ⚠️ 说明：本模块只做"搬运"，不做运算。红外逐点温度计算、时间对齐、复杂决策
//     都由软核跑 C 代码完成（Melexis 官方库需要 800+ 校准参数与浮点运算）。
//==========================================================================
`timescale 1ns / 1ps

module mmt_soc_regs (
    input  wire        clk,
    input  wire        rst_n,

    // ---------------- APB3 从机（接 SoC 的 io_apbSlave_0_*）----------------
    input  wire [15:0] PADDR,
    input  wire        PENABLE,
    input  wire [31:0] PWDATA,
    input  wire        PWRITE,
    input  wire        PSEL,
    output reg  [31:0] PRDATA,
    output wire        PREADY,
    output wire        PSLVERROR,

    // ---------------- 只读输入：传感器子系统 ----------------
    input  wire        sht_data_valid,
    input  wire signed [15:0] sht_temp_c_x100,
    input  wire [15:0] sht_rh_x100,
    input  wire [15:0] sht_temp_raw,
    input  wire [15:0] sht_rh_raw,
    input  wire        sht_crc_err,
    input  wire        sht_bus_err,

    input  wire [15:0] ir_frame_cnt,
    input  wire        ir_frame_valid,
    input  wire        ir_bus_err,
    input  wire [15:0] ir_ta_raw,
    input  wire [15:0] ir_rd_data,        // 红外帧 RAM 读口返回

    // ---------------- 只读输入：算法子系统 ----------------
    input  wire        motion_frame_done,
    input  wire        motion_frame_tgl,     // ★ 每完成一帧翻转一次（已同步到本域）
                                             //   软核靠"翻转标志变了"才信任 sum_area 等数据：
                                             //   多比特信号跨域时可能刚好读到中间值，
                                             //   而翻转标志未变就说明数据还没开始更新，可安全忽略
    input  wire [31:0] motion_sum_area,
    input  wire [31:0] motion_sum_x,
    input  wire [31:0] motion_sum_y,
    input  wire        motion_flag,
    input  wire [7:0]  conf_vision,
    input  wire [7:0]  conf_temp,
    input  wire [7:0]  conf_env,
    input  wire [8:0]  score,
    input  wire        in_auth_window,
    input  wire        alarm,

    // ---------------- 读写输出：配置给硬件 ----------------
    output reg  [7:0]  diff_threshold,
    output reg  [15:0] diff_min_area,
    output reg  [7:0]  score_thresh,
    output reg  [4:0]  auth_start_h,
    output reg  [4:0]  auth_end_h,
    output reg  [4:0]  hour,
    output reg  [7:0]  vision_prob,
    output reg         vision_valid,
    output reg  signed [15:0] body_max_c_x10,
    output reg         ir_valid,
    output reg  signed [15:0] ambient_c_x10,
    output reg         env_valid,
    output reg         diff_enable,
    output reg         bg_freeze,
    output reg         bg_clear_tgl,   // ★ 翻转式清空请求：软核每写一次 bit2 翻转一次
                                       //   （原来是单周期脉冲，跨到 148.5MHz 视频域会丢；
                                       //    单比特翻转 + 两级同步 + 视频域边沿检测 = 可靠）
    output reg         alarm_mute,
    output reg  [9:0]  ir_frame_addr,
    output reg  [15:0] rh_x100_fwd,          // 软核转发给融合模块的湿度（SHT30 读到的）
    // ---- OSD 显示缓冲写口（软核往里写文字与热力图色阶）----
    output reg         osd_txt_we,
    output reg  [7:0]  osd_txt_addr,
    output reg  [7:0]  osd_txt_data,
    output reg         osd_th_we,
    output reg  [9:0]  osd_th_addr,
    output reg  [7:0]  osd_th_data
);

    // 0 等待周期
    assign PREADY    = 1'b1;
    assign PSLVERROR = 1'b0;

    // 写使能（访问相且为写）
    wire wr = PSEL && PENABLE && PWRITE;
    // 读数据在建立相就要给出（APB3 允许地址在建立相有效）
    wire rd = PSEL && !PWRITE;

    // OSD 缓冲写脉冲：只在访问相那一拍有效（写地址/数据寄存器时不动缓冲）
    always @(*) begin
        osd_txt_we = wr && (PADDR == 16'h0060);
        osd_th_we  = wr && (PADDR == 16'h0068);
    end

    // 上一次的报警/完成标志用锁存，方便软核轮询（避免错过单周期脉冲）
    reg sht_valid_l, ir_valid_l, motion_done_l, alarm_l;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sht_valid_l   <= 1'b0;
            ir_valid_l    <= 1'b0;
            motion_done_l <= 1'b0;
            alarm_l       <= 1'b0;
        end else begin
            if (sht_data_valid)   sht_valid_l   <= 1'b1;
            if (ir_frame_valid)   ir_valid_l    <= 1'b1;
            if (motion_frame_done)motion_done_l <= 1'b1;
            if (alarm)            alarm_l       <= 1'b1;
            // 软核读走状态寄存器即清标志
            if (PSEL && PENABLE && !PWRITE && (PADDR == 16'h000C)) sht_valid_l   <= 1'b0;
            if (PSEL && PENABLE && !PWRITE && (PADDR == 16'h0010)) ir_valid_l    <= 1'b0;
            if (PSEL && PENABLE && !PWRITE && (PADDR == 16'h0024)) motion_done_l <= 1'b0;
            if (PSEL && PENABLE && !PWRITE && (PADDR == 16'h002C)) alarm_l       <= 1'b0;
        end
    end

    //----------------------------------------------------------------------
    // 读
    //----------------------------------------------------------------------
    always @(*) begin
        case (PADDR)
            16'h0000: PRDATA = 32'h4D4D5401;                                // "MMT" v1
            16'h0004: PRDATA = {sht_temp_c_x100, sht_rh_x100};
            16'h0008: PRDATA = {sht_temp_raw, sht_rh_raw};
            16'h000C: PRDATA = {29'd0, sht_bus_err, sht_crc_err, sht_valid_l};
            16'h0010: PRDATA = {ir_frame_cnt, 14'd0, ir_bus_err, ir_valid_l};
            16'h0014: PRDATA = {16'd0, ir_ta_raw};
            16'h0018: PRDATA = motion_sum_area;
            16'h001C: PRDATA = motion_sum_x;
            16'h0020: PRDATA = motion_sum_y;
            16'h0024: PRDATA = {29'd0, motion_frame_tgl, motion_done_l, motion_flag};
            16'h0028: PRDATA = {7'd0, conf_vision, conf_temp, conf_env, 6'd0, score};
            16'h002C: PRDATA = {26'd0, evt_type_l, in_auth_window, alarm_l};
            16'h004C: PRDATA = {16'd0, ir_rd_data};
            16'h005C: PRDATA = {24'd0, osd_txt_addr};      // 回读 OSD 文字写地址
            16'h0064: PRDATA = {22'd0, osd_th_addr};       // 回读 OSD 热力图写地址
            default:  PRDATA = 32'h0;
        endcase
    end

    reg [2:0] evt_type_l;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) evt_type_l <= 3'd0;
        else if (alarm) evt_type_l <= 3'd1;      // 1 = 入侵
    end

    //----------------------------------------------------------------------
    // 写
    //----------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            diff_threshold  <= 8'd25;      // 与 Python 原型默认值一致
            diff_min_area   <= 16'd60;
            score_thresh    <= 8'd154;     // 0.60 × 256
            auth_start_h    <= 5'd22;      // 22:00
            auth_end_h      <= 5'd6;       // 次日 06:00
            hour            <= 5'd0;
            vision_prob     <= 8'd0;
            vision_valid    <= 1'b0;
            body_max_c_x10  <= 16'sd0;
            ir_valid        <= 1'b0;
            ambient_c_x10   <= 16'sd0;
            env_valid       <= 1'b0;
            diff_enable     <= 1'b1;
            bg_freeze       <= 1'b0;
            bg_clear_tgl    <= 1'b0;
            alarm_mute      <= 1'b0;
            ir_frame_addr   <= 10'd0;
            rh_x100_fwd     <= 16'd0;
            osd_txt_addr    <= 8'd0;
            osd_txt_data    <= 8'd0;
            osd_th_addr     <= 10'd0;
            osd_th_data     <= 8'd0;
        end else begin
            // bg_clear 改成翻转请求，不再需要"自清脉冲"
            if (wr && (PADDR == 16'h0048) && PWDATA[2]) bg_clear_tgl <= ~bg_clear_tgl;

            if (wr) begin
                case (PADDR)
                    16'h0030: diff_threshold <= PWDATA[15:8];
                    16'h0034: diff_min_area  <= PWDATA[15:0];
                    16'h0038: begin
                        score_thresh <= PWDATA[15:8];
                        auth_end_h   <= PWDATA[4:0];
                    end
                    16'h003C: begin
                        auth_start_h <= PWDATA[4:0];
                        hour         <= PWDATA[12:8];
                    end
                    16'h0040: begin
                        vision_prob  <= PWDATA[7:0];
                        vision_valid <= PWDATA[8];
                    end
                    16'h0044: begin
                        body_max_c_x10 <= PWDATA[15:0];
                        ir_valid       <= PWDATA[16];
                    end
                    16'h0048: begin
                        diff_enable <= PWDATA[0];
                        bg_freeze   <= PWDATA[1];
                        // bit2 不在这里赋值 —— 它在上面单独做翻转（见 bg_clear_tgl）
                        alarm_mute  <= PWDATA[3];
                    end
                    16'h0050: ir_frame_addr <= PWDATA[9:0];
                    16'h0054: begin
                        ambient_c_x10 <= PWDATA[15:0];
                        env_valid     <= PWDATA[16];
                    end
                    16'h0058: rh_x100_fwd <= PWDATA[15:0];   // 软核把 SHT30 的湿度转发给融合
                    // ---- OSD 显示缓冲：先写地址，再写数据（数据那一拍产生写脉冲）----
                    16'h005C: osd_txt_addr <= PWDATA[7:0];
                    16'h0060: osd_txt_data <= PWDATA[7:0];
                    16'h0064: osd_th_addr  <= PWDATA[9:0];
                    16'h0068: osd_th_data  <= PWDATA[7:0];
                    default: ;
                endcase
            end
        end
    end

endmodule
