//==========================================================================
//  mmt_sensor_subsystem.v  —  多模态传感器子系统（任务1 的采集侧）
//--------------------------------------------------------------------------
//  把下面这些接成一个可独立综合/验证的整体：
//      mmt_i2c_master          I2C 字节级主机（唯一的总线驱动者）
//      mmt_i2c_hub             I2C 分时复用控制器（赛题明确要求的那个模块）
//      mmt_sht30_ctrl          SHT30 温湿度（1Hz）
//      mmt_mlx90640_ctrl       MLX90640 红外原始帧（2Hz）
//      mmt_dpram               红外帧缓存（832×16），给 RISC-V 读
//
//  为什么要有这个封装：
//    1) 它让这四个模块真正被【实例化】，综合时才会做完整推演（只列进文件表
//       而不实例化，综合器会整块优化掉，等于没检查过——这个坑本工程踩过）；
//    2) 它给出"传感器采集侧到底占多少 XLR / BRAM"的真实数字，供资源预算用；
//    3) 以后新顶层里直接实例化这一个模块即可。
//
//  Hub 客户端编号约定：
//      idx 0 = SHT30
//      idx 1 = MLX90640
//      idx 2 = 预留（未连接，req 恒 0）
//
//  注：红外帧的【温度计算不在硬件里做】。算 Ta 与逐点目标温度需要 EEPROM 的
//      800+ 校准参数和大量运算，交给 RISC-V 跑 Melexis 官方 C 库
//      （见 任务C_传感器与算法原型报告.md）。这里只负责把原始 RAM 搬进 BRAM。
//==========================================================================
`timescale 1ns / 1ps

module mmt_sensor_subsystem #(
    parameter CLK_HZ           = 100_000_000,
    parameter SCL_HZ           = 100_000,
    parameter SHT30_ADDR       = 7'h44,
    parameter MLX90640_ADDR    = 7'h33,
    parameter SHT30_PERIOD_MS  = 1000,     // 1Hz
    parameter IR_PERIOD_MS     = 500       // 2Hz
)(
    input  wire         clk,
    input  wire         rst_n,

    // ---- I2C 物理接口（开漏，顶层接三态 buffer；外部需上拉电阻）----
    input  wire         scl_i,
    output wire         scl_o,
    output wire         scl_oe,
    input  wire         sda_i,
    output wire         sda_o,
    output wire         sda_oe,

    // ---- SHT30 结果（保持到下次成功测量）----
    output wire         sht_data_valid,
    output wire signed [15:0] sht_temp_c_x100,
    output wire [15:0]  sht_rh_x100,
    output wire [15:0]  sht_temp_raw,
    output wire [15:0]  sht_rh_raw,
    output wire         sht_crc_err,
    output wire         sht_bus_err,

    // ---- MLX90640 红外帧 ----
    output wire [15:0]  ir_frame_cnt,      // 已完成帧计数
    output wire         ir_frame_valid,    // 一帧写完脉冲
    output wire [15:0]  ir_ta_raw,         // frameData[800]（Ptat，不完整，见控制器注释）
    output wire         ir_bus_err,

    // ---- 红外帧缓存读口（给 RISC-V）----
    input  wire [9:0]   ir_rd_addr,
    output wire [15:0]  ir_rd_data,

    // ---- 观测/调试 ----
    output wire         i2c_busy,
    output wire [2:0]   i2c_owner        // 当前占用总线的客户端编号（one-hot）
);

    //======================================================================
    // I2C 主机
    //======================================================================
    wire        m_req;
    wire [6:0]  m_dev_addr;
    // MLX register writes contain a 16-bit address followed by a 16-bit value.
    // Match hub/master v2: narrowing tx_len makes a four-byte write length zero.
    wire [31:0] m_tx_data;
    wire [2:0]  m_tx_len;
    wire [7:0]  m_rd_len;
    wire        m_busy, m_done, m_err;
    wire [7:0]  m_rd_data;
    wire        m_rd_valid;

    mmt_i2c_master #(
        .CLK_HZ (CLK_HZ),
        .SCL_HZ (SCL_HZ)
    ) u_i2c_master (
        .clk       (clk),
        .rst_n     (rst_n),
        .req       (m_req),
        .dev_addr  (m_dev_addr),
        .tx_data   (m_tx_data),
        .tx_len    (m_tx_len),
        .rd_len    (m_rd_len),
        .busy      (m_busy),
        .done      (m_done),
        .err       (m_err),
        .rd_data   (m_rd_data),
        .rd_valid  (m_rd_valid),
        .scl_i     (scl_i),
        .scl_o     (scl_o),
        .scl_oe    (scl_oe),
        .sda_i     (sda_i),
        .sda_o     (sda_o),
        .sda_oe    (sda_oe)
    );

    //======================================================================
    // 分时复用 Hub（3 个客户端）
    //======================================================================
    wire [2:0]      h_req;
    wire [3*7-1:0]  h_dev_addr;    // 3 个客户端 × 7 位（曾误写成 2*，综合报 index out of range）
    wire [3*32-1:0] h_tx_data;
    wire [3*3-1:0]  h_tx_len;
    wire [3*8-1:0]  h_rd_len;
    wire [2:0]      h_grant, h_done, h_err;
    wire [3*8-1:0]  h_rd_data;
    wire [2:0]      h_rd_valid;

    mmt_i2c_hub #(
        .N (3)
    ) u_i2c_hub (
        .clk        (clk),
        .rst_n      (rst_n),
        .c_req      (h_req),
        .c_dev_addr (h_dev_addr),
        .c_tx_data  (h_tx_data),
        .c_tx_len   (h_tx_len),
        .c_rd_len   (h_rd_len),
        .c_grant    (h_grant),
        .c_done     (h_done),
        .c_err      (h_err),
        .c_rd_data  (h_rd_data),
        .c_rd_valid (h_rd_valid),
        .m_req      (m_req),
        .m_dev_addr (m_dev_addr),
        .m_tx_data  (m_tx_data),
        .m_tx_len   (m_tx_len),
        .m_rd_len   (m_rd_len),
        .m_busy     (m_busy),
        .m_done     (m_done),
        .m_err      (m_err),
        .m_rd_data  (m_rd_data),
        .m_rd_valid (m_rd_valid)
    );

    //======================================================================
    // 客户端 0：SHT30
    //======================================================================
    wire        s_req;
    wire [6:0]  s_dev;
    wire [31:0] s_tx;
    wire [2:0]  s_txl;
    wire [7:0]  s_rdl;

    assign h_req[0]      = s_req;
    assign h_dev_addr[0*7  +: 7]  = s_dev;
    assign h_tx_data [0*32 +: 32] = s_tx;
    assign h_tx_len  [0*3  +: 3]  = s_txl;
    assign h_rd_len  [0*8  +: 8]  = s_rdl;

    mmt_sht30_ctrl #(
        .CLK_HZ    (CLK_HZ),
        .I2C_ADDR  (SHT30_ADDR),
        .PERIOD_MS (SHT30_PERIOD_MS)
    ) u_sht30 (
        .clk          (clk),
        .rst_n        (rst_n),
        .data_valid   (sht_data_valid),
        .temp_c_x100  (sht_temp_c_x100),
        .rh_x100      (sht_rh_x100),
        .temp_raw     (sht_temp_raw),
        .rh_raw       (sht_rh_raw),
        .crc_err      (sht_crc_err),
        .bus_err      (sht_bus_err),
        .req          (s_req),
        .dev_addr     (s_dev),
        .tx_data      (s_tx),
        .tx_len       (s_txl),
        .rd_len       (s_rdl),
        .busy         (m_busy),
        .done         (h_done[0]),
        .err          (h_err[0]),
        .rd_data      (h_rd_data[0*8 +: 8]),
        .rd_valid     (h_rd_valid[0]),
        .hub_grant    (h_grant[0])
    );

    //======================================================================
    // 客户端 1：MLX90640
    //======================================================================
    wire        r_req;
    wire [6:0]  r_dev;
    wire [31:0] r_tx;
    wire [2:0]  r_txl;
    wire [7:0]  r_rdl;
    wire        ir_wr;
    wire [9:0]  ir_addr;
    wire [15:0] ir_data;

    assign h_req[1]      = r_req;
    assign h_dev_addr[1*7  +: 7]  = r_dev;
    assign h_tx_data [1*32 +: 32] = r_tx;
    assign h_tx_len  [1*3  +: 3]  = r_txl;
    assign h_rd_len  [1*8  +: 8]  = r_rdl;

    mmt_mlx90640_ctrl #(
        .CLK_HZ          (CLK_HZ),
        .I2C_ADDR        (MLX90640_ADDR),
        .FRAME_PERIOD_MS (IR_PERIOD_MS)
    ) u_mlx90640 (
        .clk          (clk),
        .rst_n        (rst_n),
        .frame_wr     (ir_wr),
        .frame_addr   (ir_addr),
        .frame_data   (ir_data),
        .frame_cnt    (ir_frame_cnt),
        .frame_valid  (ir_frame_valid),
        .ta_raw       (ir_ta_raw),
        .bus_err      (ir_bus_err),
        .req          (r_req),
        .dev_addr     (r_dev),
        .tx_data      (r_tx),
        .tx_len       (r_txl),
        .rd_len       (r_rdl),
        .busy         (m_busy),
        .done         (h_done[1]),
        .err          (h_err[1]),
        .rd_data      (h_rd_data[1*8 +: 8]),
        .rd_valid     (h_rd_valid[1]),
        .hub_grant    (h_grant[1])
    );

    //======================================================================
    // 客户端 2：预留（未连接）
    //======================================================================
    assign h_req[2]               = 1'b0;
    assign h_dev_addr[2*7  +: 7]  = 7'd0;
    assign h_tx_data [2*32 +: 32] = 32'd0;
    assign h_tx_len  [2*3  +: 3]  = 3'd0;
    assign h_rd_len  [2*8  +: 8]  = 8'd0;

    //======================================================================
    // 红外帧缓存（832 字，实际用 10 位地址空间 1024）
    //======================================================================
    mmt_dpram #(
        .DW (16),
        .AW (10)
    ) u_ir_frame_ram (
        .clk   (clk),
        .we    (ir_wr),
        .waddr (ir_addr),
        .wdata (ir_data),
        .raddr (ir_rd_addr),
        .rdata (ir_rd_data)
    );

    assign i2c_busy  = m_busy;
    assign i2c_owner = h_grant;

endmodule
