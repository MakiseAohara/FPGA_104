//==========================================================================
//  mmt_soc_subsystem.v  —  Sapphire RISC-V 软核子系统
//--------------------------------------------------------------------------
//  把以下三样打包成一个干净的模块，供顶层实例化：
//    1) sapphire_soc     ：Efinix 官方 RISC-V 软核 SoC（IP，网表形式）
//    2) mmt_soc_regs     ：APB3 寄存器桥（SoC 与 FPGA 硬件之间的窗口）
//    3) 未用外设的信号端接：I2C0 / GPIO0 本方案不用，按要求接固定电平
//
//  对外只暴露真正需要的东西：
//    · 时钟 / 复位
//    · UART（软核打印调试信息用，接板载 FT4232HL 的串口）
//    · **SPI0**（路线 B：软核读板载 SPI flash，把 app+模型搬进 DDR）
//    · DDR AXI4 主口（io_ddrA_*，128 位全双工，接顶层 AXI 互联）
//    · 寄存器桥的两组线：只读的传感器/算法结果、可写的配置
//
//  ⚠️ 关于 AXI 主口：
//     路线 B 已把 io_ddrA_* 接到顶层 AXI 互联（s1 口），与 frame_buffer(s0)、TinyML(s2) 汇到 DDR3。
//
//  ⚠️ 若后续要用 I2C0：注意本方案用我们自己写的 I2C 硬件（mmt_i2c_master + hub），
//     软核侧不需要用 SoC 自带的 I2C0 控制器，所以这里把它端接了。
//==========================================================================
`timescale 1ns / 1ps

module mmt_soc_subsystem (
    input  wire        clk,             // 系统时钟，100MHz（接顶层的 core_clk / i_soc_clk）
    input  wire        rst_n,           // 低有效异步复位

    // ---- UART（接板载串口）----
    output wire        uart_txd,
    input  wire        uart_rxd,

    // ---- SPI0（路线 B 新增：RISC-V 靠它读板载 flash，把 app+模型搬进 DDR）----
    //   这 4 根在板上同时是**上电配置脚**（active 模式下 CDI0/CDI1/CCK/SSL_N 从 flash 读位流），
    //   配置完成后交还给用户逻辑 —— 与厂商 TinyML 参考设计 edge_vision_soc.peri.xml:236-250 同做法。
    //   data_0/data_1 是双向（单线模式 data_0=MOSI、data_1=MISO；dual 模式下都双向），
    //   顶层用 writeEnable 做三态，这里只把 SoC 的三根分线引出去。
    input  wire        spi_data0_read,
    output wire        spi_data0_write,
    output wire        spi_data0_writeEnable,
    input  wire        spi_data1_read,
    output wire        spi_data1_write,
    output wire        spi_data1_writeEnable,
    output wire        spi_sclk,
    output wire [0:0]  spi_ss,

    // ---- JTAG 调试（接芯片 JTAG，可选）----
    input  wire        jtag_enable,
    input  wire        jtag_tdi,
    input  wire        jtag_capture,
    input  wire        jtag_shift,
    input  wire        jtag_update,
    input  wire        jtag_reset,
    input  wire        jtag_tck,
    output wire        jtag_tdo,

    // ---- AXI 主口（留给 DDR3；当前未接）----
    output wire [31:0] axim_awaddr,
    output wire [7:0]  axim_awlen,
    output wire [2:0]  axim_awsize,
    output wire [1:0]  axim_awburst,
    output wire        axim_awlock,
    output wire [3:0]  axim_awcache,
    output wire [3:0]  axim_awqos,
    output wire [2:0]  axim_awprot,
    output wire [3:0]  axim_awregion,
    output wire [7:0]  axim_awid,
    output wire        axim_awvalid,
    input  wire        axim_awready,
    output wire [31:0] axim_wdata,
    output wire [3:0]  axim_wstrb,
    output wire        axim_wlast,
    output wire        axim_wvalid,
    input  wire        axim_wready,
    input  wire [7:0]  axim_bid,
    input  wire [1:0]  axim_bresp,
    input  wire        axim_bvalid,
    output wire        axim_bready,
    output wire [31:0] axim_araddr,
    output wire [7:0]  axim_arlen,
    output wire [2:0]  axim_arsize,
    output wire [1:0]  axim_arburst,
    output wire        axim_arlock,
    output wire [3:0]  axim_arcache,
    output wire [3:0]  axim_arqos,
    output wire [2:0]  axim_arprot,
    output wire [3:0]  axim_arregion,
    output wire [7:0]  axim_arid,
    output wire        axim_arvalid,
    input  wire        axim_arready,
    input  wire [31:0] axim_rdata,
    input  wire [7:0]  axim_rid,
    input  wire [1:0]  axim_rresp,
    input  wire        axim_rlast,
    input  wire        axim_rvalid,
    output wire        axim_rready,

    // ---- DDR AXI4 主口（SoC 的 io_ddrA_*，128 位全双工）----
    //   路线 B 新增：SoC 打开 DDR 后，CPU 对 DDR 的访问从这里出去，
    //   经 mmt_top 里的 AXI 互联（3 主口→1 从口）汇到 DDR3 控制器。
    //   注意 ID 位宽：SoC 出 8 位，DDR3 控制器只有 4 位 —— 顶层截断，
    //   这与厂商自己的 ddr_demo_ti60 做法一致（s_axi_awid 声明为 4 位）。
    output wire        ddrm_awvalid,
    output wire [31:0] ddrm_awaddr,
    output wire [7:0]  ddrm_awlen,
    output wire [2:0]  ddrm_awsize,
    output wire [1:0]  ddrm_awburst,
    output wire [1:0]  ddrm_awlock,
    output wire [3:0]  ddrm_awcache,
    output wire [2:0]  ddrm_awprot,
    output wire [3:0]  ddrm_awqos,
    output wire [3:0]  ddrm_awregion,
    output wire [7:0]  ddrm_awid,
    input  wire        ddrm_awready,
    output wire [127:0] ddrm_wdata,
    output wire [15:0] ddrm_wstrb,
    output wire        ddrm_wlast,
    output wire        ddrm_wvalid,
    input  wire        ddrm_wready,
    input  wire [1:0]  ddrm_bresp,
    input  wire [7:0]  ddrm_bid,
    input  wire        ddrm_bvalid,
    output wire        ddrm_bready,
    output wire        ddrm_arvalid,
    output wire [31:0] ddrm_araddr,
    output wire [7:0]  ddrm_arlen,
    output wire [2:0]  ddrm_arsize,
    output wire [1:0]  ddrm_arburst,
    output wire [1:0]  ddrm_arlock,
    output wire [3:0]  ddrm_arcache,
    output wire [2:0]  ddrm_arprot,
    output wire [3:0]  ddrm_arqos,
    output wire [3:0]  ddrm_arregion,
    output wire [7:0]  ddrm_arid,
    input  wire        ddrm_arready,
    input  wire [127:0] ddrm_rdata,
    input  wire [1:0]  ddrm_rresp,
    input  wire [7:0]  ddrm_rid,
    input  wire        ddrm_rlast,
    input  wire        ddrm_rvalid,
    output wire        ddrm_rready,

    // ---- 自定义指令口（SoC ↔ TinyML 加速器）----
    //   方向按 sapphire_soc.v 实测：cmd_valid/function_id/inputs_*/rsp_ready 是 SoC 输出。
    output wire        ci_cmd_valid,
    output wire [9:0]  ci_function_id,
    output wire [31:0] ci_inputs_0,
    output wire [31:0] ci_inputs_1,
    output wire        ci_rsp_ready,
    input  wire        ci_cmd_ready,
    // ★ 加速器完成中断（来自 tinyml_accelerator_channels 的 cmd_int）。
    //   2026-10-15 修复：原先这里没有这个端口，userInterruptA 被硬接 1'b0。
    //   反汇编证据（官方 tinyml_lib.a 的 conv.o）：
    //     conv_drv  : 67c: lw x27,0(x18) / 680: beqz x27,67c   ← 自旋等 .LANCHOR0[hart]
    //     conv_intr : 44: sw x31,0(x30)                        ← 唯一把该标志置 1 的地方
    //   即 ISR 是唯一唤醒源；userInterruptA 恒 0 ⇒ ISR 永不进 ⇒ 推理调用永久卡死。
    //   官方 tinyml_soc.v:473 就是 assign userInterruptA = cpu_customInstruction_cmd_int;
    input  wire        ci_cmd_int,
    input  wire        ci_rsp_valid,
    input  wire [31:0] ci_outputs_0,

    // ---- 寄存器桥：只读输入（来自传感器/算法子系统）----
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
    input  wire [15:0] ir_rd_data,
    input  wire        motion_frame_done,
    input  wire        motion_frame_tgl,      // 帧翻转标志（视频域生成，已同步）
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

    // ---- 寄存器桥：可写输出（配置给硬件/融合模块）----
    output wire [7:0]  diff_threshold,
    output wire [15:0] diff_min_area,
    output wire [7:0]  score_thresh,
    output wire [4:0]  auth_start_h,
    output wire [4:0]  auth_end_h,
    output wire [4:0]  hour,
    output wire [7:0]  vision_prob,
    output wire        vision_valid,
    output wire signed [15:0] body_max_c_x10,
    output wire        ir_valid,
    output wire signed [15:0] ambient_c_x10,
    output wire        env_valid,
    output wire        diff_enable,
    output wire        bg_freeze,
    output wire        bg_clear_tgl,   // 翻转式清背景请求（单比特跨域安全）
    output wire        alarm_mute,
    output wire [9:0]  ir_frame_addr,
    output wire [15:0] rh_x100_fwd,          // 软核转发给融合模块的湿度
    // ---- OSD 显示缓冲写口 ----
    output wire        osd_txt_we,
    output wire [7:0]  osd_txt_addr,
    output wire [7:0]  osd_txt_data,
    output wire        osd_th_we,
    output wire [9:0]  osd_th_addr,
    output wire [7:0]  osd_th_data,
    // ---- ★ task-16：帧缓冲写通路握手（从 mmt_top 引进来给寄存器块计数）----
    input  wire        fb_awvalid,
    input  wire        fb_awready,
    input  wire        fb_wvalid,
    input  wire        fb_wready,
    // ---- ★ task-22：最大写地址观察（fb_awaddr 已在顶层接互联与 checker0）----
    input  wire [31:0] fb_awaddr,
    // ---- ★ task-19：摄像头上游探针读口（→ mmt_soc_regs 的 0x80..0xA4）----
    output wire [3:0]  cam_probe_raddr,
    input  wire [31:0] cam_probe_rdata,
    // ---- ★ task-23：测试图案控制（出）/ 视频测量（入）----
    output wire        test_pattern_en,
    output wire [1:0]  test_pattern_mode,
    input  wire [15:0] vid_lines_per_frame,
    input  wire [15:0] vid_pixels_per_line,
    input  wire [15:0] vid_frame_cnt,
    // ---- 调试：frame_buffer 写侧粘滞位（→ mmt_soc_regs 0xE0）----
    input  wire [31:0] dbg_fb_sb,
    input  wire [31:0] dbg_fb_sb2,   // 调试：ddr_wr_buffer 写 FSM 粘滞位（→ 0xE4）
    output wire        ir_rd_addr_clk_unused
);

    //----------------------------------------------------------------------
    // APB3 连线
    //----------------------------------------------------------------------
    wire [15:0] apb_PADDR;
    wire        apb_PENABLE;
    wire [31:0] apb_PRDATA;
    wire        apb_PREADY;
    wire        apb_PSEL;
    wire        apb_PSLVERROR;
    wire [31:0] apb_PWDATA;
    wire        apb_PWRITE;

    wire        soc_system_reset;

    // soc_system_reset 由 SoC 的 io_systemReset 输出驱动（它是 output，见
    //      ip/sapphire_soc/sapphire_soc.v:163），下面 L474 处消费它来消化未用信号。
    //      ⚠️ 曾经在这里写过 assign soc_system_reset = ~rst_n; —— 那是错的：
    //      io_systemReset 是 SoC 的**输出**，再加一个 assign 就是两个驱动源
    //      （VDB-1000 多驱动）。已撤销。

    //----------------------------------------------------------------------
    // Sapphire SoC
    //----------------------------------------------------------------------
    sapphire_soc u_sapphire_soc (
        .io_systemClk   (clk),
        .io_asyncReset  (~rst_n),
        .io_systemReset (soc_system_reset),

        // APB Slave 0 → 我们的寄存器桥
        .io_apbSlave_0_PADDR    (apb_PADDR),
        .io_apbSlave_0_PENABLE  (apb_PENABLE),
        .io_apbSlave_0_PRDATA   (apb_PRDATA),
        .io_apbSlave_0_PREADY   (apb_PREADY),
        .io_apbSlave_0_PSEL     (apb_PSEL),
        .io_apbSlave_0_PSLVERROR(apb_PSLVERROR),
        .io_apbSlave_0_PWDATA   (apb_PWDATA),
        .io_apbSlave_0_PWRITE   (apb_PWRITE),

        // AXI 主口（对外引出，当前未接 DDR3）
        .axiA_awaddr    (axim_awaddr),
        .axiA_awlen     (axim_awlen),
        .axiA_awsize    (axim_awsize),
        .axiA_awburst   (axim_awburst),
        .axiA_awlock    (axim_awlock),
        .axiA_awcache   (axim_awcache),
        .axiA_awqos     (axim_awqos),
        .axiA_awprot    (axim_awprot),
        .axiA_awregion  (axim_awregion),
        .axiA_awid      (axim_awid),
        .axiA_awvalid   (axim_awvalid),
        .axiA_awready   (axim_awready),
        .axiA_wdata     (axim_wdata),
        .axiA_wstrb     (axim_wstrb),
        .axiA_wlast     (axim_wlast),
        .axiA_wvalid    (axim_wvalid),
        .axiA_wready    (axim_wready),
        .axiA_bid       (axim_bid),
        .axiA_bresp     (axim_bresp),
        .axiA_bvalid    (axim_bvalid),
        .axiA_bready    (axim_bready),
        .axiA_araddr    (axim_araddr),
        .axiA_arlen     (axim_arlen),
        .axiA_arsize    (axim_arsize),
        .axiA_arburst   (axim_arburst),
        .axiA_arlock    (axim_arlock),
        .axiA_arcache   (axim_arcache),
        .axiA_arqos     (axim_arqos),
        .axiA_arprot    (axim_arprot),
        .axiA_arregion  (axim_arregion),
        .axiA_arid      (axim_arid),
        .axiA_arvalid   (axim_arvalid),
        .axiA_arready   (axim_arready),
        .axiA_rdata     (axim_rdata),
        .axiA_rid       (axim_rid),
        .axiA_rresp     (axim_rresp),
        .axiA_rlast     (axim_rlast),
        .axiA_rvalid    (axim_rvalid),
        .axiA_rready    (axim_rready),
        .axiAInterrupt  (1'b0),

        // ------------------------------------------------------------------
        // ★ 自定义指令端口（TinyML 加速器专用）
        //   这几个端口只有 SoC 参数 CustomInstruction=1 时才会生成。
        //   Efinix TinyML 加速器的命令口就直连在这里（见 tinyml 仓库
        //   tinyml_vision\Ti60F225_*_demo\edge_vision_soc.v:1116）：
        //       .cmd_valid(cpu_customInstruction_cmd_valid)  ...
        //
        //   ★★ 端口方向（读 sapphire_soc.v 得到，不要凭"名字像输入"猜）：
        //        output       cpu0_customInstruction_cmd_valid     ┐
        //        output [9:0] cpu0_customInstruction_function_id   │ SoC → 加速器
        //        output [31:0] cpu0_customInstruction_inputs_0     │
        //        output [31:0] cpu0_customInstruction_inputs_1     │
        //        output       cpu0_customInstruction_rsp_ready     ┘
        //        input        cpu0_customInstruction_cmd_ready     ┐
        //        input        cpu0_customInstruction_rsp_valid     │ 加速器 → SoC
        //        input  [31:0] cpu0_customInstruction_outputs_0    ┘
        //     给 output 端口接常量会被 Efinity 判为 "constant is not allowed
        //     here"（VERI-1180）——这个错本轮实际踩到过。
        //
        //   ⚠️ 现状：加速器 RTL 还没实例化，这里把**SoC 的输入**端接到"永远就绪、
        //      无响应"，SoC 的输出悬空。绝不能让输入悬空：悬空是 z，会在 SoC
        //      内部引起 x 传播。
        //      固件目前不发自定义指令，所以端接是安全的。
        //      接加速器时：cmd_ready/rsp_valid/outputs_0 改接加速器输出，
        //      其余 5 个改接加速器输入。
        // ------------------------------------------------------------------
        .cpu0_customInstruction_cmd_ready   (ci_cmd_ready),
        .cpu0_customInstruction_rsp_valid   (ci_rsp_valid),
        .cpu0_customInstruction_outputs_0   (ci_outputs_0),
        .cpu0_customInstruction_cmd_valid   (ci_cmd_valid),
        .cpu0_customInstruction_function_id (ci_function_id),
        .cpu0_customInstruction_inputs_0    (ci_inputs_0),
        .cpu0_customInstruction_inputs_1    (ci_inputs_1),
        .cpu0_customInstruction_rsp_ready   (ci_rsp_ready),

        // ------------------------------------------------------------------
        // ★ DDR 内存域（路线 B 新增）
        //   io_memoryClk 是 input（SoC 内部 DDR 通路的时钟，接系统时钟即可）；
        //   io_memoryReset 是 **output**（sapphire_soc.v:165），不能由我们驱动 ——
        //   厂商 ddr_demo_ti60 就是留空的，照做。
        //   因为 memoryClk == systemClk，这条路径不跨时钟域，不需要 CDC。
        // ------------------------------------------------------------------
        .io_memoryClk   (clk),
        .io_memoryReset (),

        // SoC → DDR3 控制器的 AXI4 主口（128 位；ID 8 位，顶层截成 4 位）
        .io_ddrA_aw_valid           (ddrm_awvalid),
        .io_ddrA_aw_payload_addr    (ddrm_awaddr),
        .io_ddrA_aw_payload_len     (ddrm_awlen),
        .io_ddrA_aw_payload_size    (ddrm_awsize),
        .io_ddrA_aw_payload_burst   (ddrm_awburst),
        .io_ddrA_aw_payload_lock    (ddrm_awlock),
        .io_ddrA_aw_payload_cache   (ddrm_awcache),
        .io_ddrA_aw_payload_prot    (ddrm_awprot),
        .io_ddrA_aw_payload_qos     (ddrm_awqos),
        .io_ddrA_aw_payload_region  (ddrm_awregion),
        .io_ddrA_aw_payload_id      (ddrm_awid),
        .io_ddrA_aw_ready           (ddrm_awready),
        .io_ddrA_w_valid            (ddrm_wvalid),
        .io_ddrA_w_payload_data     (ddrm_wdata),
        .io_ddrA_w_payload_strb     (ddrm_wstrb),
        .io_ddrA_w_payload_last     (ddrm_wlast),
        .io_ddrA_w_ready            (ddrm_wready),
        .io_ddrA_b_valid            (ddrm_bvalid),
        .io_ddrA_b_payload_resp     (ddrm_bresp),
        .io_ddrA_b_payload_id       (ddrm_bid),
        .io_ddrA_b_ready            (ddrm_bready),
        .io_ddrA_ar_valid           (ddrm_arvalid),
        .io_ddrA_ar_payload_addr    (ddrm_araddr),
        .io_ddrA_ar_payload_len     (ddrm_arlen),
        .io_ddrA_ar_payload_size    (ddrm_arsize),
        .io_ddrA_ar_payload_burst   (ddrm_arburst),
        .io_ddrA_ar_payload_lock    (ddrm_arlock),
        .io_ddrA_ar_payload_cache   (ddrm_arcache),
        .io_ddrA_ar_payload_prot    (ddrm_arprot),
        .io_ddrA_ar_payload_qos     (ddrm_arqos),
        .io_ddrA_ar_payload_region  (ddrm_arregion),
        .io_ddrA_ar_payload_id      (ddrm_arid),
        .io_ddrA_ar_ready           (ddrm_arready),
        .io_ddrA_r_valid            (ddrm_rvalid),
        .io_ddrA_r_payload_data     (ddrm_rdata),
        .io_ddrA_r_payload_resp     (ddrm_rresp),
        .io_ddrA_r_payload_id       (ddrm_rid),
        .io_ddrA_r_payload_last     (ddrm_rlast),
        .io_ddrA_r_ready            (ddrm_rready),

        // UART0
        .system_uart_0_io_txd (uart_txd),
        .system_uart_0_io_rxd (uart_rxd),

        // JTAG 调试
        .jtagCtrl_enable  (jtag_enable),
        .jtagCtrl_tdi     (jtag_tdi),
        .jtagCtrl_capture (jtag_capture),
        .jtagCtrl_shift   (jtag_shift),
        .jtagCtrl_update  (jtag_update),
        .jtagCtrl_reset   (jtag_reset),
        .jtagCtrl_tck     (jtag_tck),
        .jtagCtrl_tdo     (jtag_tdo),

        // ---- 外设端接 ----
        // SPI0：**已引到顶层引脚**（路线 B：RISC-V 读板载 flash，把 app+模型搬进 DDR）。
        //       单线模式只用 data_0/data_1，data_2/data_3 继续端接。
        .system_spi_0_io_data_0_read        (spi_data0_read),
        .system_spi_0_io_data_0_write       (spi_data0_write),
        .system_spi_0_io_data_0_writeEnable (spi_data0_writeEnable),
        .system_spi_0_io_data_1_read        (spi_data1_read),
        .system_spi_0_io_data_1_write       (spi_data1_write),
        .system_spi_0_io_data_1_writeEnable (spi_data1_writeEnable),
        .system_spi_0_io_data_2_read        (1'b0),
        .system_spi_0_io_data_3_read        (1'b0),
        .system_spi_0_io_data_2_write       (),
        .system_spi_0_io_data_2_writeEnable (),
        .system_spi_0_io_data_3_write       (),
        .system_spi_0_io_data_3_writeEnable (),
        .system_spi_0_io_sclk_write         (spi_sclk),
        .system_spi_0_io_ss                 (spi_ss),

        // I2C0：不用（我们用自写的 I2C 硬件）。读回拉高表示总线空闲
        .system_i2c_0_io_scl_read  (1'b1),
        .system_i2c_0_io_sda_read  (1'b1),
        .system_i2c_0_io_scl_write (),
        .system_i2c_0_io_sda_write (),

        // GPIO0：不用
        .system_gpio_0_io_read        (4'b0),
        .system_gpio_0_io_write       (),
        .system_gpio_0_io_writeEnable (),

        // ★ 2026-10-15 修复：原先硬接 1'b0，导致加速器完成中断永远进不了 CPU。
        //   见端口表 ci_cmd_int 处的反汇编证据。
        .userInterruptA (ci_cmd_int)
    );

    //----------------------------------------------------------------------
    // APB3 寄存器桥
    //----------------------------------------------------------------------
    mmt_soc_regs u_soc_regs (
        .clk        (clk),
        .rst_n      (rst_n),
        .PADDR      (apb_PADDR),
        .PENABLE    (apb_PENABLE),
        .PWDATA     (apb_PWDATA),
        .PWRITE     (apb_PWRITE),
        .PSEL       (apb_PSEL),
        .PRDATA     (apb_PRDATA),
        .PREADY     (apb_PREADY),
        .PSLVERROR  (apb_PSLVERROR),

        .sht_data_valid (sht_data_valid),
        .sht_temp_c_x100(sht_temp_c_x100),
        .sht_rh_x100    (sht_rh_x100),
        .sht_temp_raw   (sht_temp_raw),
        .sht_rh_raw     (sht_rh_raw),
        .sht_crc_err    (sht_crc_err),
        .sht_bus_err    (sht_bus_err),

        .ir_frame_cnt   (ir_frame_cnt),
        .ir_frame_valid (ir_frame_valid),
        .ir_bus_err     (ir_bus_err),
        .ir_ta_raw      (ir_ta_raw),
        .ir_rd_data     (ir_rd_data),

        .motion_frame_done (motion_frame_done),
        .motion_frame_tgl  (motion_frame_tgl),
        .motion_sum_area   (motion_sum_area),
        .motion_sum_x      (motion_sum_x),
        .motion_sum_y      (motion_sum_y),
        .motion_flag       (motion_flag),
        .conf_vision       (conf_vision),
        .conf_temp         (conf_temp),
        .conf_env          (conf_env),
        .score             (score),
        .in_auth_window    (in_auth_window),
        .alarm             (alarm),

        .diff_threshold  (diff_threshold),
        .diff_min_area   (diff_min_area),
        .score_thresh    (score_thresh),
        .auth_start_h    (auth_start_h),
        .auth_end_h      (auth_end_h),
        .hour            (hour),
        .vision_prob     (vision_prob),
        .vision_valid    (vision_valid),
        .body_max_c_x10  (body_max_c_x10),
        .ir_valid        (ir_valid),
        .ambient_c_x10   (ambient_c_x10),
        .env_valid       (env_valid),
        .diff_enable     (diff_enable),
        .bg_freeze       (bg_freeze),
        .bg_clear_tgl    (bg_clear_tgl),
        .alarm_mute      (alarm_mute),
        .ir_frame_addr   (ir_frame_addr),
        .rh_x100_fwd     (rh_x100_fwd),
        .osd_txt_we      (osd_txt_we),
        .osd_txt_addr    (osd_txt_addr),
        .osd_txt_data    (osd_txt_data),
        .osd_th_we       (osd_th_we),
        .osd_th_addr     (osd_th_addr),
        .osd_th_data     (osd_th_data),
        // ---- ★ task-16：写通路握手计数输入 ----
        .fb_awvalid      (fb_awvalid),
        .fb_awready      (fb_awready),
        .fb_wvalid       (fb_wvalid),
        .fb_wready       (fb_wready),
        // ---- ★ task-22：最大写地址 ----
        .fb_awaddr       (fb_awaddr),
        // ---- ★ task-19：探针读口 ----
        .cam_probe_raddr (cam_probe_raddr),
        .cam_probe_rdata (cam_probe_rdata),
        // ---- ★ task-23 ----
        .test_pattern_en     (test_pattern_en),
        .test_pattern_mode   (test_pattern_mode),
        .vid_lines_per_frame (vid_lines_per_frame),
        .vid_pixels_per_line (vid_pixels_per_line),
        .vid_frame_cnt       (vid_frame_cnt),
        .dbg_fb_sb           (dbg_fb_sb),
        .dbg_fb_sb2          (dbg_fb_sb2)
    );

    // 未用信号，避免综合告警（soc_spi_ss 已改成顶层输出端口，不再需要在这里消化）
    assign ir_rd_addr_clk_unused = soc_system_reset;

endmodule
