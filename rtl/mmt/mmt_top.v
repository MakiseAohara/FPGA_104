//==========================================================================
//  mmt_top.v  —  本项目顶层（由板卡包 10 号 demo 的 ti60f225_oob_top.v 派生）
//--------------------------------------------------------------------------
//  相对原顶层的唯一实质改动：**剥掉 DSI TX**（MIPI 屏那一路）。
//  依据：dvi_encoder_m0(HDMI) 的输入是 hdmi_tx_*，完全不经过 inst_efx_dsi_tx；
//        两者是并列且互不依赖的显示输出。赛题只要求 "HDMI/LCD" 二选一。
//  收益：省 5089 XLR + 76 BRAM（原占 16830 XLR / 138 BRAM 中的大头），
//        其中 BRAM 尤其关键——BRAM 才是本设计的紧资源。
//
//  删除内容（共 111 行）：
//    - MIPI DSI 端口声明（mipi_dp_* 共 39 个端口 + i_mipi_tx_pclk）
//    - dsi_tx inst_efx_dsi_tx 实例整块
//    - mipi_dp_*_RST 的 5 条 assign
//    - 一条死赋值 assign mipi_dsi_tx_pll_RSTN = i_arstn;（该网名全文件仅此一处）
//
//  ⚠️ 若要恢复 MIPI 屏输出：把 ip/dsi_tx 加回工程 XML，并从原顶层把这四段贴回来。
//==========================================================================
//
// =======================================================================
// ★ 2026-10-16 资源腾挪开关：MMT_TINYML_ENABLE
//   未定义（默认）=> **不综合 TinyML 加速器**，把它占的约 15.6k XLR / 33 BRAM 全部
//                     让给写通路修复（infer-clk-enable=0 需要 60833 XLR，器件只有
//                     60800，差 33 个）。s2 口与 ci_* 全部钉 0，AXI 互联拓扑不变。
//   定义       => 恢复原来行为（TinyML 重新入网表）。
//   改法：取消下面那行的注释即可回滚；也可在综合参数里加 macro 定义。
//   依据：docs/驾驶舱-摄像头出图作战-2026-10-16.md
// =======================================================================
// `define MMT_TINYML_ENABLE 1

/////////////////////////////////////////////////////////////////////////////
//
// Copyright (C) 2013-2021 Efinix Inc. All rights reserved.
//
// Description:
// Example top file for ti60f225 dev kit OOB design
//
// Language:  Verilog 2001
//
// ------------------------------------------------------------------------------

/////////////////////////////////////////////////////////////////////////////////
//`define SOFT_TAP 1
// ★ 路径改成相对"本文件"的位置（本文件在 rtl/mmt/，ddr3_parameter.vh 在 rtl/ddr3_controller/）。
//   原来的写法 "ddr3_controller/ddr3_parameter.vh" 是按**包含它的文件的目录**解析的，
//   在 rtl/mmt/ 下就变成 rtl/mmt/ddr3_controller/... —— 找不到。
//   命令行脚本过去靠额外传一个包含目录（"rtl"）绕过去，但 IDE 不知道，
//   于是在 Efinity GUI 里点综合就报
//       ERROR: mmt_top.v(32): cannot open include file 'ddr3_controller/ddr3_parameter.vh'
//   改成相对路径后，**不再依赖任何包含目录设置**，GUI 和脚本行为一致。
`include "../ddr3_controller/ddr3_parameter.vh"
// `include "define.v"

module mmt_top #(

	parameter                       RANK_RATIO         = 1,       // # of unique CS outputs per rank
	parameter                       ASYN_AXI_CLK       = `ASYN_AXI_CLK, 
	parameter                       RANKS              = `RANKS,
	parameter                       CK_WIDTH           = `CK_WIDTH,       // # of CK/CK# outputs to memory   
	parameter                       CKE_WIDTH          = `CKE_WIDTH,       // # of cke outputs
	parameter                       CS_WIDTH           = `CS_WIDTH,       // # of unique CS outputs
	parameter                       BANK_WIDTH         = `BANK_WIDTH,       // # of bank bits
	parameter                       ROW_WIDTH          = `ROW_WIDTH,       // DRAM address bus width
	parameter                       COL_WIDTH          = `COL_WIDTH,      // column address width
	parameter                       DM_WIDTH           = `DM_WIDTH,       // # of DM (data mask)
	parameter                       DQS_WIDTH          = `DQS_WIDTH,       // # of DQS (strobe)
	parameter                       DQ_WIDTH           = `DQ_WIDTH,      // # of DQ (data)
	parameter                       ODT_WIDTH          = `ODT_WIDTH,
	parameter                       DQ_CNT_WIDTH       = `DQ_CNT_WIDTH,       // = ceil(log2(DQ_WIDTH))
	parameter                       DQS_CNT_WIDTH      = `DQS_CNT_WIDTH,       // = ceil(log2(DQS_WIDTH))  
	parameter                       DRAM_WIDTH         = `DRAM_WIDTH,       // # of DQ per DQS   
	parameter                       DATA_WIDTH         = `DATA_WIDTH,
	parameter                       ADDR_WIDTH         = `ADDR_WIDTH,    
	parameter                       AXI_ID_WIDTH       = `AXI_ID_WIDTH,
	parameter                       AXI_ADDR_WIDTH     = `AXI_ADDR_WIDTH,
	parameter                       AXI_DATA_WIDTH     = `AXI_DATA_WIDTH
)
(
   //Clocks 
	input	wire	i_arstn,
    input	wire	i_mipi_rx_pclk,
    input wire  vid_clk_dvi2,
    input wire hdmi_tx_slow_clk,
    // input   wire    i_soc_clk,
    input wire CLK_5M,
    input  wire CLK_25M,
	output  wire    pll_inst1_RSTN,
	input	wire	i_pll_locked,
	input 	wire  	pll_locked,
	output  wire  	USER_PLL_RSTN,
    output 	wire 	DDR3_PLL_RSTN,
	input 	wire  	user_pll_locked,
    //CSI Interface
    input	 wire		io_cam_sda_IN,
    output wire   io_cam_sda_OUT,
    output wire		io_cam_sda_OE,

    output io_cam_scl_OUT,
    input io_cam_scl_IN,
    output io_cam_scl_OE,

    output	wire		o_cam_rst_p,
    
    input	wire		i_cam_ck_LP_P_IN,
    input	wire		i_cam_ck_LP_N_IN,
    output	wire		o_cam_ck_HS_TERM,
    output	wire		o_cam_ck_HS_ENA,
    input	wire		i_cam_ck_CLKOUT,
    
    input	wire	[7:0]			cam_d0_HS_IN,
    input	  wire		      cam_d0_LP_P_IN,
    input	  wire		      cam_d0_LP_N_IN,
    output	wire		      cam_d0_HS_TERM,
    output	wire		      cam_d0_HS_ENA,
    output	wire		      cam_d0_RST,
    output	wire		      cam_d0_FIFO_RD,
    input	  wire		      cam_d0_FIFO_EMPTY,
    
    input 	wire	[7:0]			cam_d1_HS_IN,
    input	  wire		        cam_d1_LP_P_IN,
    input	  wire		        cam_d1_LP_N_IN,
    output	wire		        cam_d1_HS_TERM,
    output	wire		        cam_d1_HS_ENA,
    output	wire		        cam_d1_RST,
    output	wire		        cam_d1_FIFO_RD,
    input	  wire		        cam_d1_FIFO_EMPTY,
    
    input 	wire	[7:0]			cam_d2_HS_IN,
    input	  wire		        cam_d2_LP_P_IN,
    input	  wire		        cam_d2_LP_N_IN,
    output	wire		        cam_d2_HS_TERM,
    output	wire		        cam_d2_HS_ENA,
    output	wire		        cam_d2_RST,
    output	wire		        cam_d2_FIFO_RD,
    input	  wire		        cam_d2_FIFO_EMPTY,  
   
    input 	wire	[7:0]			cam_d3_HS_IN,
    input	  wire		        cam_d3_LP_P_IN,
    input	  wire		        cam_d3_LP_N_IN,
    output	wire		        cam_d3_HS_TERM,
    output	wire		        cam_d3_HS_ENA,
    output	wire		        cam_d3_RST,
    output	wire		        cam_d3_FIFO_RD,
    input	  wire		        cam_d3_FIFO_EMPTY,

	
	input 					tx_cal_clk_90edge,
  	input 					rx_cal_clk,
  	input 					tx_cal_clk,
	input                              core_clk,     // CORE CLK @ 100MHz
	input                              sdram_clk,    // SDRAM CK @ 400MHz
	// PLL status flags  
	output [2:0]                       pll_shift,  
	output [4:0]                       pll_shift_sel,
	output                             pll_shift_ena,  
	// memory interface ports
	output                             ddr_ck_hi,
	output                             ddr_ck_lo,
	output                             ddr_reset_n,
	output [CKE_WIDTH-1:0]             ddr_cke,     
	output [ROW_WIDTH-1:0]             ddr_addr,
	output [BANK_WIDTH-1:0]            ddr_ba,
	output                             ddr_cas_n,
 
	output [CS_WIDTH*RANK_RATIO-1:0]   ddr_cs_n,
	output                             ddr_ras_n,
	output                             ddr_we_n,
	
	input  [DQS_WIDTH-1:0]             ddr_dqs_in_hi,
	input  [DQS_WIDTH-1:0]             ddr_dqs_in_lo,
	input  [DQ_WIDTH-1:0]              ddr_dq_in_hi,
	input  [DQ_WIDTH-1:0]              ddr_dq_in_lo,
	
	output [DQS_WIDTH-1:0]             ddr_dqs_oe,
	output [DQS_WIDTH-1:0]             ddr_dqs_oe_n,
	output [DQ_WIDTH-1:0]              ddr_dq_oe,  
	output [DQS_WIDTH-1:0]             ddr_dqs_out_hi,
	output [DQS_WIDTH-1:0]             ddr_dqs_out_lo,
	output [DQ_WIDTH-1:0]              ddr_dq_out_hi,
	output [DQ_WIDTH-1:0]              ddr_dq_out_lo,
	output [DM_WIDTH-1:0]              ddr_dm_hi,
	output [DM_WIDTH-1:0]              ddr_dm_lo,
	output [ODT_WIDTH-1:0]             ddr_odt,

       //LED
       output [1:0] led,

       //==== 本次新增：多模态传感器 / 报警 / 软核串口 ====
       // 传感器 I2C 总线（开漏，需外部上拉电阻；MLX90640 与 SHT30 共用）
       // ⚠️ 具体接哪几个引脚【等板子到手后对着原理图定，届时补进 peri.xml/约束】
       input  wire                        i_sensor_scl,
       output wire                        o_sensor_scl,
       output wire                        o_sensor_scl_oe,
       input  wire                        i_sensor_sda,
       output wire                        o_sensor_sda,
       output wire                        o_sensor_sda_oe,
       // 蜂鸣器（有源，3.3V 直接驱动；板子上没有，需外接）
       output wire                        o_buzzer,
       // RISC-V 软核的串口（走板载 FT4232HL 的 UART 通道，用于打印调试信息）
       // ⚠️ 引脚同样待定
       input  wire                        i_uart_rxd,
       output wire                        o_uart_txd,
       //================================================================
       // SPI0（路线 B 新增）：RISC-V 靠它读板载 SPI flash，把 app+模型搬进 DDR。
       // 这 4 根脚在板上**同时是上电配置脚**（active 模式：CDI0/CDI1/CCK/SSL_N），
       // 配置完成后交还用户逻辑。
       // ★ 照厂商做法（edge_vision_soc.v:176-185）暴露 **8 个单向端口**，
       //   **不要在顶层手工做三态** —— peri 的 GPIO pad 是按信号名绑定的，
       //   它会自己用 *_writeEnable 生成三态缓冲；顶层再插一个 inout 反而会
       //   让这两个脚随机落到别的空闲引脚、并和 pad 抢 MOSI/MISO。
       input  wire                        system_spi_0_io_data_0_read,
       output wire                        system_spi_0_io_data_0_write,
       output wire                        system_spi_0_io_data_0_writeEnable,
       input  wire                        system_spi_0_io_data_1_read,
       output wire                        system_spi_0_io_data_1_write,
       output wire                        system_spi_0_io_data_1_writeEnable,
       output wire                        system_spi_0_io_sclk_write,
       output wire                        system_spi_0_io_ss,
       //================================================================

       output	wire	                     LCD_RST_P			,
       output wire                        LCD_POWER			,

       // hdmi interface

    output tmds_tx_clk_TX_OE,
    output [9:0] tmds_tx_clk_TX_DATA,
    output tmds_tx_clk_TX_RST,
    output tmds_tx_data0_TX_OE,
    output [9:0] tmds_tx_data0_TX_DATA,
    output tmds_tx_data0_TX_RST,
    output tmds_tx_data1_TX_OE,
    output [9:0] tmds_tx_data1_TX_DATA,
    output tmds_tx_data1_TX_RST,
    output tmds_tx_data2_TX_OE,
    output [9:0] tmds_tx_data2_TX_DATA,
    output tmds_tx_data2_TX_RST,

    // ---- SoC JTAG 调试口（★ 端口名由 Interface Designer 的 JTAG_USER1 硬块决定，
    //      不能随意改；peri 里把它标成 required，名字不对 efx_pnr 直接失败）----
    input  wire jtag_inst1_TCK,
    input  wire jtag_inst1_TDI,
    output wire jtag_inst1_TDO,
    input  wire jtag_inst1_SEL,
    input  wire jtag_inst1_CAPTURE,
    input  wire jtag_inst1_SHIFT,
    input  wire jtag_inst1_UPDATE,
    input  wire jtag_inst1_RESET


);



//===============================================================================
//localparam
//===============================================================================
localparam WR_FIFO_DEPTH  = 1024;
localparam RD_FIFO_DEPTH  = 1024;

localparam	MAX_HRES		= 12'd1920;
localparam	MAX_VRES		= 12'd1080;
// ★ 2026-10-15 退回已上板实测通过（显示器锁住、OSD 可见）的 150MHz 方案，标准 CEA-861 1080p60 时序。
//   时钟：VCO = 25×2×60 = 3000MHz；vid_clk_dvi2 = 3000/40 = 75.0MHz（每拍 2 像素 ⇒ 像素时钟 150MHz）；
//         hdmi_tx_slow_clk = 3000/20 = 150.0MHz；i_mipi_rx_pclk = 3000/60 = 50.0MHz；
//         hdmi_tx_fast_clk = 3000/4 = 750MHz；TMDS 码率 = 150×10 = 1.500Gbps。
//   水平：HFP/2 + HSP + 960 + HBP/2 = 44 + 22 + 960 + 74 = 1100 拍，×2 = 2200 像素（标准）
//   垂直：VFP + VSP + 1080 + VBP = 4 + 5 + 1080 + 36 = 1125 行（标准）
//   帧率：150e6 / (2200×1125) = 60.606 Hz
//   ⚠ 已知代价：vid_clk_dvi2 → hdmi_tx_slow_clk（2px→1px 展开，约 L1188-1199）有 10 条 setup 负 slack，
//     最差 -1.319ns（out\mmt.timing.rpt）；但上板实测 HDMI 通，暂时接受。
//   （曾试过 140MHz 折中方案 HBP=72/HFP=44/VBP=33，已退回。）
//   更早旧值：HSP=2/HBP=88/HFP=120/VSP=2/VBP=20/VFP=20 ⇒ 行 2132、帧 1122、58.53Hz、HS 仅 4 像素。
//   frame_buffer 例化处（约 L754-761）的接法已回读核对：
//     .H_FRONT_PORCH(HFP/2) .H_SYNC(HSP) .H_VALID(MAX_HRES/2) .H_BACK_PORCH(HBP/2)  —— 单位全是"拍"(=2 像素)
//     .V_FRONT_PORCH(VFP) .V_SYNC(VSP) .V_VALID(MAX_VRES) .V_BACK_PORCH(VBP)        —— 单位是"行"
//   旧值反验：2×(120/2 + 2 + 960 + 88/2)=2×1066=2132 ✓（与实测 2132 一致，故 HSP 单位=拍，HS=2×HSP 像素）。
//   ⚠ 与任务描述不同：HSP 不除 2，但它本身就是"拍"数，HS 像素数 = 2×HSP；
//     标准 HS=44 像素 ⇒ HSP=22（不是 44，写 44 会得到 88 像素 HS、行 2288 拍错）。
//     同理 HFP 写像素数（/2 在接线处做）：前肩 88 像素 ⇒ HFP=88；后肩 148 像素 ⇒ HBP=148。
//   HS 宽度 = 2×HSP = 44 像素（标准 44）✓；VS 宽度 = VSP = 5 行（标准 5）✓
localparam	HSP			= 8'd22;	// 同步 44 像素 = 22 拍（不除 2 直接接 .H_SYNC）
localparam	HBP			= 8'd148;	// 后肩 148 像素（接线处 /2 = 74 拍）
localparam	HFP			= 8'd88;	// 前肩 88 像素（接线处 /2 = 44 拍）
localparam	VSP			= 8'd5;		// 场同步 5 行（CEA-861 VIC16）
localparam	VBP			= 8'd36;	// 场后肩 36 行（1125 行总数：4+5+1080+36）
localparam	VFP			= 8'd4;		// 场前肩 4 行
//===============================================================================
//signal
//===============================================================================
   
wire                              app_sr_active;
wire                              app_ref_ack;
wire                              app_zq_ack;
wire                              cal_done;

// Slave Interface Write Address Ports
wire [AXI_ID_WIDTH-1:0]           s_axi_awid;
wire [AXI_ADDR_WIDTH-1:0]         s_axi_awaddr;
wire [7:0]                        s_axi_awlen;
wire [2:0]                        s_axi_awsize;
wire [1:0]                        s_axi_awburst;
wire [1:0]                        s_axi_awlock;   // 互联 m 口是 2 位；DDR3 控制器只取 [0]
wire [3:0]                        s_axi_awcache;
wire [2:0]                        s_axi_awprot;
wire                              s_axi_awvalid;
wire                              s_axi_awready;
// Slave Interface Write Data Ports
wire [AXI_DATA_WIDTH-1:0]         s_axi_wdata;
wire [(AXI_DATA_WIDTH/8)-1:0]     s_axi_wstrb;
wire                              s_axi_wlast;
wire                              s_axi_wvalid;
wire                              s_axi_wready;
// Slave Interface Write Response Ports
wire                              s_axi_bready;
wire [AXI_ID_WIDTH-1:0]           s_axi_bid;
wire [1:0]                        s_axi_bresp;
wire                              s_axi_bvalid;
// Slave Interface Read Address Ports
wire [AXI_ID_WIDTH-1:0]           s_axi_arid;
wire [AXI_ADDR_WIDTH-1:0]         s_axi_araddr;
wire [7:0]                        s_axi_arlen;
wire [2:0]                        s_axi_arsize;
wire [1:0]                        s_axi_arburst;
wire [1:0]                        s_axi_arlock;   // 同上
wire [3:0]                        s_axi_arcache;
wire [2:0]                        s_axi_arprot;
wire                              s_axi_arvalid;
wire                              s_axi_arready;
// Slave Interface Read Data Ports
wire                              s_axi_rready;
wire [AXI_ID_WIDTH-1:0]           s_axi_rid;
wire [AXI_DATA_WIDTH-1:0]         s_axi_rdata;
wire [1:0]                        s_axi_rresp;
wire                              s_axi_rlast;
wire                              s_axi_rvalid;
// 互联 m 口的 region / user / qos（DDR3 控制器没有这些口，region/user 悬空）
wire [3:0]                        s_axi_awqos;
wire [3:0]                        s_axi_arqos;
wire [3:0]                        s_axi_awregion;
wire [3:0]                        s_axi_arregion;
wire [0:0]                        m_axic_awuser;
wire [0:0]                        m_axic_aruser;
wire [0:0]                        m_axic_wuser;

// ============================================================================
//  路线 B：DDR 三主口 AXI 互联（frame_buffer / SoC / TinyML → DDR3 控制器）
// ----------------------------------------------------------------------------
//  原设计是 frame_buffer 独占 DDR3 控制器（1 主 1 从直连，见下）。现在三个主口
//  都要访问同一片 DDR3，所以中间加一级 AXI4 互联：
//      Efinity IP efx_axi_interconnect 5.6
//      参数 S_PORTS=3 / M_PORTS=1 / DATA_WIDTH=128 / ID_WIDTH=4 / ADDR_WIDTH=32
//      默认 ARB_MODE=PRIORITY、PROTOCOL=AXI4、下游地址窗口 0x00000000 宽 28 位(256MB)
//  互联的 s_axi_* 是**扁平向量**，第 n 个主口占 [n*W +: W]，端口 2 在最高位。
//
//  端口分配：s0 = frame_buffer（视频实时路径）
//            s1 = Sapphire SoC（CPU 访问 DDR）
//            s2 = TinyML 加速器（读模型权重/张量）
//
//  ID 宽度：DDR3 控制器只有 AXI_ID_WIDTH=4 位。frame_buffer 出 6 位、SoC 出 8 位，
//  这里统一截成低 4 位；TinyML 没有 ID，恒接 0。厂商自己的 ddr_demo_ti60 也是
//  "8 位 SoC ID 直连 4 位控制器"（Verilog 静默截断），做法一致。
//
//  地址分配（整片 DDR3 = 256 MB，见 docs/工程全貌与学习地图.md）：
//      0x0000_0000 – 0x00FF_BFFF   RISC-V 应用区（LDSize=16380KB≈16MB）
//      0x0200_0000 – 0x02BD_DDFF   视频帧缓存 3 bank（frame_buffer.START_ADDR）
//      其余留给 TinyML 输入/张量缓冲
// ============================================================================
// ---- s0：frame_buffer ----
wire [5:0]                        fb_awid;
wire [AXI_ADDR_WIDTH-1:0]         fb_awaddr;
wire [7:0]                        fb_awlen;
wire [2:0]                        fb_awsize;
wire [1:0]                        fb_awburst;
wire [0:0]                        fb_awlock;
wire [3:0]                        fb_awcache;
wire [2:0]                        fb_awprot;
wire                              fb_awvalid;
wire                              fb_awready;
wire [AXI_DATA_WIDTH-1:0]         fb_wdata;
wire [(AXI_DATA_WIDTH/8)-1:0]     fb_wstrb;
wire                              fb_wlast;
wire                              fb_wvalid;
wire                              fb_wready;
wire                              fb_bready;
wire [5:0]                        fb_bid;
wire [1:0]                        fb_bresp;
wire                              fb_bvalid;
wire [5:0]                        fb_arid;
wire [AXI_ADDR_WIDTH-1:0]         fb_araddr;
wire [7:0]                        fb_arlen;
wire [2:0]                        fb_arsize;
wire [1:0]                        fb_arburst;
wire [0:0]                        fb_arlock;
wire [3:0]                        fb_arcache;
wire [2:0]                        fb_arprot;
wire                              fb_arvalid;
wire                              fb_arready;
wire                              fb_rready;
wire [5:0]                        fb_rid;
wire [AXI_DATA_WIDTH-1:0]         fb_rdata;
wire [1:0]                        fb_rresp;
wire                              fb_rlast;
wire                              fb_rvalid;

// ---- s1：SoC 的 DDR AXI4 主口（128 位 / ID 8 位）----
wire                              soc_ddr_awvalid;
wire [AXI_ADDR_WIDTH-1:0]         soc_ddr_awaddr;
wire [7:0]                        soc_ddr_awlen;
wire [2:0]                        soc_ddr_awsize;
wire [1:0]                        soc_ddr_awburst;
wire [1:0]                        soc_ddr_awlock;
wire [3:0]                        soc_ddr_awcache;
wire [2:0]                        soc_ddr_awprot;
wire [3:0]                        soc_ddr_awqos;
wire [3:0]                        soc_ddr_awregion;
wire [7:0]                        soc_ddr_awid;
wire                              soc_ddr_awready;
wire [AXI_DATA_WIDTH-1:0]         soc_ddr_wdata;
wire [(AXI_DATA_WIDTH/8)-1:0]     soc_ddr_wstrb;
wire                              soc_ddr_wlast;
wire                              soc_ddr_wvalid;
wire                              soc_ddr_wready;
wire [1:0]                        soc_ddr_bresp;
wire [7:0]                        soc_ddr_bid;
wire                              soc_ddr_bvalid;
wire                              soc_ddr_bready;
wire                              soc_ddr_arvalid;
wire [AXI_ADDR_WIDTH-1:0]         soc_ddr_araddr;
wire [7:0]                        soc_ddr_arlen;
wire [2:0]                        soc_ddr_arsize;
wire [1:0]                        soc_ddr_arburst;
wire [1:0]                        soc_ddr_arlock;
wire [3:0]                        soc_ddr_arcache;
wire [2:0]                        soc_ddr_arprot;
wire [3:0]                        soc_ddr_arqos;
wire [3:0]                        soc_ddr_arregion;
wire [7:0]                        soc_ddr_arid;
wire                              soc_ddr_arready;
wire [AXI_DATA_WIDTH-1:0]         soc_ddr_rdata;
wire [1:0]                        soc_ddr_rresp;
wire [7:0]                        soc_ddr_rid;
wire                              soc_ddr_rlast;
wire                              soc_ddr_rvalid;
wire                              soc_ddr_rready;

// ---- SoC ↔ TinyML 自定义指令口 ----
wire                              ci_cmd_valid;
wire [9:0]                        ci_function_id;
wire [31:0]                       ci_inputs_0;
wire [31:0]                       ci_inputs_1;
wire                              ci_rsp_ready;
wire                              ci_cmd_ready;
wire                              ci_rsp_valid;
wire [31:0]                       ci_outputs_0;
wire                              tml_cmd_int;      // 加速器完成中断 → u_soc.ci_cmd_int → userInterruptA → PLIC

// ---- s2：TinyML 加速器 AXI 主口（32 位地址 / 128 位数据 / 8 位 ID）----
wire                              tml_awvalid;
wire [31:0]                       tml_awaddr;
wire [7:0]                        tml_awlen;
wire [2:0]                        tml_awsize;
wire [1:0]                        tml_awburst;
wire [2:0]                        tml_awprot;
wire [1:0]                        tml_awlock;
wire [3:0]                        tml_awcache;
wire [7:0]                        tml_awid;      // channels 包装出的写 ID（互联取低 4 位）
wire                              tml_awready;
wire [AXI_DATA_WIDTH-1:0]         tml_wdata;
wire [(AXI_DATA_WIDTH/8)-1:0]     tml_wstrb;
wire                              tml_wlast;
wire                              tml_wvalid;
wire                              tml_wready;
wire [1:0]                        tml_bresp;
wire                              tml_bvalid;
wire                              tml_bready;
wire                              tml_arvalid;
wire [31:0]                       tml_araddr;
wire [7:0]                        tml_arlen;
wire [2:0]                        tml_arsize;
wire [1:0]                        tml_arburst;
wire [2:0]                        tml_arprot;
wire [1:0]                        tml_arlock;
wire [3:0]                        tml_arcache;
wire [7:0]                        tml_arid;      // 读 ID（互联取低 4 位）
wire                              tml_arready;
wire                              tml_rvalid;
wire [AXI_DATA_WIDTH-1:0]         tml_rdata;
wire                              tml_rlast;
wire [1:0]                        tml_rresp;
wire                              tml_rready;
// channels 包装只输出 1 位 lock（[0:0]），互联每口要 2 位 —— 高位显式补 0，
// 否则 tml_awlock[1]/tml_arlock[1] 悬空(z) 还会被拼进互联输入
`ifdef MMT_TINYML_ENABLE
assign tml_awlock[1] = 1'b0;
assign tml_arlock[1] = 1'b0;
`else
// ---------------------------------------------------------------------------
// TinyML 剪除态：s2 主口全部钉成合法空闲值（valid=0 / ready=0）。
//   互联侧看到的是一个「永远不发请求」的主口，无需改动互联 IP 或拓扑。
// ---------------------------------------------------------------------------
assign tml_awvalid = 1'b0;
assign tml_awaddr  = 32'd0;
assign tml_awlen   = 8'd0;
assign tml_awsize  = 3'd0;
assign tml_awburst = 2'd0;
assign tml_awprot  = 3'd0;
assign tml_awlock  = 2'd0;
assign tml_awcache = 4'd0;
assign tml_awid    = 8'd0;
assign tml_wdata   = {AXI_DATA_WIDTH{1'b0}};
assign tml_wstrb   = {(AXI_DATA_WIDTH/8){1'b0}};
assign tml_wlast   = 1'b0;
assign tml_wvalid  = 1'b0;
assign tml_bready  = 1'b0;
assign tml_arvalid = 1'b0;
assign tml_araddr  = 32'd0;
assign tml_arlen   = 8'd0;
assign tml_arsize  = 3'd0;
assign tml_arburst = 2'd0;
assign tml_arprot  = 3'd0;
assign tml_arlock  = 2'd0;
assign tml_arcache = 4'd0;
assign tml_arid    = 8'd0;
assign tml_rready  = 1'b0;
`endif




////////////////////////////////////////////////////////////////
// System & Debugger
wire    w_arstn;
wire	w_sysclk_mcu_arstn;
wire	w_sysclk_mcu_arst;
wire	w_mipi_rx_pclk_arstn;
wire	w_mipi_rx_pclk_arst;

wire		       w_mipi_rx_vs;
wire		       w_mipi_rx_hs;
wire	       w_mipi_rx_de;
// ---- ★ task-19：CSI RX 明文状态（原来这些端口都是 () 悬空的）----
wire [15:0] csi_word_count;
wire [5:0]  csi_datatype;
wire [1:0]  csi_vc;
wire [3:0]  csi_pixel_per_clk;
wire [3:0]  cam_fifo_rd_empty;
wire        csi_irq;
assign cam_fifo_rd_empty = {cam_d3_FIFO_EMPTY, cam_d2_FIFO_EMPTY,
                            cam_d1_FIFO_EMPTY, cam_d0_FIFO_EMPTY};
wire	[63:0]			w_mipi_rx_data	;

wire					io_systemReset;



//===================================================================================================
//reset module
//===================================================================================================

assign w_arstn  		       = i_pll_locked & pll_locked & user_pll_locked;
assign pll_inst1_RSTN  		= i_arstn;
assign USER_PLL_RSTN      		= i_arstn;
assign DDR3_PLL_RSTN 		= i_arstn;
reset_ctrl
#(
	.NUM_RST		(2),
	.CYCLE			(1),
	.IN_RST_ACTIVE	(4'b00),
	.OUT_RST_ACTIVE	(4'b10)
)
inst_reset_ctrl
(
	.i_arst		({2{w_arstn}}),//({{4{i_pll_locked}},                  {2{i_arstn}}}),
	.i_clk			({2{i_mipi_rx_pclk}}),
	.o_srst		({w_mipi_rx_pclk_arst, w_mipi_rx_pclk_arstn})
);


reset_ctrl
#(
	.NUM_RST		(2),
	.CYCLE			(10),
	.IN_RST_ACTIVE	(2'b00),
	.OUT_RST_ACTIVE	(2'b10)
)
inst_reset_mcu_ctrl
(
	.i_arst		({2{w_arstn}}),
	.i_clk			({2{i_soc_clk}}),
	.o_srst		({w_sysclk_mcu_arst,w_sysclk_mcu_arstn})
);



reg [25:0] cnt = 'd0;
always @( posedge core_clk)
begin 
       cnt <= cnt + 1'b1;
end
// ★ 原来这里是 `assign led[0] = cal_done ? cnt[24] : 1'b0;`（心跳灯）。
//   现在 led 改由报警模块统一驱动（见文件末尾的互连部分）：
//   报警时 4 个灯一起闪；平时保留原来的心跳灯行为。
//   为避免多驱动，这一条 assign 已删除。

//========================================================================================================
//MIPI RX
//========================================================================================================
wire i_mipi_clk ;
assign i_mipi_clk = core_clk;
assign i_soc_clk  = core_clk;

		assign	cam_d0_RST		= 1'b0;
		assign	cam_d1_RST		= 1'b0;
		assign  cam_d2_RST = 1'b0;
    assign  cam_d3_RST = 1'b0;
	
	
		

		csi_rx_controller inst_efx_csi2_rx
		(
              .reset_n			(i_arstn),
              .clk				(i_mipi_clk),
              .reset_byte_HS_n	(i_arstn),
              .clk_byte_HS		  (i_cam_ck_CLKOUT),
              .reset_pixel_n		(w_mipi_rx_pclk_arstn),
              .clk_pixel			  (i_mipi_rx_pclk),
              
              .Rx_LP_CLK_P		  (i_cam_ck_LP_P_IN),
              .Rx_LP_CLK_N		  (i_cam_ck_LP_N_IN),
              .Rx_HS_enable_C		(o_cam_ck_HS_ENA),
              .LVDS_termen_C		(o_cam_ck_HS_TERM),
              
              .Rx_LP_D_P			({cam_d3_LP_P_IN, cam_d2_LP_P_IN, cam_d1_LP_P_IN, cam_d0_LP_P_IN}),//(r_mipi_rx_data_LP_P_IN_2P),
              .Rx_LP_D_N			({cam_d3_LP_N_IN, cam_d2_LP_N_IN, cam_d1_LP_N_IN, cam_d0_LP_N_IN}),//(r_mipi_rx_data_LP_N_IN_2P),
              .Rx_HS_D_0			(cam_d0_HS_IN),//(r_mipi_rx_data_HS_IN_2P[0*8+:8]),
              .Rx_HS_D_1			(cam_d1_HS_IN),//(r_mipi_rx_data_HS_IN_2P[1*8+:8]),
              .Rx_HS_D_2			(cam_d2_HS_IN),
              .Rx_HS_D_3			(cam_d3_HS_IN),
              .Rx_HS_D_4			(),
              .Rx_HS_D_5			(),
              .Rx_HS_D_6			(),
              .Rx_HS_D_7			(),
              .Rx_HS_enable_D		({cam_d3_HS_ENA    ,cam_d2_HS_ENA    ,cam_d1_HS_ENA    ,cam_d0_HS_ENA    }),//( w_cam_d_HS_ENA),
              .LVDS_termen_D		({cam_d3_HS_TERM   ,cam_d2_HS_TERM   ,cam_d1_HS_TERM   ,cam_d0_HS_TERM   }),
              .fifo_rd_enable		({cam_d3_FIFO_RD   ,cam_d2_FIFO_RD   ,cam_d1_FIFO_RD   ,cam_d0_FIFO_RD   }),
              .fifo_rd_empty (cam_fifo_rd_empty),
              .DLY_enable_D		       (),
              .DLY_inc_D			(),
              .u_dly_enable_D		(),
              .u_dly_inc_D		       (),
              
              // ★ 2026-10-11 修复（根因见 docs\帧缓冲写通路根因.md）：
              //   原来 axi_clk/axi_reset_n 都绑 0 ⇒ 综合器可证明 IP 内**所有 AXI 域寄存器
              //   恒等于复位值**。CSI RX IP 5.15 新增的"像素输出使能"寄存器若复位值为 0，
              //   就会被证明 pixel_data_valid 恒 0 → 像素侧 FIFO 整段被删
              //   （实测：我们 CSI RX 只 4 块 BRAM、厂商同 IP 36 块；i_mipi_rx_pclk 的
              //    Memory Ports 45 → 0）→ frame_stable/frame_start 恒 0 → 帧缓冲写通路被折叠。
              //   修法 E1：给 AXI 一个真实时钟并释放复位，但**不发起任何事务**（其余 AXI 仍绑 0）。
              .axi_clk			(core_clk),
              .axi_reset_n		       (w_arstn),
              .axi_awaddr			(6'b0),
              .axi_awvalid		       (1'b0),
              .axi_awready		       (),
              .axi_wdata			(32'b0),
              .axi_wvalid			(1'b0),
              .axi_wready			(),
              
              .axi_bvalid			(),
              .axi_bready			(1'b0),
              .axi_araddr			(6'b0),
              .axi_arvalid		       (1'b0),
              .axi_arready		       (),
              .axi_rdata			(),
              .axi_rvalid			(),
              .axi_rready			(1'b1),
              
              .hsync_vc0			(w_mipi_rx_hs),
              .hsync_vc1			(),
              .hsync_vc2			(),
              .hsync_vc3			(),
              .vsync_vc0			(w_mipi_rx_vs),
              .vsync_vc1			(),
              .vsync_vc2			(),
              .vsync_vc3			(),
              .vc (csi_vc),
              .word_count (csi_word_count),
              .shortpkt_data_field        (),
              .datatype (csi_datatype),
              .pixel_per_clk (csi_pixel_per_clk),
              .pixel_data			(w_mipi_rx_data),
              .pixel_data_valid	       (w_mipi_rx_de),
              .irq (csi_irq)
		);

//========================================================================================================
//
//========================================================================================================
		

//*************** imx219 config********************/
// mipi_config_imx219_top u_config_imx219(
// 										.i_sys_clk(CLK_5M)    	,    /////48M 
// 										.sys_rstn(vid_rst_n )    ,
// 										.o_sen_rst_n(o_cam_rstn)  	,
										
										// .o_iic_sda_OE(io_cam_sda_OE) ,
										// .i_iic_sda(io_cam_sda_IN)   	,
										// .o_iic_sda(io_cam_sda_OUT)   	,
										// .o_iic_scl(io_cam_scl)    	
										// ); 	

wire scl_padoen_o;
wire sda_padoen_o;


reg [12:0] i2c_rst_cnt = '0;

always @( posedge CLK_5M or negedge w_arstn )
begin
    if( !w_arstn )
       i2c_rst_cnt <= 'd0;
    else 
       i2c_rst_cnt <= i2c_rst_cnt[12] ? i2c_rst_cnt : i2c_rst_cnt + 1'b1;
end
wire i2c_rst_n = i2c_rst_cnt[12];

i2c_master_ctrl_top u2_i2c_master_ctrl_top(
  /*i*/.clk			(CLK_5M		),
  /*i*/.rst_n			(i2c_rst_n		),
  /*i*/.scl_pad_i     (io_cam_scl_IN),//(1'b1),
  /*o*/.scl_pad_o     (io_cam_scl_OUT),
  /*o*/.scl_padoen_o  (scl_padoen_o),
  /*i*/.sda_pad_i     (io_cam_sda_IN),
  /*o*/.sda_pad_o     (io_cam_sda_OUT),
  /*o*/.sda_padoen_o  (sda_padoen_o)
  
  );
assign o_cam_rst_p = ~w_arstn;
assign io_cam_scl_OE = ~scl_padoen_o;
assign io_cam_sda_OE = ~sda_padoen_o;

//=====================================================================================
//frame buffer
//=====================================================================================
wire [7:0] 	ch0_r;
wire [7:0]    ch0_g;
wire [7:0]    ch0_b;
wire ch0_vs;
wire ch0_hs;
wire ch0_de;
// IMX219
// ================= ★ task-23 / M0：测试图案注入（方案 A：同域，无时钟 mux）=================
wire        tp_en;                       // 来自 mmt_soc_regs 0xC8[0]（复位默认 0 = 摄像头）
wire [1:0]  tp_mode;                     // 来自 mmt_soc_regs 0xC8[2:1]
wire        tp_vs, tp_hs, tp_de;
wire [31:0] tp_vin;
wire [15:0] vid_lines_per_frame, vid_pixels_per_line, vid_frame_cnt;
wire [31:0] dbg_fb_sb;   // 调试：frame_buffer 写侧粘滞位（checker0.test_wdata → 0xE0）
wire [31:0] dbg_fb_sb2;
wire [31:0] dbg_live_fb;  // frame_buffer live 输出（= ddr_wr_buffer.dbg_sb）
reg  pll_shift_seen = 1'b0;
always @(posedge core_clk) begin if (pll_shift_ena) pll_shift_seen <= 1'b1; end
// 0xE8: [25]=pll_shift_ena曾高 [24]=pll_shift_ena live [23]=ddr_reset_n [22:0]=dbg_sb[22:0]
wire [31:0] dbg_live = {6'd0, pll_shift_seen, pll_shift_ena, ddr_reset_n, 1'b0, dbg_live_fb[22:0]};

wire        mipi_vs_sel  = tp_en ? tp_vs : w_mipi_rx_vs;
wire        mipi_hs_sel  = tp_en ? tp_hs : w_mipi_rx_hs;
wire        mipi_de_sel  = tp_en ? tp_de : w_mipi_rx_de;
wire [31:0] mipi_vin_sel = tp_en ? tp_vin
                                 : {w_mipi_rx_data[39:32], w_mipi_rx_data[29:22],
                                    w_mipi_rx_data[19:12], w_mipi_rx_data[9:2]};

mmt_test_pattern #(
    .H_ACTIVE(1920), .V_ACTIVE(1080),
    .H_FRONT(120), .H_SYNC(2), .H_BACK(88),
    .V_FRONT(20),  .V_SYNC(2), .V_BACK(20),
    .PPC(4)
) u_test_pattern (
    .i_clk(i_mipi_rx_pclk), .i_rstn(vid_rst_n), .i_en(tp_en), .i_mode(tp_mode),
    .o_vs(tp_vs), .o_hs(tp_hs), .o_de(tp_de), .o_vin(tp_vin),
    .o_frame_cnt(), .o_line_cnt(), .o_pix_cnt(),
    .i_vid_de(mipi_de_sel & mipi_hs_sel), .i_vid_hs(mipi_hs_sel), .i_vid_vs(mipi_vs_sel),
    .o_lines_per_frame(vid_lines_per_frame),
    .o_pixels_per_line(vid_pixels_per_line),
    .o_vid_frame_cnt  (vid_frame_cnt)
);
// =====================================================================================
  frame_buffer #(
.I_VID_WIDTH         (32),
.O_VID_WIDTH         (16),
.START_ADDR          (32'h02000000    ),
.AXI_DATA_WIDTH      ( AXI_DATA_WIDTH	),
.AXI_ADDR_WIDTH      ( AXI_ADDR_WIDTH	),
.WR_FIFO_DEPTH	      ( 1024		),    
.RD_FIFO_DEPTH 	      ( 512 	),   // ★ 2026-10-12 削减：1024→512（省 6 块 RAM，见 docs\BRAM资源优化方案.md R1）
.BURST_LEN  	       (127),
.FB_NUM	            (3),
.MAX_VID_WIDTH	    (960) ,
.MAX_VID_HIGHT	    (1080) 


)checker0(
       .axi_clk		(core_clk 	        ),
       .rst_n			(vid_rst_n   ),
       .test_wdata (dbg_fb_sb),
       .test_rdata (dbg_fb_sb2),
       .dbg_live   (dbg_live_fb),

/*i*/.i_clk			(i_mipi_rx_pclk      ),
/*i*/.i_vs			(mipi_vs_sel	),
/*i*/.i_de			(mipi_de_sel & mipi_hs_sel	),
/*i*/.vin 			(mipi_vin_sel	),
                     
/*i*/.o_clk			(vid_clk_dvi2),//(i_mipi_rx_pclk	),
/*i*/.o_hs    		(ch0_hs		),			
/*i*/.o_vs    		(ch0_vs		),			
/*i*/.o_de    		(ch0_de		),			
/*i*/.vout    		({ch0_g,ch0_b}	),//ch0_r,

/*i*/.H_FRONT_PORCH (HFP/2  		),//
/*i*/.H_SYNC 	 	    (HSP	 	),///2
/*i*/.H_VALID 	 	  (MAX_HRES/2     ),//		
/*i*/.H_BACK_PORCH	(HBP/2		),//		
/*i*/.V_FRONT_PORCH (VFP  		),//		
/*i*/.V_SYNC 	 	    (VSP 	 	),//		
/*i*/.V_VALID 	 	  (MAX_VRES     ),//		
/*i*/.V_BACK_PORCH	(VBP		),//		

       .awid			(fb_awid	),      
       .awaddr		(fb_awaddr	),
       .awlen			(fb_awlen	),
       .awsize		(fb_awsize	),
       .awburst		(fb_awburst),
       .awprot    (fb_awprot ),
       .awcache   (fb_awcache),
       .awlock		(fb_awlock	),
       .awvalid		(fb_awvalid),
       .awready		(fb_awready),

       .arid			(fb_arid	  ),
       .araddr		(fb_araddr	),
       .arlen			(fb_arlen	),
       .arsize		(fb_arsize	),
       .arburst 	(fb_arburst),

       .arprot    (fb_arprot ),
       .arcache   (fb_arcache),
       .arlock 		(fb_arlock	),
       .arvalid		(fb_arvalid),
       .arready		(fb_arready),

       .wdata			(fb_wdata	),
       .wstrb			(fb_wstrb	),
       .wlast			(fb_wlast	),
       .wvalid		(fb_wvalid	),
       .wready		(fb_wready	),


       .rid			  (fb_rid	),
       .rdata			(fb_rdata	),
       .rlast			(fb_rlast	),
       .rvalid 		(fb_rvalid	),
       .rready		(fb_rready	),
       .rresp			(fb_rresp	),

       .bid			  (fb_bid	),
       .bvalid		(fb_bvalid	),
       .bready	  (fb_bready	)
);


//***************************************************************************
// AXI 互联：frame_buffer(s0) / SoC(s1) / TinyML(s2) → DDR3 控制器(m)
//***************************************************************************
// 互联是 4 位 ID，但 frame_buffer 的 bid/rid 是 6 位、SoC 的是 8 位 ——
// 回程 ID 要**零扩展**接回去（截断只发生在去程）。输出端口上不能直接接常量
// （Efinity VERI-1180 "constant is not allowed here"），所以用中间线。
wire [3:0] ic_bid_p0, ic_bid_p1, ic_bid_p2;
wire [3:0] ic_rid_p0, ic_rid_p1, ic_rid_p2;
assign fb_bid      = {2'b00, ic_bid_p0};   // frame_buffer：6 位
assign soc_ddr_bid = {4'h0,  ic_bid_p1};   // SoC：8 位
assign fb_rid      = {2'b00, ic_rid_p0};
assign soc_ddr_rid = {4'h0,  ic_rid_p1};
// ic_bid_p2 / ic_rid_p2：TinyML 侧没有 ID 消费者，留着不接

axi_interconnect u_ddr_axi_ic (
    .clk    (core_clk   ),
    .rst_n  (w_arstn    ),

    // ---------------- s0 / s1 / s2 的写地址通道 ----------------
    .s_axi_awvalid  ({tml_awvalid,  soc_ddr_awvalid,  fb_awvalid  }),
    .s_axi_awaddr   ({tml_awaddr,   soc_ddr_awaddr,   fb_awaddr   }),
    .s_axi_awlen    ({tml_awlen,    soc_ddr_awlen,    fb_awlen    }),
    .s_axi_awsize   ({tml_awsize,   soc_ddr_awsize,   fb_awsize   }),
    .s_axi_awburst  ({tml_awburst,  soc_ddr_awburst,  fb_awburst  }),
    // ★ lock 每口必须正好 2 位：fb_awlock 只有 [0:0]，原来直接拼会让整个向量错位
    //   （2+2+1=5 位拼进 6 位端口 → Verilog 在高位补 0，SoC 的 lock 位会被当成 TinyML 口的位）
    .s_axi_awlock   ({tml_awlock[1:0], soc_ddr_awlock[1:0], {1'b0, fb_awlock}}),
    .s_axi_awcache  ({tml_awcache,  soc_ddr_awcache,  fb_awcache  }),
    .s_axi_awprot   ({tml_awprot,   soc_ddr_awprot,   fb_awprot   }),
    .s_axi_awqos    ({4'h0,         soc_ddr_awqos,    4'h0        }),
    .s_axi_awuser   (3'h0),
    .s_axi_awid     ({tml_awid[3:0],  soc_ddr_awid[3:0], fb_awid[3:0]}),
    .s_axi_awready  ({tml_awready,  soc_ddr_awready,  fb_awready  }),
    // ---------------- 写数据通道 ----------------
    .s_axi_wvalid   ({tml_wvalid,   soc_ddr_wvalid,   fb_wvalid   }),
    .s_axi_wdata    ({tml_wdata,    soc_ddr_wdata,    fb_wdata    }),
    .s_axi_wstrb    ({tml_wstrb,    soc_ddr_wstrb,    fb_wstrb    }),
    .s_axi_wlast    ({tml_wlast,    soc_ddr_wlast,    fb_wlast    }),
    .s_axi_wid      (12'h0),
    .s_axi_wuser    (3'h0),
    .s_axi_wready   ({tml_wready,   soc_ddr_wready,   fb_wready   }),
    // ---------------- 写响应通道 ----------------
    .s_axi_bvalid   ({tml_bvalid,   soc_ddr_bvalid,   fb_bvalid   }),
    .s_axi_bresp    ({tml_bresp,    soc_ddr_bresp,    fb_bresp    }),
    .s_axi_bid      ({ic_bid_p2,    ic_bid_p1,       ic_bid_p0   }),
    .s_axi_bready   ({tml_bready,   soc_ddr_bready,   fb_bready   }),
    .s_axi_buser    (),
    // ---------------- 读地址通道 ----------------
    .s_axi_arvalid  ({tml_arvalid,  soc_ddr_arvalid,  fb_arvalid  }),
    .s_axi_araddr   ({tml_araddr,   soc_ddr_araddr,   fb_araddr   }),
    .s_axi_arlen    ({tml_arlen,    soc_ddr_arlen,    fb_arlen    }),
    .s_axi_arsize   ({tml_arsize,   soc_ddr_arsize,   fb_arsize   }),
    .s_axi_arburst  ({tml_arburst,  soc_ddr_arburst,  fb_arburst  }),
    // ★ 同上：arlock 每口补齐成 2 位
    .s_axi_arlock   ({tml_arlock[1:0], soc_ddr_arlock[1:0], {1'b0, fb_arlock}}),
    .s_axi_arcache  ({tml_arcache,  soc_ddr_arcache,  fb_arcache  }),
    .s_axi_arprot   ({tml_arprot,   soc_ddr_arprot,   fb_arprot   }),
    .s_axi_arqos    ({4'h0,         soc_ddr_arqos,    4'h0        }),
    .s_axi_aruser   (3'h0),
    .s_axi_arid     ({tml_arid[3:0],  soc_ddr_arid[3:0], fb_arid[3:0]}),
    .s_axi_arready  ({tml_arready,  soc_ddr_arready,  fb_arready  }),
    // ---------------- 读数据通道 ----------------
    .s_axi_rvalid   ({tml_rvalid,   soc_ddr_rvalid,   fb_rvalid   }),
    .s_axi_rdata    ({tml_rdata,    soc_ddr_rdata,    fb_rdata    }),
    .s_axi_rresp    ({tml_rresp,    soc_ddr_rresp,    fb_rresp    }),
    .s_axi_rlast    ({tml_rlast,    soc_ddr_rlast,    fb_rlast    }),
    .s_axi_rid      ({ic_rid_p2,    ic_rid_p1,       ic_rid_p0   }),
    .s_axi_rready   ({tml_rready,   soc_ddr_rready,   fb_rready   }),
    .s_axi_ruser    (),

    // ---------------- m：唯一从口 = DDR3 控制器 ----------------
    .m_axi_awvalid  (s_axi_awvalid ),
    .m_axi_awaddr   (s_axi_awaddr  ),
    .m_axi_awlen    (s_axi_awlen   ),
    .m_axi_awsize   (s_axi_awsize  ),
    .m_axi_awburst  (s_axi_awburst ),
    .m_axi_awlock   (s_axi_awlock  ),
    .m_axi_awcache  (s_axi_awcache ),
    .m_axi_awprot   (s_axi_awprot  ),
    .m_axi_awqos    (s_axi_awqos   ),
    .m_axi_awregion (s_axi_awregion),
    .m_axi_awuser   (m_axic_awuser ),
    .m_axi_awid     (s_axi_awid    ),
    .m_axi_awready  (s_axi_awready ),
    .m_axi_wvalid   (s_axi_wvalid  ),
    .m_axi_wdata    (s_axi_wdata   ),
    .m_axi_wstrb    (s_axi_wstrb   ),
    .m_axi_wlast    (s_axi_wlast   ),
    .m_axi_wuser    (m_axic_wuser  ),
    .m_axi_wready   (s_axi_wready  ),
    .m_axi_bvalid   (s_axi_bvalid  ),
    .m_axi_bresp    (s_axi_bresp   ),
    .m_axi_bid      (s_axi_bid     ),
    .m_axi_bready   (s_axi_bready  ),
    .m_axi_buser    (1'b0          ),
    .m_axi_arvalid  (s_axi_arvalid ),
    .m_axi_araddr   (s_axi_araddr  ),
    .m_axi_arlen    (s_axi_arlen   ),
    .m_axi_arsize   (s_axi_arsize  ),
    .m_axi_arburst  (s_axi_arburst ),
    .m_axi_arlock   (s_axi_arlock  ),
    .m_axi_arcache  (s_axi_arcache ),
    .m_axi_arprot   (s_axi_arprot  ),
    .m_axi_arqos    (s_axi_arqos   ),
    .m_axi_arregion (s_axi_arregion),
    .m_axi_aruser   (m_axic_aruser ),
    .m_axi_arid     (s_axi_arid    ),
    .m_axi_arready  (s_axi_arready ),
    .m_axi_rvalid   (s_axi_rvalid  ),
    .m_axi_rdata    (s_axi_rdata   ),
    .m_axi_rresp    (s_axi_rresp   ),
    .m_axi_rlast    (s_axi_rlast   ),
    .m_axi_ruser    (1'b0          ),
    .m_axi_rid      (s_axi_rid     ),
    .m_axi_rready   (s_axi_rready  )
);

//***************************************************************************
// TinyML 加速器（路线 B）
//   用官方那个 **channels 包装**，不要直接例化 tinyml_top。
//   理由（实测）：直接用 tinyml_top 时 Efinity 会报
//     tinyml_accelerator.v(5093): instantiating unknown module '**'  → 综合失败
//   换成 tinyml_accelerator_channels（官方 edge_vision_soc.v / tinyml_soc.v 例化的就是它）
//   后同样的文件集综合一次通过。channels 会 `define NUMBER_OF_CHANNELS /
//   ENABLED_ACCELERATOR_CHANNEL 并把配置参数透传给内部的 tinyml_top。
//   单通道时它的命令/响应口就是 1 位宽（[0:0]），AXI 口多出 8 位 awid/arid。
//   ★ 2026-10-16：整块由 MMT_TINYML_ENABLE 包住。未定义时本加速器不入网表，
//     省约 15.6k XLR + 33 BRAM，让 infer-clk-enable=0 的写通路修复能装下。
//***************************************************************************
`ifdef MMT_TINYML_ENABLE
tinyml_accelerator_channels #(
    .AXI_DW_M (128)
) u_tinyml_accel (
    .clk            (core_clk   ),
    .reset          (~w_arstn   ),
    // 命令口（单通道，均 1 位宽）
    .cmd_valid      (ci_cmd_valid   ),
    .cmd_function_id(ci_function_id ),
    .cmd_inputs_0   (ci_inputs_0    ),
    .cmd_inputs_1   (ci_inputs_1    ),
    .cmd_ready      (ci_cmd_ready   ),
    .cmd_int        (tml_cmd_int    ),
    // 响应口
    .rsp_valid      (ci_rsp_valid   ),
    .rsp_outputs_0  (ci_outputs_0   ),
    .rsp_ready      (ci_rsp_ready   ),
    // AXI4 主口
    .m_axi_clk      (core_clk   ),
    .m_axi_rstn     (w_arstn    ),
    .m_axi_awvalid  (tml_awvalid),
    .m_axi_awaddr   (tml_awaddr ),
    .m_axi_awlen    (tml_awlen  ),
    .m_axi_awid     (tml_awid   ),
    .m_axi_awsize   (tml_awsize ),
    .m_axi_awburst  (tml_awburst),
    .m_axi_awprot   (tml_awprot ),
    .m_axi_awlock   (tml_awlock[0]),
    .m_axi_awcache  (tml_awcache),
    .m_axi_awready  (tml_awready),
    .m_axi_wdata    (tml_wdata  ),
    .m_axi_wstrb    (tml_wstrb  ),
    .m_axi_wlast    (tml_wlast  ),
    .m_axi_wvalid   (tml_wvalid ),
    .m_axi_wready   (tml_wready ),
    .m_axi_bresp    (tml_bresp  ),
    .m_axi_bvalid   (tml_bvalid ),
    .m_axi_bready   (tml_bready ),
    .m_axi_arvalid  (tml_arvalid),
    .m_axi_araddr   (tml_araddr ),
    .m_axi_arlen    (tml_arlen  ),
    .m_axi_arid     (tml_arid   ),
    .m_axi_arsize   (tml_arsize ),
    .m_axi_arburst  (tml_arburst),
    .m_axi_arprot   (tml_arprot ),
    .m_axi_arlock   (tml_arlock[0]),
    .m_axi_arcache  (tml_arcache),
    .m_axi_arready  (tml_arready),
    .m_axi_rvalid   (tml_rvalid ),
    .m_axi_rdata    (tml_rdata  ),
    .m_axi_rlast    (tml_rlast  ),
    .m_axi_rresp    (tml_rresp  ),
    .m_axi_rready   (tml_rready )
);
`endif  // MMT_TINYML_ENABLE

ddr3_top                 u_ddr3_top
(

.axi_clk                (core_clk            ),
.core_clk               (core_clk            ),
.sdram_clk              (sdram_clk           ),  
.rx_cal_clk             (rx_cal_clk          ),
.tx_cal_clk             (tx_cal_clk          ),
.tx_cal_clk_90edge      (tx_cal_clk_90edge   ),
.rstn                   (w_arstn             ),      
.pll_shift              (pll_shift           ),
.pll_shift_sel          (pll_shift_sel       ),
.pll_shift_ena          (pll_shift_ena       ),       
///////////////DDR BUS
.ddr_ck_hi              (ddr_ck_hi           ),
.ddr_ck_lo              (ddr_ck_lo           ),
.ddr_cke                (ddr_cke             ),    
.ddr_reset_n            (ddr_reset_n         ),
.ddr_cs_n               (ddr_cs_n            ),
.ddr_ras_n              (ddr_ras_n           ),
.ddr_cas_n              (ddr_cas_n           ),
.ddr_we_n               (ddr_we_n            ),     
.ddr_addr               (ddr_addr            ),
.ddr_ba                 (ddr_ba              ),

.ddr_dqs_oe             (ddr_dqs_oe          ),
.ddr_dqs_oe_n           (ddr_dqs_oe_n        ),
.ddr_dq_oe              (ddr_dq_oe           ),
.ddr_dqs_in_hi          (ddr_dqs_in_hi       ),
.ddr_dqs_in_lo          (ddr_dqs_in_lo       ),
.ddr_dq_in_hi           (ddr_dq_in_hi        ),
.ddr_dq_in_lo           (ddr_dq_in_lo        ),

.ddr_dqs_out_hi         (ddr_dqs_out_hi      ),
.ddr_dqs_out_lo         (ddr_dqs_out_lo      ),
.ddr_dq_out_hi          (ddr_dq_out_hi       ),
.ddr_dq_out_lo          (ddr_dq_out_lo       ),

.ddr_dm_hi              (ddr_dm_hi           ),
.ddr_dm_lo              (ddr_dm_lo           ),
.ddr_odt                (ddr_odt             ),

// Application interface ports
.app_sr_req                     (1'b0),
.app_ref_req                    (1'b0),
.app_zq_req                     (1'b0),
.app_sr_active                  (app_sr_active),
.app_ref_ack                    (app_ref_ack),
.app_zq_ack                     (app_zq_ack),

// Slave Interface Write Address Ports
.s_axi_awid                     (s_axi_awid        ),
.s_axi_awaddr                   (s_axi_awaddr      ),
.s_axi_awlen                    (s_axi_awlen       ),
.s_axi_awsize                   (s_axi_awsize      ),
.s_axi_awburst                  (s_axi_awburst     ),
.s_axi_awlock                   (s_axi_awlock[0]   ),
.s_axi_awcache                  (s_axi_awcache     ),
.s_axi_awprot                   (s_axi_awprot      ),
.s_axi_awqos                    (s_axi_awqos       ),
.s_axi_awvalid                  (s_axi_awvalid     ),
.s_axi_awready                  (s_axi_awready     ),
// Slave Interface Write Data Ports
.s_axi_wdata                    (s_axi_wdata       ),
.s_axi_wstrb                    (s_axi_wstrb       ),
.s_axi_wlast                    (s_axi_wlast       ),
.s_axi_wvalid                   (s_axi_wvalid      ),
.s_axi_wready                   (s_axi_wready      ),
// Slave Interface Write Response Ports
.s_axi_bid                      (s_axi_bid         ),
.s_axi_bresp                    (s_axi_bresp       ),
.s_axi_bvalid                   (s_axi_bvalid      ),
.s_axi_bready                   (s_axi_bready      ),
// Slave Interface Read Address Ports
.s_axi_arid                     (s_axi_arid        ),
.s_axi_araddr                   (s_axi_araddr      ),
.s_axi_arlen                    (s_axi_arlen       ),
.s_axi_arsize                   (s_axi_arsize      ),
.s_axi_arburst                  (s_axi_arburst     ),
.s_axi_arlock                   (s_axi_arlock[0]   ),
.s_axi_arcache                  (s_axi_arcache     ),
.s_axi_arprot                   (s_axi_arprot      ),
.s_axi_arqos                    (s_axi_arqos       ),
.s_axi_arvalid                  (s_axi_arvalid     ),
.s_axi_arready                  (s_axi_arready     ),
// Slave Interface Read Data Ports
.s_axi_rid                      (s_axi_rid         ),
.s_axi_rdata                    (s_axi_rdata       ),
.s_axi_rresp                    (s_axi_rresp       ),
.s_axi_rlast                    (s_axi_rlast       ),
.s_axi_rvalid                   (s_axi_rvalid      ),
.s_axi_rready                   (s_axi_rready      ),
//DEBUG       
.wrlvl_dq_check                 (wrlvl_dq_check    ) ,
.rd_level_dqs_check             (rd_level_dqs_check) ,
.init_cur_state                 (init_cur_state    ) ,
.idelay_ld                      (idelay_ld         ) ,
.mpr_rdlvl_dly                  (mpr_rdlvl_dly     ) ,
.cal_done                       (cal_done          ) 
);

//***************************************************************************
// debayer
//***************************************************************************


wire        rgb_vs;
wire        rgb_hs;
wire        rgb_de;
wire        rgb_valid;
wire [47:0] rgb_datax2;


debayer_top_2to1 debayer_top
(
	.in_pclk		  (vid_clk_dvi2),//(i_mipi_rx_pclk ),
	.in_rstn		  (vid_rst_n	),
	
	.raw_vs_i		  (ch0_vs		      ),
	.raw_hs_i		  (ch0_hs		      ),
	.raw_de_i		  (ch0_de		      ),
	.raw_valid_i	(ch0_de	        ),
	.raw_datax4_i	({ch0_b,ch0_g}	),
	
	.rgb_vs_o		  (rgb_vs         ),
	.rgb_hs_o		  (rgb_hs         ),
	.rgb_de_o		  (rgb_de         ),
	.rgb_valid_o	(rgb_valid      ),
	.rgb_datax2_o (rgb_datax2     )//b,g,r,b,g,r
);
reg vid_cnt = 'd0;
reg [7:0] hdmi_tx_rdata ;
reg [7:0] hdmi_tx_gdata ;
reg [7:0] hdmi_tx_bdata ;
reg hdmi_tx_vs;
reg hdmi_tx_hs;
reg hdmi_tx_de;
always @( posedge hdmi_tx_slow_clk )
begin
  vid_cnt <= ~vid_cnt ;
  if( vid_cnt )
    {hdmi_tx_rdata,hdmi_tx_gdata,hdmi_tx_bdata} <= rgb_datax2[23:0];
  else 
    {hdmi_tx_rdata,hdmi_tx_gdata,hdmi_tx_bdata} <= rgb_datax2[47:24];

  hdmi_tx_vs <= rgb_vs;
  hdmi_tx_hs <= rgb_hs;
  hdmi_tx_de <= rgb_de;
end
//==============================================================================
// MIPI DSI
//==============================================================================
// signal 

reg		[25:0]	r_rst_cnt;

wire	[31:0]	w_axi_rdata;
wire			w_axi_awready;
wire			w_axi_wready;
wire			w_axi_arready;
wire			w_axi_rvalid;
wire			w_axi_bvalid;

wire	[6:0]	w_axi_awaddr;
wire			w_axi_awvalid;
wire	[31:0]	w_axi_wdata;
wire			w_axi_wvalid;
wire			w_axi_bready;
wire	[6:0]	w_axi_araddr;
wire			w_axi_arvalid;
wire			w_axi_rready;

wire			w_confdone;


assign  LCD_POWER 			= i_arstn;
assign	LCD_RST_P	      = ~w_arstn;//~r_rst_cnt[23]; LCD复位先释放，然后再释放MIPI 的复位
////////////////////////////////////////////////////////////////
always@(posedge i_mipi_clk or  negedge w_arstn )
begin
  if ( !w_arstn ) begin
    r_rst_cnt	<= 'd0;
  end else 		
    r_rst_cnt	<= r_rst_cnt[25] ? r_rst_cnt :r_rst_cnt + 1'b1;
end

wire axi_rst_n = r_rst_cnt[25];

reg [26:0] dly_cnt = 'd0;

// ★ 2026-10-11 修复（根因见 docs\帧缓冲写通路根因-3.md 与本次实验 X1/X3/Y1/Y2）：
//   原为 `else if( w_confdone )`。但 w_confdone 是 panel_config 的 AXI 配置握手结果，
//   而我们**删掉了 DSI TX（面板）**之后，panel_config 的 AXI 主口（w_axi_*，L1101-1115）
//   没有任何从设备：awready/wready/bvalid 永远不响应 ⇒ o_confdone 永不置位
//   ⇒ w_confdone 恒 0 ⇒ dly_cnt 不计数 ⇒ **vid_rst_n 恒 0**
//   ⇒ 整条视频链（frame_buffer / debayer / …）被永久按在复位态
//   ⇒ 综合器据此把帧缓冲**写通路折成常量**（实测 map.rpt 里 fb_awvalid/fb_wvalid/
//     fb_wlast/state[1:0] 全是 (optimized to 0)、ddr_wr_buffer_inst 的 RAM = 0）。
//   我们没有面板要等，所以去掉这个门控：释放 w_arstn 后由 vid_clk_dvi2（75MHz，150MHz 方案）自己数，
//   约 2^26/75MHz = 67108864/75e6 ≈ 0.895 s 后释放 vid_rst_n。像素域的复位仍由 CSI RX 自己的
//   reset_pixel_n（i_mipi_rx_pclk 域同步复位）负责，不受影响。
always @( posedge vid_clk_dvi2 or negedge w_arstn )
begin
  if( !w_arstn )
    dly_cnt <= 'd0;
  else
    dly_cnt <= dly_cnt[26] ? dly_cnt :(dly_cnt + 1'b1);
end 

assign vid_rst_n = dly_cnt[26];



// Panel driver initialization
panel_config
#(
  .INITIAL_CODE	("Panel_1080p_reg.mem"),
  .REG_DEPTH		(9'd150)
)
inst_panel_config
(
  .i_axi_clk		(i_mipi_clk		),
  .i_restn		(axi_rst_n),
  
  .i_axi_awready	(w_axi_awready	),
  .i_axi_wready	(w_axi_wready	),
  .i_axi_bvalid	(w_axi_bvalid	),
  .o_axi_awaddr	(w_axi_awaddr	),
  .o_axi_awvalid	(w_axi_awvalid	),
  .o_axi_wdata	(w_axi_wdata	),
  .o_axi_wvalid	(w_axi_wvalid	),
  .o_axi_bready	(w_axi_bready	),
  
  .i_axi_arready	(w_axi_arready	),
  .i_axi_rdata	(w_axi_rdata	),
  .i_axi_rvalid	(w_axi_rvalid	),
  .o_axi_araddr	(w_axi_araddr	),
  .o_axi_arvalid	(w_axi_arvalid	),
  .o_axi_rready	(w_axi_rready	),
  
  .o_addr_cnt		(			),
  .o_state		(			),
  .o_confdone		(w_confdone	),
  
  .i_dbg_we		(0	),
  .i_dbg_din		(0	),
  .i_dbg_addr		(0	),
  .o_dbg_dout		(	),
  .i_dbg_reconfig	(0	)
);

wire hs;
wire vs;
wire de;
wire [7:0] rgb_r;
wire [7:0] rgb_g;
wire [7:0] rgb_b;
  
  // color_bar_rgb #(
  // .HS_POLORY 		(1'b1		),
  // .VS_POLORY 		(1'b1		),
  // .H_FRONT_PORCH 	(HFP		),///2
  // .H_SYNC 		(HSP		),//
  // .H_VALID 		(MAX_HRES	),//
  // .H_BACK_PORCH 	(HBP		),//
  // .V_FRONT_PORCH 	(VFP		),
  // .V_SYNC 		(VSP		),
  // .V_VALID 		(MAX_VRES	),
  // .V_BACK_PORCH 	(VBP		),
  // .TEST_MODE 		(2'd2)
  // )u_color_bar_rgb1(
  // /*i*/.clk	(vid_clk_dvi2),//(vid_clk),
  // /*i*/.rst_n	(vid_rst_n),
  // /*o*/.hs	(hs),
  // /*o*/.vs	(vs),
  // /*o*/.de	(de),
  // // /*O*/.h_cnt (h_cnt),
  // // /*O*/.v_cnt (v_cnt),
  // /*o*/.rgb_r	(rgb_r),    //像素数据、红色分量
  // /*o*/.rgb_g	(rgb_g),    //像素数据、绿色分量
  // /*o*/.rgb_b (rgb_b)    //像素数据、蓝色分量
  
  // );

// MIPI DSI TX Channel
// ch0_vs		    
// ch0_hs		    
// ch0_de		    
// ch0_de	      
// {ch0_g,ch0_b}

//=================================================================================
//hdmi tx ctrl 
//=================================================================================
wire                            video_hs;
wire                            video_vs;
wire                            video_de;
wire[7:0]                       video_r;
wire[7:0]                       video_g;
wire[7:0]                       video_b;

assign tmds_tx_data0_TX_OE = 1'b1;
assign tmds_tx_data1_TX_OE = 1'b1;
assign tmds_tx_data2_TX_OE = 1'b1;
assign tmds_tx_clk_TX_OE   = 1'b1;

assign tmds_tx_data0_TX_RST = 1'b0;
assign tmds_tx_data1_TX_RST = 1'b0;
assign tmds_tx_data2_TX_RST = 1'b0;
assign tmds_tx_clk_TX_RST   = 1'b0;

// 	  color_bar color_bar_m0(
// 	.clk(hdmi_tx_slow_clk),
// 	.rst(~vid_rst_n),
// 	.hs(video_hs),
// 	.vs(video_vs),
// 	.de(video_de),
// 	.rgb_r(video_r),
// 	.rgb_g(video_g),
// 	.rgb_b(video_b)
// );

wire [9:0] tmds_data0;
wire [9:0] tmds_data1;
wire [9:0] tmds_data2;
wire [9:0] tmds_clk ;

//==========================================================================
// ★ 2026-10-15 修复：dvi_encoder 的这几个输入在顶层**从来没有被驱动**
//------------------------------------------------------------------------
// 证据（Efinity 自己的日志，不是推断）：
//   out\mmt.warn.log:2426-2431 六条 VDB-1002「does not have a driver」：
//     video_format / audio_L / audio_R / audio_valid / audio_samp_freq / audio_samp_word_len
//   out\mmt.warn.log:2359 VERI-1330：`video_format` 实际位宽 1，端口要 2 位
//     ⇒ 说明它是**隐式 1 位线**，在网表里没有驱动源。
//
// 为什么这会导致"显示器无信号"：
//   `i_video_format` 决定编码器按 RGB(00) / YCbCr 4:2:2(01) / YCbCr 4:4:4(10) 编码。
//   悬空 ⇒ 取值不确定 ⇒ 编码器可能根本不按 RGB 输出 ⇒ 显示器解不出有效 TMDS ⇒ 锁不住。
//
// 这里显式驱动成"RGB + 无音频"。位宽按端口要求给，避免再出 VERI-1330。
// 顺带说明：厂商参考顶层 ti60f225_oob_top.v:969-977 这几个信号**同样是悬空的**，
//   属于厂商遗留缺陷（它的 demo 位流也许因此也出不了图）；我们把它修掉。
//==========================================================================
wire [1:0]  video_format          = 2'b00;   // 00 = RGB
wire [23:0] audio_L               = 24'd0;
wire [23:0] audio_R               = 24'd0;
wire        audio_valid           = 1'b0;    // 无音频输入
wire [3:0]  audio_samp_freq       = 4'd0;
wire [1:0]  audio_samp_word_len   = 2'd0;    // 与 audio_max_word_length 拼成 4 位给端口
wire [1:0]  audio_max_word_length = 2'd0;


dvi_encoder dvi_encoder_m0
(
	.pixelclk      		(hdmi_tx_slow_clk          ),// system clock
	.rst_p         		(~vid_rst_n      ),// reset
	.i_bdata      		(osd_b ),   // ★ 改成接 OSD 叠加后的像素（命名 r/b 反，
	.i_gdata     		(osd_g ),   //    所以 bdata 接 osd_b）
	.i_rdata       		(osd_r ),
	.i_hs         		(osd_hs ),  // ★ 2026-10-15：**不交叉**——已用明文 dvi_encoder 证实这是对的
	.i_vs         		(osd_vs ),  //   证据（板卡资料包 02_Ti60F225_hdmi_demo 里有一份**明文**的
	                                //   source/hdmi_src/dvi_tx/dvi_encoder.v）：
	                                //     :324  encode encb (              // 蓝通道编码器
	                                //     :329    .c0 (ram_hs_r[...]),    // i_hs → c0
	                                //     :330    .c1 (ram_vs_r[...])     // i_vs → c1
	                                //   而 TMDS/DVI 里蓝通道控制位 {c1,c0} = {VSYNC,HSYNC}
	                                //   ⇒ 端口名就是字面意思：i_hs 要接 HSYNC、i_vs 要接 VSYNC。
	                                //   厂商 10_sc431hai2hdmi_v1 顶层 :966-967 的交叉是 bug：
	                                //   同一 demo 的 v4/v5/v6 已经改回直连；02 号 hdmi_demo、
	                                //   03_hdmi_tx_demo、09_hdmi2dsi 也都是直连。
	                                //   2026-10-15 夜间曾一度照抄厂商改成交叉，属于引入回归，已撤回。
	.i_de            	(osd_de ),
  .video_format     (video_format), //// 00 = RGB, 01 = YCbCr 4:2:2, 10 = YCbCr 4:4:4
  .video_VIC        (0),
	.audio_L			    (audio_L),
  .audio_R			    (audio_R),
  .audio_valid		  (audio_valid),
  .audio_N                (6144),     //(20'h01880),//     
  .audio_CTS              (150000),      // 像素时钟实为 150MHz（USER_PLL VCO 3000MHz ÷20）；CTS=f_pix/1000（N=6144 对应 48kHz: 128·fs=N·f_pix/CTS ⇒ 与 f_pix 成正比）；原 148500 对应 148.5MHz
  .audio_sample_frequency (audio_samp_freq),    //(3'b000),// 
  .audio_word_length      ({audio_samp_word_len,audio_max_word_length}),//(4'b1011),//

	.tmds_data0    		(tmds_data0),
  .tmds_data1    		(tmds_data1),
  .tmds_data2    		(tmds_data2),
  .tmds_clk      	  (tmds_clk  )
);
assign tmds_tx_clk_TX_DATA   = ~tmds_clk;
assign tmds_tx_data0_TX_DATA = ~tmds_data0;
assign tmds_tx_data1_TX_DATA = ~tmds_data1;
assign tmds_tx_data2_TX_DATA = ~tmds_data2;


//==========================================================================================
//  多模态 AI 智能终端 —— 传感器 / 算法 / RISC-V 软核 / 报警 的互连
//  （本节把我们自己写的模块接进这条已验证的摄像头链路）
//------------------------------------------------------------------------------------------
//  ★ 时钟域划分（重要）：
//    · 视频域 hdmi_tx_slow_clk (139.997MHz，周期 7.143ns)：降采样灰度化 → 帧差法 → 融合决策
//      因为视频像素流本身在这个域里，跨域搬像素没有意义
//    · 系统域 core_clk (100MHz)：传感器 I2C 采集、RISC-V SoC、报警输出
//    · 两域之间用 mmt_sync2 两级同步器搬控制/状态信号
//
//  ⚠️ 已知的 bring-up 级局限（正式版必须改进，记在这里别忘了）：
//    1) bg_clear 是单周期脉冲，跨域后可能被漏掉（core 周期 10ns > video 周期 7.143ns）。
//       现在靠"软核写一次、下次再写一次"的冗余来兜。正式版应改成电平+边沿检测。
//    2) 多比特状态（sum_area / score）按位同步，理论上可能读到从未存在过的中间值。
//       正式版应改成"帧结束时锁存快照 + 握手"。
//    3) 传感器 I2C / 蜂鸣器 / UART 的引脚都还是随机布局（peri.xml 里没有），
//       等板子到手对着原理图定引脚后要补约束。
//==========================================================================================

//--------------------------------------------------------------------
// 1. 降采样 + 灰度化（视频域）：1920×1080 彩色 → 160×120 灰度
//--------------------------------------------------------------------
wire [7:0] gray_pix;
wire       gray_de, gray_vs;
wire [15:0] gray_frame_cnt;

mmt_video_downscale #(
    .OUT_W (160),
    .OUT_H (120),
    .X_DEC (12),
    .Y_DEC (9)
) u_downscale (
    .clk       (hdmi_tx_slow_clk),
    .rst_n     (w_arstn),
    // ★ 2026-10-13 修复（task-18 仿真实证）：原接法是 .in_r(hdmi_tx_bdata)/.in_b(hdmi_tx_rdata)，
    //   把蓝接到红通道 ⇒ 画面全紫。厂商原设计留下的注释 "b,g,r" 才是错的源头；
    //   仿真实测：正接 11/22/33 → 输出 11/22/33；原接法 → 输出 33/22/11（R/B 颠倒）。
    .in_r      (hdmi_tx_rdata),
    .in_g      (hdmi_tx_gdata),
    .in_b      (hdmi_tx_bdata),
    .in_de     (hdmi_tx_de),
    .in_vs     (hdmi_tx_vs),
    .out_gray  (gray_pix),
    .out_de    (gray_de),
    .out_vs    (gray_vs),
    .frame_cnt (gray_frame_cnt)
);

//--------------------------------------------------------------------
// 2. OSD 叠加显示（视频域）：温度热力图小窗 + 参数文字 + 报警红框
//    插在「帧缓存输出 → dvi_encoder」之间
//--------------------------------------------------------------------
wire [7:0] osd_r, osd_g, osd_b;
wire       osd_de, osd_hs, osd_vs;

// 文字缓冲：3 行 × 48 字符 = 144 字节（软核写、OSD 读，跨时钟域）
wire [7:0]  osd_txt_rd_addr, osd_txt_rd_data;
wire [9:0]  osd_th_rd_addr;
wire [7:0]  osd_th_rd_data;

mmt_dpram_2clk #(.DW(8), .AW(8), .DEPTH(256)) u_osd_txt_ram (
    .clk_a  (core_clk),
    .we_a   (osd_txt_we),
    .addr_a (osd_txt_addr),
    .data_a (osd_txt_data),
    .clk_b  (hdmi_tx_slow_clk),
    .addr_b (osd_txt_rd_addr),
    .data_b (osd_txt_rd_data)
);

// 热力图缓冲：32×24 = 768 字节（色阶 0..255）
mmt_dpram_2clk #(.DW(8), .AW(10), .DEPTH(768)) u_osd_th_ram (
    .clk_a  (core_clk),
    .we_a   (osd_th_we),
    .addr_a (osd_th_addr),
    .data_a (osd_th_data),
    .clk_b  (hdmi_tx_slow_clk),
    .addr_b (osd_th_rd_addr),
    .data_b (osd_th_rd_data)
);

mmt_osd_overlay #(
    .H_ACTIVE (1920),
    .V_ACTIVE (1080)
) u_osd (
    .vclk       (hdmi_tx_slow_clk),
    .vrst_n     (w_arstn),
    // ★ 2026-10-13 修复：同上（此处是"显示主通路"的 R/B 交叉，就是"全紫"的直接原因）
    .i_r        (hdmi_tx_rdata),
    .i_g        (hdmi_tx_gdata),
    .i_b        (hdmi_tx_bdata),
    .i_de       (hdmi_tx_de),
    .i_hs       (hdmi_tx_hs),
    .i_vs       (hdmi_tx_vs),
    .o_r        (osd_r),
    .o_g        (osd_g),
    .o_b        (osd_b),
    .o_de       (osd_de),
    .o_hs       (osd_hs),
    .o_vs       (osd_vs),
    .th_rd_addr (osd_th_rd_addr),
    .th_rd_data (osd_th_rd_data),
    .txt_rd_addr(osd_txt_rd_addr),
    .txt_rd_data(osd_txt_rd_data),
    // ★ 这里必须用**视频域**的 alg_alarm（算法实例输出，hdmi_tx_slow_clk 域）。
    //   原来接 alg_alarm_s —— 那是 alg_alarm 经 mmt_sync2 同步到 **core_clk（系统域）** 的结果
    //   （见下方 "6. 状态信号跨域：视频域 → 系统域"），给系统域的 SoC / LED 用才对；
    //   拿到视频域的 OSD 里做组合逻辑，就是一条不同步的 core→video CDC 通路
    //   （时序报告里 core_clk→hdmi_tx_slow_clk 那批失败路径的来源）。
    .alarm      (alg_alarm)
);

//--------------------------------------------------------------------
// 3. RISC-V 软核子系统（系统域）：SoC + APB 寄存器桥
//--------------------------------------------------------------------
wire [7:0]  cfg_diff_thr;
wire [15:0] cfg_min_area;
wire [7:0]  cfg_score_thr;
wire [4:0]  cfg_auth_start, cfg_auth_end, cfg_hour;
wire [7:0]  cfg_vision_prob;
wire        cfg_vision_valid;
wire signed [15:0] cfg_body_max_t;
wire        cfg_ir_valid;
wire signed [15:0] cfg_ambient_t;
wire        cfg_env_valid;
wire        cfg_diff_enable, cfg_bg_freeze, cfg_bg_clear_tgl, cfg_alarm_mute;
wire [9:0]  cfg_ir_frame_addr;
wire [15:0] cfg_rh_x100;
wire [15:0] cfg_ir_rd_data;
// OSD 显示缓冲写口（软核 → OSD RAM）
wire        osd_txt_we;
wire [7:0]  osd_txt_addr, osd_txt_data;
wire        osd_th_we;
wire [9:0]  osd_th_addr;
wire [7:0]  osd_th_data;

// 传感器子系统状态与红外帧 RAM 读口
wire        sensor_sht_valid, sensor_sht_crc_err, sensor_sht_bus_err;
wire signed [15:0] sensor_sht_temp;
wire [15:0] sensor_sht_rh, sensor_sht_temp_raw, sensor_sht_rh_raw;
wire [15:0] sensor_ir_frame_cnt, sensor_ir_ta_raw, sensor_ir_rd_data;
wire        sensor_ir_frame_valid, sensor_ir_bus_err;
wire        sensor_i2c_busy;
wire [2:0]  sensor_i2c_owner;

// 算法子系统状态（视频域，需要同步到系统域）
wire        alg_motion_done, alg_motion_flag;
wire [31:0] alg_sum_area, alg_sum_x, alg_sum_y;
wire [7:0]  alg_conf_v, alg_conf_t, alg_conf_e;
wire [8:0]  alg_score;
wire        alg_in_auth, alg_alarm;

//--------------------------------------------------------------------------
// SPI0：**不在这里做三态** —— 见端口处的说明。
//   这 8 个信号是顶层端口，直接接到子系统；peri 的 GPIO pad 负责三态与回读。
//--------------------------------------------------------------------------
//==========================================================================
// ★ task-19：摄像头上游探针 —— 把 4 个时钟域的信号变成 SoC 可读的计数器
//==========================================================================
wire [3:0]  cam_probe_raddr;
wire [31:0] cam_probe_rdata;

mmt_cam_probe u_cam_probe (
    .clk      (core_clk        ),
    .rst_n    (w_arstn         ),
    .clk_5m   (CLK_5M          ),
    .clk_byte (i_cam_ck_CLKOUT ),
    .clk_pixel(i_mipi_rx_pclk  ),
    // ★ 2026-10-13 修复（Claude 审查发现）：原接 io_cam_scl_OUT 是恒 0 的！
    //   OpenCores I2C 开漏写法：i2c_master_ctrl_top.v:13 注释写明 "always 1'b0"，
    //   最底层 scl_o = 1'b0；真正翻转的是输出使能 scl_padoen_o
    //   （mmt_top.v:679 assign io_cam_scl_OE = ~scl_padoen_o）。
    //   原接法会让 SCL 探针恒 0（I2C 跑没跑看不出来），还可能被综合器折成常量。
    .cam_scl  (io_cam_scl_OE   ),
    .cam_sda  (io_cam_sda_IN   ),
    .csi_de   (w_mipi_rx_de    ),
    .csi_hs   (w_mipi_rx_hs    ),
    .csi_vs   (w_mipi_rx_vs    ),
    .csi_pixel_data (w_mipi_rx_data),
    .pix_rstn (w_mipi_rx_pclk_arstn),
    .hs_ck_ena(o_cam_ck_HS_ENA ),
    .hs_d0_ena(cam_d0_HS_ENA   ),
    .hs_d1_ena(cam_d1_HS_ENA   ),
    .hs_d2_ena(cam_d2_HS_ENA   ),
    .hs_d3_ena(cam_d3_HS_ENA   ),
    .csi_word_count    (csi_word_count   ),
    .csi_datatype      (csi_datatype     ),
    .csi_vc            (csi_vc           ),
    .csi_pixel_per_clk (csi_pixel_per_clk),
    .csi_fifo_rd_empty (cam_fifo_rd_empty),
    .csi_irq           (csi_irq          ),
    .raddr    (cam_probe_raddr ),
    .rdata    (cam_probe_rdata )
);


mmt_soc_subsystem u_soc (
    .clk        (core_clk),
    .rst_n      (w_arstn),

    .uart_txd   (o_uart_txd),
    .uart_rxd   (i_uart_rxd),

    // ---- SPI0（路线 B：读板载 flash → 搬 app/模型进 DDR）----
    //   顶层做成三态：SoC 只给 read/write/writeEnable 三根分线，
    //   这里按 writeEnable 决定驱动还是高阻，回读信号直接来自双向脚。
    //   peri 的 GPIO 块（inout 模式）按 *_read/_write/_writeEnable 的名字找它们。
    .spi_data0_read        (system_spi_0_io_data_0_read),
    .spi_data0_write       (system_spi_0_io_data_0_write),
    .spi_data0_writeEnable (system_spi_0_io_data_0_writeEnable),
    .spi_data1_read        (system_spi_0_io_data_1_read),
    .spi_data1_write       (system_spi_0_io_data_1_write),
    .spi_data1_writeEnable (system_spi_0_io_data_1_writeEnable),
    .spi_sclk              (system_spi_0_io_sclk_write),
    .spi_ss                (system_spi_0_io_ss),

    // SoC 的 JTAG 调试口★
    //   —— 端口名必须与 Interface Designer 的 JTAG_USER1 硬块一致：
    //      peri 里声明 <efxpt:jtag name="jtag_inst1" jtag_def="JTAG_USER1">，
    //      它要求顶层有 jtag_inst1_TDI/TDO（标为 required），
    //      否则 efx_pnr 报 "Required pin jtag_inst1_TDI is not found" 并直接失败。
    //      命名照抄板卡包 demo 的 edge_vision_soc.v：
    //          input  jtag_inst1_TCK/TDI/SEL/CAPTURE/SHIFT/UPDATE/RESET
    //          output jtag_inst1_TDO
    //      接法也就是 SoC 的 jtagCtrl_*。
    //   原来这里把 8 个信号全部端接成常量，等于**主动放弃了 RISC-V 调试能力**，
    //   上板 bring-up 时会很难受 —— 现在引出来。
    .jtag_tck     (jtag_inst1_TCK),
    .jtag_tdi     (jtag_inst1_TDI),
    .jtag_tdo     (jtag_inst1_TDO),
    .jtag_enable  (jtag_inst1_SEL),
    .jtag_capture (jtag_inst1_CAPTURE),
    .jtag_shift   (jtag_inst1_SHIFT),
    .jtag_update  (jtag_inst1_UPDATE),
    .jtag_reset   (jtag_inst1_RESET),

    // AXI 主口：暂未接 DDR3（固件只要不访问外部存储就不会等）。
    // 后续接 DDR3 控制器时接这里。
    .axim_awaddr  (), .axim_awlen   (), .axim_awsize  (), .axim_awburst (),
    .axim_awlock  (), .axim_awcache (), .axim_awqos   (), .axim_awprot  (),
    .axim_awregion(), .axim_awid    (), .axim_awvalid (),
    .axim_awready (1'b0),
    .axim_wdata   (), .axim_wstrb   (), .axim_wlast   (), .axim_wvalid  (),
    .axim_wready  (1'b0),
    .axim_bid     (8'd0), .axim_bresp(2'd0), .axim_bvalid(1'b0),
    .axim_bready  (),
    .axim_araddr  (), .axim_arlen   (), .axim_arsize  (), .axim_arburst (),
    .axim_arlock  (), .axim_arcache (), .axim_arqos   (), .axim_arprot  (),
    .axim_arregion(), .axim_arid    (), .axim_arvalid (),
    .axim_arready (1'b0),
    .axim_rdata   (32'd0), .axim_rid  (8'd0), .axim_rresp (2'd0),
    .axim_rlast   (1'b0),  .axim_rvalid(1'b0),
    .axim_rready  (),

    // ---- ★ DDR AXI4 主口（路线 B）：接 AXI 互联的 s1 ----
    .ddrm_awvalid (soc_ddr_awvalid ),
    .ddrm_awaddr  (soc_ddr_awaddr  ),
    .ddrm_awlen   (soc_ddr_awlen   ),
    .ddrm_awsize  (soc_ddr_awsize  ),
    .ddrm_awburst (soc_ddr_awburst ),
    .ddrm_awlock  (soc_ddr_awlock  ),
    .ddrm_awcache (soc_ddr_awcache ),
    .ddrm_awprot  (soc_ddr_awprot  ),
    .ddrm_awqos   (soc_ddr_awqos   ),
    .ddrm_awregion(soc_ddr_awregion),
    .ddrm_awid    (soc_ddr_awid    ),
    .ddrm_awready (soc_ddr_awready ),
    .ddrm_wdata   (soc_ddr_wdata   ),
    .ddrm_wstrb   (soc_ddr_wstrb   ),
    .ddrm_wlast   (soc_ddr_wlast   ),
    .ddrm_wvalid  (soc_ddr_wvalid  ),
    .ddrm_wready  (soc_ddr_wready  ),
    .ddrm_bresp   (soc_ddr_bresp   ),
    .ddrm_bid     (soc_ddr_bid     ),
    .ddrm_bvalid  (soc_ddr_bvalid  ),
    .ddrm_bready  (soc_ddr_bready  ),
    .ddrm_arvalid (soc_ddr_arvalid ),
    .ddrm_araddr  (soc_ddr_araddr  ),
    .ddrm_arlen   (soc_ddr_arlen   ),
    .ddrm_arsize  (soc_ddr_arsize  ),
    .ddrm_arburst (soc_ddr_arburst ),
    .ddrm_arlock  (soc_ddr_arlock  ),
    .ddrm_arcache (soc_ddr_arcache ),
    .ddrm_arprot  (soc_ddr_arprot  ),
    .ddrm_arqos   (soc_ddr_arqos   ),
    .ddrm_arregion(soc_ddr_arregion),
    .ddrm_arid    (soc_ddr_arid    ),
    .ddrm_arready (soc_ddr_arready ),
    .ddrm_rdata   (soc_ddr_rdata   ),
    .ddrm_rresp   (soc_ddr_rresp   ),
    .ddrm_rid     (soc_ddr_rid     ),
    .ddrm_rlast   (soc_ddr_rlast   ),
    .ddrm_rvalid  (soc_ddr_rvalid  ),
    .ddrm_rready  (soc_ddr_rready  ),

`ifdef MMT_TINYML_ENABLE
    // ---- ★ 自定义指令口 ←→ TinyML 加速器 ----
    .ci_cmd_valid   (ci_cmd_valid  ),
    .ci_function_id (ci_function_id),
    .ci_inputs_0    (ci_inputs_0   ),
    .ci_inputs_1    (ci_inputs_1   ),
    .ci_rsp_ready   (ci_rsp_ready  ),
    .ci_cmd_ready   (ci_cmd_ready  ),
    // ★ 2026-10-15 修复：加速器完成中断必须接进 SoC，否则推理调用死等。
    //   证据（官方 tinyml_lib.a / conv.o 反汇编）：
    //     conv_drv  67c: lw x27,0(x18) ; 680: beqz x27,67c   ← 自旋等 .LANCHOR0[hart]
    //     conv_intr  44: sw x31,0(x30)                        ← 唯一置位处（ISR 内）
    //   官方 tinyml_soc.v:473 同样是 assign userInterruptA = cpu_customInstruction_cmd_int;
    //   同域：加速器 cmd_int 与 SoC clk 都是 core_clk，无需 CDC。
    .ci_cmd_int     (tml_cmd_int   ),
    .ci_rsp_valid   (ci_rsp_valid  ),
    .ci_outputs_0   (ci_outputs_0  ),
`else
    // ---- TinyML 剪除态：加速器不在，ci_* 这九个端口必须全部有人驱动 ----
    //   ci_cmd_ready=0：CPU 若真发 CI 指令会一直等，这是刻意的 fail-closed；
    //   固件 MMT_TINYML_ISSUE_EN 本来就是 0，不会走到这条路。
    //
    //   ★ 2026-10-18 修正（首次真机综合报 VERI-1180 constant is not allowed here）：
    //     前 5 个（cmd_valid/function_id/inputs_0/inputs_1/rsp_ready）是 u_soc 的 **output**
    //     （见 rtl/mmt/soc/mmt_soc_subsystem.v:144-148），Verilog 不允许 output 口接常量。
    //     这 5 个改接回同名 wire（447-451 行本就无条件声明），悬空无害；
    //     后 4 个是 u_soc 的 **input**，接常量合法，保持 fail-closed。
    .ci_cmd_valid   (ci_cmd_valid  ),
    .ci_function_id (ci_function_id),
    .ci_inputs_0    (ci_inputs_0   ),
    .ci_inputs_1    (ci_inputs_1   ),
    .ci_rsp_ready   (ci_rsp_ready  ),
    .ci_cmd_ready   (1'b0          ),
    .ci_cmd_int     (1'b0          ),
    .ci_rsp_valid   (1'b0          ),
    .ci_outputs_0   (32'd0         ),
`endif

    // ---- 只读输入：传感器子系统 ----
    .sht_data_valid (sensor_sht_valid),
    .sht_temp_c_x100(sensor_sht_temp),
    .sht_rh_x100    (sensor_sht_rh),
    .sht_temp_raw   (sensor_sht_temp_raw),
    .sht_rh_raw     (sensor_sht_rh_raw),
    .sht_crc_err    (sensor_sht_crc_err),
    .sht_bus_err    (sensor_sht_bus_err),
    .ir_frame_cnt   (sensor_ir_frame_cnt),
    .ir_frame_valid (sensor_ir_frame_valid),
    .ir_bus_err     (sensor_ir_bus_err),
    .ir_ta_raw      (sensor_ir_ta_raw),
    .ir_rd_data     (cfg_ir_rd_data),

    // ---- 只读输入：算法子系统（已同步到系统域）----
    .motion_frame_done (alg_motion_done_s),
    .motion_frame_tgl  (alg_frame_tgl_s),
    .motion_sum_area   (alg_sum_area_s),
    .motion_sum_x      (alg_sum_x_s),
    .motion_sum_y      (alg_sum_y_s),
    .motion_flag       (alg_motion_flag_s),
    .conf_vision       (alg_conf_v_s),
    .conf_temp         (alg_conf_t_s),
    .conf_env          (alg_conf_e_s),
    .score             (alg_score_s),
    .in_auth_window    (alg_in_auth_s),
    .alarm             (alg_alarm_s),

    // ---- 可写输出：配置 ----
    .diff_threshold (cfg_diff_thr),
    .diff_min_area  (cfg_min_area),
    .score_thresh   (cfg_score_thr),
    .auth_start_h   (cfg_auth_start),
    .auth_end_h     (cfg_auth_end),
    .hour           (cfg_hour),
    .vision_prob    (cfg_vision_prob),
    .vision_valid   (cfg_vision_valid),
    .body_max_c_x10 (cfg_body_max_t),
    .ir_valid       (cfg_ir_valid),
    .ambient_c_x10  (cfg_ambient_t),
    .env_valid      (cfg_env_valid),
    .diff_enable    (cfg_diff_enable),
    .bg_freeze      (cfg_bg_freeze),
    .bg_clear_tgl   (cfg_bg_clear_tgl),
    .alarm_mute     (cfg_alarm_mute),
    .ir_frame_addr  (cfg_ir_frame_addr),
    .rh_x100_fwd    (cfg_rh_x100),
    .osd_txt_we     (osd_txt_we),
    .osd_txt_addr   (osd_txt_addr),
    .osd_txt_data   (osd_txt_data),
    .osd_th_we      (osd_th_we),
    .osd_th_addr    (osd_th_addr),
    .osd_th_data    (osd_th_data),
    // ---- ★ task-16：帧缓冲写通路握手 → SoC 寄存器（只加一路观察者，不影响原功能）----
    //      fb_awvalid/fb_awready/fb_wvalid/fb_wready 都是现成的 wire
    //      （它们已同时接到 axi_interconnect 的 s0 口与 checker0）
    .fb_awvalid (fb_awvalid),
    .fb_awready (fb_awready),
    .fb_wvalid  (fb_wvalid),
    .fb_wready  (fb_wready),
    // ---- ★ task-22：最大写地址 → 0xA8/0xAC ----
    .fb_awaddr  (fb_awaddr),
    // ---- ★ task-23：测试图案控制与视频测量 ----
    .test_pattern_en   (tp_en),
    .test_pattern_mode (tp_mode),
    .vid_lines_per_frame (vid_lines_per_frame),
    .vid_pixels_per_line (vid_pixels_per_line),
    .dbg_fb_sb           (dbg_fb_sb),
    .dbg_fb_sb2          (dbg_fb_sb2),
    .dbg_live            (dbg_live),
    .vid_frame_cnt       (vid_frame_cnt),
    // ---- ★ task-19：摄像头上游探针读口（0x80..0xA4）----
    .cam_probe_raddr (cam_probe_raddr),
    .cam_probe_rdata (cam_probe_rdata),
    .ir_rd_addr_clk_unused ()
);

//--------------------------------------------------------------------
// 3. 传感器子系统（系统域）：I2C 主机 + 分时复用 Hub + SHT30 + MLX90640
//--------------------------------------------------------------------
mmt_sensor_subsystem #(
    .CLK_HZ          (100_000_000),
    .SCL_HZ          (100_000),
    .SHT30_PERIOD_MS (1000),
    .IR_PERIOD_MS    (500)
) u_sensors (
    .clk   (core_clk),
    .rst_n (w_arstn),

    .scl_i (i_sensor_scl), .scl_o (o_sensor_scl), .scl_oe(o_sensor_scl_oe),
    .sda_i (i_sensor_sda), .sda_o (o_sensor_sda), .sda_oe(o_sensor_sda_oe),

    .sht_data_valid (sensor_sht_valid),
    .sht_temp_c_x100(sensor_sht_temp),
    .sht_rh_x100    (sensor_sht_rh),
    .sht_temp_raw   (sensor_sht_temp_raw),
    .sht_rh_raw     (sensor_sht_rh_raw),
    .sht_crc_err    (sensor_sht_crc_err),
    .sht_bus_err    (sensor_sht_bus_err),

    .ir_frame_cnt   (sensor_ir_frame_cnt),
    .ir_frame_valid (sensor_ir_frame_valid),
    .ir_ta_raw      (sensor_ir_ta_raw),
    .ir_bus_err     (sensor_ir_bus_err),

    .ir_rd_addr     (cfg_ir_frame_addr),
    .ir_rd_data     (cfg_ir_rd_data),

    .i2c_busy       (sensor_i2c_busy),
    .i2c_owner      (sensor_i2c_owner)
);

//--------------------------------------------------------------------
// 4. 配置信号跨域：系统域 → 视频域（准静态，两级同步即可）
//--------------------------------------------------------------------
wire [7:0]  sy_diff_thr;
wire [15:0] sy_min_area;
wire [7:0]  sy_score_thr;
wire [4:0]  sy_auth_start, sy_auth_end, sy_hour;
wire [7:0]  sy_vision_prob;
wire        sy_vision_valid;
wire signed [15:0] sy_body_max_t;
wire        sy_ir_valid;
wire signed [15:0] sy_ambient_t;
wire        sy_env_valid;
wire [15:0] sy_rh_x100;
wire [2:0]  sy_ctrl;              // {保留, bg_freeze, diff_enable}

mmt_sync2 #(.WIDTH(8))  u_sy_dthr (.clk_b(hdmi_tx_slow_clk), .rst_n_b(w_arstn), .d_a(cfg_diff_thr),   .q_b(sy_diff_thr));
mmt_sync2 #(.WIDTH(16)) u_sy_marea(.clk_b(hdmi_tx_slow_clk), .rst_n_b(w_arstn), .d_a(cfg_min_area),   .q_b(sy_min_area));
mmt_sync2 #(.WIDTH(8))  u_sy_sthr (.clk_b(hdmi_tx_slow_clk), .rst_n_b(w_arstn), .d_a(cfg_score_thr),  .q_b(sy_score_thr));
mmt_sync2 #(.WIDTH(5))  u_sy_ast  (.clk_b(hdmi_tx_slow_clk), .rst_n_b(w_arstn), .d_a(cfg_auth_start), .q_b(sy_auth_start));
mmt_sync2 #(.WIDTH(5))  u_sy_aen  (.clk_b(hdmi_tx_slow_clk), .rst_n_b(w_arstn), .d_a(cfg_auth_end),   .q_b(sy_auth_end));
mmt_sync2 #(.WIDTH(5))  u_sy_hour (.clk_b(hdmi_tx_slow_clk), .rst_n_b(w_arstn), .d_a(cfg_hour),       .q_b(sy_hour));
mmt_sync2 #(.WIDTH(8))  u_sy_vprob(.clk_b(hdmi_tx_slow_clk), .rst_n_b(w_arstn), .d_a(cfg_vision_prob),.q_b(sy_vision_prob));
mmt_sync2 #(.WIDTH(1))  u_sy_vvald(.clk_b(hdmi_tx_slow_clk), .rst_n_b(w_arstn), .d_a(cfg_vision_valid),.q_b(sy_vision_valid));
mmt_sync2 #(.WIDTH(16)) u_sy_body (.clk_b(hdmi_tx_slow_clk), .rst_n_b(w_arstn), .d_a(cfg_body_max_t), .q_b(sy_body_max_t));
mmt_sync2 #(.WIDTH(1))  u_sy_irv  (.clk_b(hdmi_tx_slow_clk), .rst_n_b(w_arstn), .d_a(cfg_ir_valid),   .q_b(sy_ir_valid));
mmt_sync2 #(.WIDTH(16)) u_sy_amb  (.clk_b(hdmi_tx_slow_clk), .rst_n_b(w_arstn), .d_a(cfg_ambient_t),  .q_b(sy_ambient_t));
mmt_sync2 #(.WIDTH(1))  u_sy_envv (.clk_b(hdmi_tx_slow_clk), .rst_n_b(w_arstn), .d_a(cfg_env_valid),  .q_b(sy_env_valid));
mmt_sync2 #(.WIDTH(16)) u_sy_rh   (.clk_b(hdmi_tx_slow_clk), .rst_n_b(w_arstn), .d_a(cfg_rh_x100),    .q_b(sy_rh_x100));
mmt_sync2 #(.WIDTH(3))  u_sy_ctrl (.clk_b(hdmi_tx_slow_clk), .rst_n_b(w_arstn),
                                    .d_a({cfg_bg_freeze, cfg_diff_enable, 1'b0}), .q_b(sy_ctrl));

wire sy_diff_enable = sy_ctrl[1];
wire sy_bg_freeze   = sy_ctrl[2];

// ---- bg_clear 的跨域处理（★ 硬化后的做法）----
// 原来是单周期脉冲（core 周期 10ns > video 周期 7.143ns），跨域可能整个丢掉。
// 改成：软核写寄存器 → 输出端翻转电平（单比特）→ 两级同步 → 视频域检测翻转沿 → 产生 1 拍脉冲。
// 单比特信号跨域 + 两级同步是可靠的；只有"两次请求间隔小于同步延迟"才会合并，
// 而 bg_clear 是人手动触发的，不存在这个问题。
wire sy_bg_clear_tgl;
reg  sy_bg_clear_d;
mmt_sync2 #(.WIDTH(1)) u_sy_bgclr (.clk_b(hdmi_tx_slow_clk), .rst_n_b(w_arstn),
                                    .d_a(cfg_bg_clear_tgl), .q_b(sy_bg_clear_tgl));
always @(posedge hdmi_tx_slow_clk or negedge w_arstn) begin
    if (!w_arstn) sy_bg_clear_d <= 1'b0;
    else          sy_bg_clear_d <= sy_bg_clear_tgl;
end
wire sy_bg_clear = sy_bg_clear_tgl ^ sy_bg_clear_d;   // 翻转沿 → 1 拍脉冲

//--------------------------------------------------------------------
// 5. 算法子系统（视频域）：帧差法 + 60/25/15 融合决策
//--------------------------------------------------------------------
mmt_algo_subsystem #(
    .IMG_W (160),
    .IMG_H (120),
    .XW    (8),
    .YW    (8)
) u_algo (
    .clk   (hdmi_tx_slow_clk),
    .rst_n (w_arstn),

    .pix_data (gray_pix),
    .pix_de   (gray_de),
    .pix_vs   (gray_vs),

    .diff_threshold (sy_diff_thr),
    .diff_min_area  (sy_min_area),
    .diff_enable    (sy_diff_enable),
    .bg_freeze      (sy_bg_freeze),
    .bg_clear       (sy_bg_clear),

    .motion_frame_done (alg_motion_done),
    .motion_sum_area   (alg_sum_area),
    .motion_sum_x      (alg_sum_x),
    .motion_sum_y      (alg_sum_y),
    .motion_flag       (alg_motion_flag),

    .vision_prob     (sy_vision_prob),
    .vision_valid    (sy_vision_valid),
    .body_max_c_x10  (sy_body_max_t),
    .ir_valid        (sy_ir_valid),
    .ambient_c_x10   (sy_ambient_t),
    .rh_x100         (sy_rh_x100),
    .env_valid       (sy_env_valid),
    .hour            (sy_hour),

    .score_thresh (sy_score_thr),
    .auth_start_h (sy_auth_start),
    .auth_end_h   (sy_auth_end),

    .conf_vision    (alg_conf_v),
    .conf_temp      (alg_conf_t),
    .conf_env       (alg_conf_e),
    .score          (alg_score),
    .in_auth_window (alg_in_auth),
    .alarm          (alg_alarm)
);

//--------------------------------------------------------------------
// 6. 状态信号跨域：视频域 → 系统域（轮询用，两级同步）
//--------------------------------------------------------------------
wire [31:0] alg_sum_area_s, alg_sum_x_s, alg_sum_y_s;
wire [7:0]  alg_conf_v_s, alg_conf_t_s, alg_conf_e_s;
wire [8:0]  alg_score_s;
wire [3:0]  alg_flags_s;          // {alarm, in_auth, motion_done, motion_flag}

mmt_sync2 #(.WIDTH(32)) u_sy_area (.clk_b(core_clk), .rst_n_b(w_arstn), .d_a(alg_sum_area), .q_b(alg_sum_area_s));
mmt_sync2 #(.WIDTH(32)) u_sy_sumx (.clk_b(core_clk), .rst_n_b(w_arstn), .d_a(alg_sum_x),    .q_b(alg_sum_x_s));
mmt_sync2 #(.WIDTH(32)) u_sy_sumy (.clk_b(core_clk), .rst_n_b(w_arstn), .d_a(alg_sum_y),    .q_b(alg_sum_y_s));
mmt_sync2 #(.WIDTH(8))  u_sy_cv   (.clk_b(core_clk), .rst_n_b(w_arstn), .d_a(alg_conf_v),   .q_b(alg_conf_v_s));
mmt_sync2 #(.WIDTH(8))  u_sy_ct   (.clk_b(core_clk), .rst_n_b(w_arstn), .d_a(alg_conf_t),   .q_b(alg_conf_t_s));
mmt_sync2 #(.WIDTH(8))  u_sy_ce   (.clk_b(core_clk), .rst_n_b(w_arstn), .d_a(alg_conf_e),   .q_b(alg_conf_e_s));
mmt_sync2 #(.WIDTH(9))  u_sy_sc   (.clk_b(core_clk), .rst_n_b(w_arstn), .d_a(alg_score),    .q_b(alg_score_s));
mmt_sync2 #(.WIDTH(4))  u_sy_fl   (.clk_b(core_clk), .rst_n_b(w_arstn),
                                    .d_a({alg_alarm, alg_in_auth, alg_motion_done, alg_motion_flag}), .q_b(alg_flags_s));

wire alg_motion_flag_s = alg_flags_s[0];
wire alg_motion_done_s = alg_flags_s[1];
wire alg_in_auth_s     = alg_flags_s[2];
wire alg_alarm_s       = alg_flags_s[3];

// ---- 帧翻转标志（★ CDC 硬化的关键一环）----
// 多比特状态量（sum_area / score 等）跨域按位同步时，理论上可能刚好在两拍之间被采样，
// 读到一个"从未存在过"的中间值。解法：视频域每完成一帧翻转一个单比特标志，
// 该标志单独同步到系统域；软核**只有在标志发生变化时才去读数据**，
// 而那时数据早已稳定（数据是帧结束才更新的），从而彻底避开竞争窗口。
reg  alg_frame_tgl;
wire alg_frame_tgl_s;
always @(posedge hdmi_tx_slow_clk or negedge w_arstn) begin
    if (!w_arstn) alg_frame_tgl <= 1'b0;
    else if (alg_motion_done) alg_frame_tgl <= ~alg_frame_tgl;
end
mmt_sync2 #(.WIDTH(1)) u_sy_ftgl (.clk_b(core_clk), .rst_n_b(w_arstn),
                                  .d_a(alg_frame_tgl), .q_b(alg_frame_tgl_s));

//--------------------------------------------------------------------
// 7. 报警输出（系统域）：LED 闪烁 + 蜂鸣器
//--------------------------------------------------------------------
wire [3:0] alarm_led;

mmt_alarm_ctrl #(
    .CLK_HZ   (100_000_000),
    .HF_BLINK_HZ (2),
    .BUZZ_HZ     (2_000)
) u_alarm (
    .clk       (core_clk),
    .rst_n     (w_arstn),
    .alarm     (alg_alarm_s),
    .event_type(3'd1),               // 1 = 入侵（本方案选的场景）
    .confidence({1'b0, alg_score_s[8:2]}),   // 9 位得分压成 8 位给 OSD 用
    .mute      (cfg_alarm_mute),
    .led       (alarm_led),
    .buzzer    (o_buzzer),
    .evt_type_out(),
    .conf_out  (),
    .alarm_active()
);

// LED 合并：报警时板载 LED 齐闪；平时保留原来的心跳灯
//   ★ 2026-10-11：板子只有 2 个真正引到 LED 的 3.3V 脚（GPIOR_27/GPIOR_24，
//     见 mmt.peri.xml），所以顶层 led 收成 [1:0]，只取报警模块输出的低两位。
//   ★ 2026-10-13 上板实测：原用 cnt[24]（core_clk 100MHz/2^24 ≈ 3Hz）偏快、
//     且与报警的 2Hz 不易区分；改用 cnt[25]（≈1.5Hz）作为"心跳"更直观：
//       正常 = 只有一个灯 ~1.5Hz 闪；报警 = 两个灯同相 2Hz 闪。
assign led = (alg_alarm_s) ? alarm_led[1:0]
                           : {1'b0, (cal_done ? cnt[25] : 1'b0)};



endmodule
