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
//   ─────────────── 以下为 2026-10-12 新增（上板判据，见 docs\上板判据-写通路握手计数.md）──
//   0x6C   R     FB_AW_CNT         [31:0]=写地址通道(fb_awvalid&fb_awready)握手累计数
//   0x70   R     FB_W_CNT          [31:0]=写数据通道(fb_wvalid &fb_wready )握手累计数
//   0x74   R     FB_WR_STAT        [0]=awvalid [1]=awready [2]=wvalid [3]=wready
//                                  [4]=aw_seen [5]=w_seen（曾握手过的粘滞位）
//   0x78   R     VISION_WORD       [31:24]=conf_vision(完整 8 位) [23:16]=conf_temp
//                                  [15:8]=conf_env [7:0]=0
//   0x7C   R     FRAME_TGL_CNT     [31:0]=motion_frame_tgl 的跳变次数（视频帧数）
//                                  ★ 这个**不需要额外接线**，重编位流即可用
//  ─────────────── 以下为 task-19/22/24 新增（摄像头上游探针 + 最大写地址）──────
//   0x80..0xBC  R  （摄像头上游探针）**连续** 16 个寄存器，raddr 0..15，
//                    见 rtl\mmt\mmt_cam_probe.v 的表头寄存器表
//   0xC0/0xC4   R  **不映射**（探针窗口的越界保护；读到 0）
//   0xC8..0xD4  R  测试图案 + 视频时序计数（task-23）
//   0xD8   R     FB_AWADDR_MAX     [31:0]=历史最大 fb_awaddr（只在 AW 握手那拍取样）
//   0xDC   R     FB_AW_STAT        [15:0]=采样次数(饱和) [16]=至少采样过一次
//                                  [17]=曾采到非 0 地址
//                                  ⚠️ 0xD8 必须与 0xDC 联合读："amax=0 且采样=0"=没出图，
//                                     不能当成"没越界"（见 docs\上板判据-最大写地址.md）
//
//  ★ 2026-10-13 修正（task-24 复查查出并修掉）：
//     FB_AWADDR_MAX / FB_AW_STAT 原先在 **0xA8/0xAC**，正好插在探针的线性窗口里
//     ⇒ ① 显式 case 优先于 default，把探针 raddr 10/11（PROBE_ID/CSI_PD_CNT）挡死；
//        ② 探针上界原为 49(0xC4)，0xC0/0xC4 算出 raddr 16/17 被 4 位截成 0/1
//           ⇒ **别名**回 CAM_SCL_CNT / CAM_CK_CNT。
//     现在：fb 两个寄存器移到空闲的 **0xD8/0xDC**；探针上界收到 **47(0xBC)**
//     ⇒ 探针窗口是**连续无洞**的 0x80..0xBC，0xC0/0xC4 返回 0。
//     （软核侧 sw\mmt_regs.h 已同步；判读文档见 docs\上板判据-摄像头上游探针.md §7）
//  ─────────────────────────────────────────────────────────────────────
//
//  ⚠️ 已知问题（本轮查出，**未修改**，避免破坏既有映射）：0x28 的拼接
//     `{7'd0, conf_vision, conf_temp, conf_env, 6'd0, score}` 是 46 位，
//     赋给 32 位 PRDATA 时高 14 位被截断 ⇒ 实际布局与注释**不一致**：
//       [31]   = conf_vision[0]（**只有 1 位**视觉，不是 8 位）
//       [30:23]= conf_temp      [22:15]= conf_env      [14:9]=0      [8:0]=score
//     所以要读完整的视觉字节请用新的 0x78（VISION_WORD）。
//     详见 docs\上板判据-写通路握手计数.md §3。
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

    // ---------------- 只读输入：帧缓冲写通路握手（★ 2026-10-12 新增，上板判据用）----
    //   来源：mmt_top.v 里 frame_buffer 写通道的 4 根 wire
    //         （fb_awvalid :347 / fb_awready :348 / fb_wvalid :352 / fb_wready :353，
    //          它们同时接到 axi_interconnect 的 s0 口 :783/:796/:798 与 checker0 :729/:730/:747/:748）
    //   时钟域：这 4 根线都在 **core_clk** 域（AXI 互联与 checker0 用的都是 core_clk，
    //           见 mmt_top.v:698/.axi_clk(core_clk)、:779 .clk(core_clk)），
    //           而本模块也在 core_clk ⇒ **不需要 CDC**，直接采样即可。
    //   ⚠️ 这 4 个端口需要在 mmt_soc_subsystem.v 与 mmt_top.v 各补几行连接
    //      （写权限不在本轮范围内），补丁见 docs\上板判据-写通路握手计数.md §2。
    input  wire        fb_awvalid,
    input  wire        fb_awready,
    input  wire        fb_wvalid,
    input  wire        fb_wready,
    // fb_awaddr 用于"最大写地址"判据（task-22）：必须与 awvalid/awready 同域同时刻有效。
    //   来源 mmt_top.v:340 `wire [AXI_ADDR_WIDTH-1:0] fb_awaddr;`（AXI_ADDR_WIDTH=32，
    //   见 rtl\ddr3_controller\ddr3_parameter.vh:22），它同时接到互联 s0 口与 checker0，
    //   但**没有**引进 mmt_soc_subsystem —— 需要 Lead 补 1 个端口 + 2 处连接，
    //   补丁见 docs\上板判据-最大写地址.md §2。
    input  wire [31:0] fb_awaddr,

    // ---------------- ★ 视频时序计数（task-23 / M0）：只读输入 ----------------
    //   来源：mmt_test_pattern 自带的测量输出（该模块例化在 mmt_top，
    //         用它自己的像素域时钟计数，因此**不需要在本模块再数一遍**）。
    //   为什么不在这里数：像素时钟 i_mipi_rx_pclk 是 PLL 输出、可能快于
    //   core_clk(100MHz)，在 core_clk 域采 de 电平会漏窄脉冲 ⇒ 计数偏小。
    //   ⚠️ 这三个值每帧才更新一次（准静态），跨到 core_clk 直接采样即可，
    //      但需要在 mmt_soc_subsystem.v / mmt_top.v 各补几行连接，
    //      补丁见 docs\测试图案注入.md §5。
    input  wire [15:0] vid_lines_per_frame,   // 一帧内 hs 上升沿个数
    input  wire [15:0] vid_pixels_per_line,   // 一行内 de 拍数
    input  wire [15:0] vid_frame_cnt,         // 上电以来 vs 个数
    input  wire [31:0] dbg_fb_sb,             // 调试：frame_buffer 写侧粘滞位（i_clk 域，直接采样）
    input  wire [31:0] dbg_fb_sb2,            // 调试：ddr_wr_buffer 写 FSM 粘滞位（axi_clk 域，直接采样）

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
    output reg  [7:0]  osd_th_data,

    // ---------------- ★ 摄像头上游探针的读口（task-19）----------------
    //   探针模块 mmt_cam_probe 实例化在 mmt_top（那些域的信号/时钟都在那边），
    //   这里只负责：把 APB 地址 0x80..0xA4 翻译成探针的 raddr，并把它的
    //   rdata 混进读数据。两者都在 core_clk 域，是**纯组合**通路，不需要 CDC。
    //   ⚠️ 需要 mmt_soc_subsystem.v / mmt_top.v 各补几行连接，
    //      补丁见 docs\上板判据-摄像头上游探针.md §2。
    output wire [3:0]  cam_probe_raddr,      // 0..9 ⇒ 0x80..0xA4
    input  wire [31:0] cam_probe_rdata,

    // ---------------- ★ 测试图案注入配置（task-23 / M0）----------------
    //   复位默认 **en=0 / mode=0 = 摄像头**，保证不改变现有行为。
    //   en=1 后 mmt_top 上的多路选择器把 checker0 的 i_clk/i_vs/i_de/vin
    //   一起切到 mmt_test_pattern（**连时钟一起切**）。
    //   写 0xC8: bit0 = en, bits[2:1] = mode (0=彩条+方块 1=红场 2=绿场 3=蓝场)
    output reg         test_pattern_en,
    output reg  [1:0]  test_pattern_mode
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
    // ★ 帧缓冲写通路握手计数（2026-10-12 新增）—— 上板判据
    //----------------------------------------------------------------------
    // 为什么要这两个计数器：
    //   Efinity 曾经把 frame_buffer 写通路静默折成常量（mmt_top.v:1141-1142 记了这件事），
    //   现在靠 (* preserve, syn_keep=1 *) 绕过。但"静态报告 PASS"**不等于**
    //   "运行时真的发生了 AXI 握手" —— 这两个计数器就是运行时的硬证据：
    //   串口读出来只要在涨，就说明写通道真的在跑。
    //
    // 为什么要 preserve/syn_keep：
    //   计数器本身被 PRDATA 读到、不会被删；但它的**输入** fb_* 若被工具视为
    //   "只喂给可优化逻辑"，仍可能被折成常量（这正是之前踩的坑）。
    //   加上属性后综合器必须保留这段时序逻辑以及驱动它的路径。
    //   （本模块用的就是 Efinity；Xilinx 的等价属性是 dont_touch，不通用，别混写。）
    (* preserve, syn_keep = 1 *) reg [31:0] fb_aw_cnt;
    (* preserve, syn_keep = 1 *) reg [31:0] fb_w_cnt;
    // "曾经握手过"的粘滞位：只读一次串口时，比"计数器是否非零"更抗误判
    //（例如计数器刚好被读过、或两次读数之间没变化）
    (* preserve, syn_keep = 1 *) reg        fb_aw_seen;
    (* preserve, syn_keep = 1 *) reg        fb_w_seen;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fb_aw_cnt  <= 32'd0;
            fb_w_cnt   <= 32'd0;
            fb_aw_seen <= 1'b0;
            fb_w_seen  <= 1'b0;
        end else begin
            if (fb_awvalid && fb_awready) begin
                fb_aw_cnt  <= fb_aw_cnt + 32'd1;
                fb_aw_seen <= 1'b1;
            end
            if (fb_wvalid && fb_wready) begin
                fb_w_cnt  <= fb_w_cnt + 32'd1;
                fb_w_seen <= 1'b1;
            end
        end
    end

    //----------------------------------------------------------------------
    // ★ 最大写地址 FB_AWADDR_MAX（task-22）—— 验证"帧步长修复"是否真的进了位流
    //----------------------------------------------------------------------
    // 为什么需要它：握手计数只说明"写通道在跑"，**不说明写到哪里**。
    //   帧步长参数漏转发的 bug（见 docs\帧步长修复-DDR分区对齐.md）会让三个 bank 的
    //   基址差一倍：坏版本 = 0x02000000 / 0x027E9200 / 0x02FD2400（bank2 写进
    //   TinyML 张量区），修好后 = 0x02000000 / 0x023F4A00 / 0x027E9400。
    //   两者的**最大写地址**差得很远，所以"取历史最大 awaddr"就是最直接的硬件判据。
    //
    // ⚠️ Claude 审查特别提醒过的那一点，这里用**两个**信息一起解决：
    //   "最大地址读到 0" **不等于** "没越界" —— 没出图时它本来就是 0。
    //   所以另配一个**采样次数**（饱和）与两个粘滞位：
    //     fb_aw_smp  : 采样到多少次 AW 握手（饱和在 0xFFFF，不绕回）
    //     fb_aw_seen : 至少采样过一次     → 区分"没出图"与"出了图但地址是 0"
    //     fb_aw_nz  : 曾采到非 0 地址     → 进一步确认地址真在动
    (* preserve, syn_keep = 1 *) reg [31:0] fb_awaddr_max;
    (* preserve, syn_keep = 1 *) reg [15:0] fb_aw_smp;
    (* preserve, syn_keep = 1 *) reg        fb_aw_nz;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fb_awaddr_max <= 32'd0;
            fb_aw_smp     <= 16'd0;
            fb_aw_nz      <= 1'b0;
        end else if (fb_awvalid && fb_awready) begin
            // 只在**握手那一拍**取样：AXI 规定此时 awaddr 必然有效
            if (fb_awaddr > fb_awaddr_max) fb_awaddr_max <= fb_awaddr;   // 只保留历史最大
            if (fb_aw_smp != 16'hFFFF)     fb_aw_smp     <= fb_aw_smp + 16'd1;  // 饱和，不绕回
            if (fb_awaddr != 32'd0)        fb_aw_nz      <= 1'b1;
        end
    end

    //----------------------------------------------------------------------
    // ★ 视频帧翻转计数（0x7C）—— 上板判据的"免接线"那一半
    //----------------------------------------------------------------------
    // motion_frame_tgl 是算法子系统在视频域每完成一帧翻转一次的标志，
    // 而且它**本来就是本模块的输入**（见端口表）——所以这一个计数器
    // **不需要任何顶层接线**，只要重编位流就能用。
    // 它的意义：串口上这个数在涨 ⇒ 视频通路确实在出帧（详见判据文档 §4）。
    (* preserve, syn_keep = 1 *) reg [31:0] frame_tgl_cnt;
    reg frame_tgl_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            frame_tgl_cnt <= 32'd0;
            frame_tgl_d   <= 1'b0;
        end else begin
            frame_tgl_d <= motion_frame_tgl;
            if (motion_frame_tgl != frame_tgl_d)
                frame_tgl_cnt <= frame_tgl_cnt + 32'd1;
        end
    end

    //----------------------------------------------------------------------
    // ★ 摄像头上游探针的地址译码（task-19；**上界 task-24 修正**）
    //----------------------------------------------------------------------
    //   探针 mmt_cam_probe 在 mmt_top 里实例化，它的寄存器表用 raddr(0..15) 索引；
    //   这里把 APB 地址线性映射过去，区间外照旧返回 0。
    //   ⚠️ 必须用 PADDR[7:2]（0x80>>2 = 32），**不是** PADDR[5:2]（那是 0x80 的 bit7 抹掉后的 0）。
    //   ★ 上界必须是 **47（0xBC）**，正好覆盖探针全部 16 个寄存器（raddr 0..15）：
    //     · 若写到 49（0xC4）：0xC0/0xC4 会算出 raddr 16/17，被 4 位宽**截成 0/1**
    //       ⇒ 别名回 CAM_SCL_CNT / CAM_CK_CNT（task-24 查出的缺陷）；
    //     · 收到 47 后 0xC0/0xC4 不满足 probe_sel ⇒ 落到 default 返回 0（安全）。
    //   ★ 前提：FB_AWADDR_MAX / FB_AW_STAT 已从 0xA8/0xAC 移到 0xD8/0xDC ——
    //     否则它们的显式 case（优先于 default）会把 raddr 10/11 挡死。
    wire [5:0] probe_word  = PADDR[7:2];       // 0x80→32, 0x84→33, … 0xBC→47
    wire       probe_sel   = (PADDR[15:8] == 8'd0) &&
                             (probe_word >= 6'd32) && (probe_word <= 6'd47) &&
                             (PADDR[1:0] == 2'b00);
    assign cam_probe_raddr = probe_word - 6'd32;   // 32-32=0 … 47-32=15（正好不溢出 4 位）

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
            // ---- ★ 上板判据（2026-10-12 新增）----
            // 0x6C/0x70：写通路握手累计数（只增）
            16'h006C: PRDATA = fb_aw_cnt;
            16'h0070: PRDATA = fb_w_cnt;
            // 0x74：当前电平 + 粘滞标志
            //       bit0=fb_awvalid 电平  bit1=fb_awready 电平
            //       bit2=fb_wvalid  电平  bit3=fb_wready  电平
            //       bit4=曾发生 AW 握手  bit5=曾发生 W 握手
            16'h0074: PRDATA = {26'd0, fb_w_seen, fb_aw_seen,
                                       fb_wready, fb_wvalid, fb_awready, fb_awvalid};
            // 0x78：**完整的视觉字节**（[31:24]=conf_vision 8 位）
            //       为什么要新开一个：0x28 的拼接是 46 位被截断，[31:24] 实际只有
            //       conf_vision[0] 一位（详见 docs\上板判据-写通路握手计数.md §3）。
            //       这里 8+8+8+8 = 32 位，不再截断，且**不动 0x28 的既有映射**。
            16'h0078: PRDATA = {conf_vision, conf_temp, conf_env, 8'd0};
            // 0x7C：视频帧翻转次数（motion_frame_tgl 的跳变次数）。
            //       这个计数器**不需要顶层接线**（信号本来就是本模块输入），
            //       重编位流即可用；用来回答"视频/摄像头通路在不在出帧"。
            16'h007C: PRDATA = frame_tgl_cnt;
            // ---- ★ 最大写地址判据（task-22）----
            // ★ 2026-10-13（task-24 复查后修正）：这两个寄存器原先在 0xA8/0xAC，
            //   正好插在探针的线性窗口（0x80..0xBC）里 ⇒ 显式 case 优先于 default，
            //   把探针 raddr 10/11（PROBE_ID / CSI_PD_CNT）挡死。现移到空闲的 0xD8/0xDC。
            // 0xD8：历史最大 fb_awaddr（只在 AW 握手那拍取样，单调不减）
            16'h00D8: PRDATA = fb_awaddr_max;
            // 0xDC：采样信息 —— 判据必须与 0xD8 **联合**读，否则"没出图"会被误当成"没越界"
            //       [15:0]=采样次数（饱和 0xFFFF） [16]=至少采样过一次 [17]=曾采到非 0 地址
            16'h00DC: PRDATA = {14'd0, fb_aw_nz, (fb_aw_smp != 16'd0), fb_aw_smp};
            // ---- ★ 测试图案 + 视频时序计数（task-23 / M0）----
            // 0xC8：测试图案配置回读 —— [0]=en  [2:1]=mode
            //       复位后读到 0 ⇒ 默认是摄像头，可据此确认"没被误切"
            16'h00C8: PRDATA = {29'd0, test_pattern_mode, test_pattern_en};
            // 0xCC：LINES_PER_FRAME —— 一帧内 hs 上升沿个数
            //       摄像头 1080p 正常应 ≈1080；明显偏小/为 0 ⇒ vs 之间没有行
            16'h00CC: PRDATA = {16'd0, vid_lines_per_frame};
            // 0xD0：PIXELS_PER_LINE —— 一行内 de 拍数
            //       4 像素/拍时 1920 宽应 ≈480；为 0 ⇒ 该行没有 de
            16'h00D0: PRDATA = {16'd0, vid_pixels_per_line};
            // 0xD4：上电以来 vs 个数 —— **判断"到底有没有在出帧"的第一手依据**
            //       不增长 ⇒ 根本没有 vs（摄像头没出图 / 图案没在跑）
            16'h00D4: PRDATA = {16'd0, vid_frame_cnt};
            // 0xE0：★ 调试观测寄存器（非产品功能）—— frame_buffer 写侧粘滞"曾经发生过"位
            //       [0]=wr_fifo_wren [1]=frame_start [2]=frame_stable
            //       [3]=frame_start&frame_stable(wr_start) [4]=wr_fifo_wrfull
            //       i_clk 域直接被 core_clk 采样；复位后清零
            16'h00E0: PRDATA = dbg_fb_sb;
            // 0xE4：★ 调试观测 —— ddr_wr_buffer 写 FSM 粘滞位
            //       [0]=pos_sync [1]=state1 [2]=wr_req [3]=state2 [4]=awready [5]=rdusedw!=0
            //       [6]=wr_fifo_rden [7]=state3；[23:16]=wr_fifo_rdusedw[7:0] 当前值（非粘滞）
            16'h00E4: PRDATA = dbg_fb_sb2;
            // ---- ★ 摄像头上游探针（task-19）：探针窗口 0x80..0xBC → raddr 0..15 ----
            //   这里不逐个写 case，而是把这个区间整体交给探针自己的读口，
            //   这样"探针寄存器表"只在一个文件里维护（mmt_cam_probe.v）。
            //   0x80⇒0, 0x84⇒1, … 0xBC⇒15；窗口外（含 0xC0/0xC4）返回 0。
            default:  PRDATA = probe_sel ? cam_probe_rdata : 32'h0;
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

    //------------------------------------------------------------------
    //  ★ 测试图案配置寄存器（task-23 / M0）
    //    单独一个 always 块，**不去动既有的写译码 case**（降低回归风险）。
    //    复位默认 0 = 摄像头 ⇒ 增量行为为零。
    //------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            test_pattern_en   <= 1'b0;
            test_pattern_mode <= 2'd0;
        end else if (wr && (PADDR == 16'h00C8)) begin
            test_pattern_en   <= PWDATA[0];
            test_pattern_mode <= PWDATA[2:1];
        end
    end

endmodule
