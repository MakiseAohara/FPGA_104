
/////////////////////////////////////////////////////////////////////////////
//
// Copyright (C) 2013-2021 Efinix Inc. All rights reserved.
//
// Description:
// Example top file for ti60f225 dev kit OOB design
//
// Language:  Verilog 2001
//Ti60f225_sc431hai2hdmi_v6�?//使用了最新版本的framebuffer_v3;
// ------------------------------------------------------------------------------

/////////////////////////////////////////////////////////////////////////////////
//`define SOFT_TAP 1
`include "ddr3_controller/ddr3_parameter.vh"
// `include "define.v"

module ti60f225_oob_top #(

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

  (* syn_peri_port = 0 *) input jtag_inst1_CAPTURE,
  (* syn_peri_port = 0 *) input jtag_inst1_DRCK,
  (* syn_peri_port = 0 *) input jtag_inst1_RESET,
  (* syn_peri_port = 0 *) input jtag_inst1_RUNTEST,
  (* syn_peri_port = 0 *) input jtag_inst1_SEL,
  (* syn_peri_port = 0 *) input jtag_inst1_SHIFT,
  (* syn_peri_port = 0 *) input jtag_inst1_TCK,
  (* syn_peri_port = 0 *) input jtag_inst1_TDI,
  (* syn_peri_port = 0 *) input jtag_inst1_TMS,
  (* syn_peri_port = 0 *) input jtag_inst1_UPDATE,
  (* syn_peri_port = 0 *) output jtag_inst1_TDO,

    // P2b: SoC UART�����Ÿ�������֤�� AI ���̷��䣩
    input  wire uart_rxd,
    output wire uart_txd,

   //Clocks 
	input	wire	i_arstn,
    input	wire	i_mipi_rx_pclk,
    input wire  vid_clk_dvi2,
    input wire hdmi_tx_slow_clk,
    input wire CLK_5M,
    input  wire CLK_25M,
	output  wire    pll_inst1_RSTN,
	input	wire	i_pll_locked,
	input 	wire  	pll_locked,
	output  wire    pll_inst4_RSTN,
	input   wire    pll_inst4_LOCKED,
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
       input  wire io_sns_sda_IN,
       output wire io_sns_sda_OUT,
       output wire io_sns_sda_OE,
       input  wire io_sns_scl_IN,
       output wire io_sns_scl_OUT,
       output wire io_sns_scl_OE,
       output wire sns_buzzer,
       input  wire key_night_n,
       input  wire key_learn_n,
       output [7:0] led,

       // MIPI DSI
       input	wire	                     i_mipi_tx_pclk		,
       output	wire	                     mipi_dp_clk_LP_P_OUT		,
       output	wire	                     mipi_dp_clk_LP_N_OUT		,
       output	wire	[7:0] 	              mipi_dp_clk_HS_OUT		,
       output	wire	                     mipi_dp_clk_HS_OE		,
       output	wire	                     mipi_dp_data3_LP_P_OUT	,
       output	wire	                     mipi_dp_data2_LP_P_OUT	,
       output	wire	                     mipi_dp_data1_LP_P_OUT	,
       output	wire	                     mipi_dp_data0_LP_P_OUT	,
       output	wire	                     mipi_dp_data3_LP_N_OUT	,
       output	wire	                     mipi_dp_data2_LP_N_OUT	,
       output	wire	                     mipi_dp_data1_LP_N_OUT	,
       output	wire	                     mipi_dp_data0_LP_N_OUT	,
       output	wire	[7:0] 	              mipi_dp_data0_HS_OUT	       ,
       output	wire	[7:0] 	              mipi_dp_data1_HS_OUT	       ,
       output	wire	[7:0] 	              mipi_dp_data2_HS_OUT	       ,
       output	wire	[7:0] 	              mipi_dp_data3_HS_OUT	       ,
       output	wire	                     mipi_dp_data3_HS_OE		,
       output	wire	                     mipi_dp_data2_HS_OE		,
       output	wire	                     mipi_dp_data1_HS_OE		,
       output	wire	                     mipi_dp_data0_HS_OE		,

       output	wire	                     mipi_dp_clk_RST		,
       output	wire	                     mipi_dp_data0_RST		,
       output	wire	                     mipi_dp_data1_RST		,
       output	wire	                     mipi_dp_data2_RST		,
       output	wire	                     mipi_dp_data3_RST		,
       output	wire	                     mipi_dp_clk_LP_P_OE		,
       output	wire	                     mipi_dp_clk_LP_N_OE		,
       output	wire	                     mipi_dp_data3_LP_P_OE	,
       output	wire	                     mipi_dp_data3_LP_N_OE	,
       output	wire	                     mipi_dp_data2_LP_P_OE	,
       output	wire	                     mipi_dp_data2_LP_N_OE	,
       output	wire	                     mipi_dp_data1_LP_P_OE	,
       output	wire	                     mipi_dp_data1_LP_N_OE	,
       output	wire	                     mipi_dp_data0_LP_P_OE	,
       output	wire	                     mipi_dp_data0_LP_N_OE	,

       input  wire	                     mipi_dp_data0_LP_P_IN	,
       input  wire	                     mipi_dp_data0_LP_N_IN	,
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
    output tmds_tx_data2_TX_RST


);

function integer log2;
	input	integer	val;
	integer	i;
	begin
		log2 = 0;
		for (i=0; 2**i<val; i=i+1)
			log2 = i+1;
	end
endfunction


//===============================================================================
//localparam
//===============================================================================
localparam WR_FIFO_DEPTH  = 1024;
localparam RD_FIFO_DEPTH  = 1024;

// localparam	MAX_HRES		= 12'd1920;
// localparam	MAX_VRES		= 12'd1080;
// localparam	HSP			= 8'd2;
// localparam	HBP			= 8'd88;
// localparam	HFP			= 8'd120;
// localparam	VSP			= 8'd2;
// localparam	VBP			= 8'd20;
// localparam	VFP			= 8'd20;

localparam HACT     = 1920;
localparam HFP      = 88;
localparam HSP      = 44;
localparam HBP      = 148;

localparam VACT     = 1080;
localparam VFP      = 4;
localparam VSP      = 5;
localparam VBP      = 36;
//===============================================================================
//signal
//===============================================================================
   
wire                              app_sr_active;
wire                              app_ref_ack;
wire                              app_zq_ack;
wire                              cal_done;

// Slave Interface Write Address Ports
wire [AXI_ID_WIDTH-1:0]           s_axi_awid;

// ===================== P2a: SoC + 3-lane bridge =========================
// frame_buffer �� AXI ���ڣ�ԭ s_axi_*�����Ѹ�����
wire [AXI_ID_WIDTH-1:0]      fb_axi_awid;
wire [AXI_ADDR_WIDTH-1:0]    fb_axi_awaddr;
wire [7:0]                   fb_axi_awlen;
wire [2:0]                   fb_axi_awsize;
wire [1:0]                   fb_axi_awburst;
wire [2:0]                   fb_axi_awprot;
wire [3:0]                   fb_axi_awcache;
wire [1:0]                   fb_axi_awlock;
wire                         fb_axi_awvalid;
wire                         fb_axi_awready;
wire [AXI_ID_WIDTH-1:0]      fb_axi_arid;
wire [AXI_ADDR_WIDTH-1:0]    fb_axi_araddr;
wire [7:0]                   fb_axi_arlen;
wire [2:0]                   fb_axi_arsize;
wire [1:0]                   fb_axi_arburst;
wire [2:0]                   fb_axi_arprot;
wire [3:0]                   fb_axi_arcache;
wire [1:0]                   fb_axi_arlock;
wire                         fb_axi_arvalid;
wire                         fb_axi_arready;
wire [AXI_DATA_WIDTH-1:0]    fb_axi_wdata;
wire [(AXI_DATA_WIDTH/8)-1:0] fb_axi_wstrb;
wire                         fb_axi_wlast;
wire                         fb_axi_wvalid;
wire                         fb_axi_wready;
wire [AXI_ID_WIDTH-1:0]      fb_axi_rid;
wire [AXI_DATA_WIDTH-1:0]    fb_axi_rdata;
wire                         fb_axi_rlast;
wire                         fb_axi_rvalid;
wire                         fb_axi_rready;
wire [1:0]                   fb_axi_rresp;
wire [AXI_ID_WIDTH-1:0]      fb_axi_bid;
wire                         fb_axi_bvalid;
wire                         fb_axi_bready;

// ---- SapphireSoC���ϲ��� arw ͨ�� �� ����� aw/ar ----
wire [31:0] soc_arw_addr;
wire [7:0]  soc_arw_len;
wire [2:0]  soc_arw_size;
wire [1:0]  soc_arw_burst;
wire [1:0]  soc_arw_lock;
wire [3:0]  soc_arw_cache;
wire [2:0]  soc_arw_prot;
wire [7:0]  soc_arw_id;
wire        soc_arw_valid, soc_arw_ready, soc_arw_write;
wire [7:0]  soc_awid;  wire [31:0] soc_awaddr; wire [7:0] soc_awlen;
wire [2:0]  soc_awsize; wire [1:0] soc_awburst; wire [2:0] soc_awprot;
wire [3:0]  soc_awcache; wire [1:0] soc_awlock;
wire        soc_awvalid, soc_awready;
wire [7:0]  soc_arid;  wire [31:0] soc_araddr; wire [7:0] soc_arlen;
wire [2:0]  soc_arsize; wire [1:0] soc_arburst; wire [2:0] soc_arprot;
wire [3:0]  soc_arcache; wire [1:0] soc_arlock;
wire        soc_arvalid, soc_arready;
wire [127:0] soc_wdata; wire [15:0] soc_wstrb; wire soc_wlast;
wire        soc_wvalid, soc_wready;
wire [7:0]  soc_bid; wire [1:0] soc_bresp; wire soc_bvalid, soc_bready;
wire [7:0]  soc_rid; wire [127:0] soc_rdata; wire [1:0] soc_rresp;
wire        soc_rlast, soc_rvalid, soc_rready;
wire        soc_system_reset, soc_memory_reset;
wire [31:0] soc_apb_paddr; wire soc_apb_psel, soc_apb_penable, soc_apb_pwrite;
wire [31:0] soc_apb_pwdata;
reg  [31:0] soc_apb_prdata;
wire        soc_cmd_valid, soc_cmd_ready, soc_rsp_valid, soc_rsp_ready;
wire [9:0]  soc_cmd_function;
wire [31:0] soc_cmd_a, soc_cmd_b, soc_rsp_data;
// lane2��TinyML������δ�ã����ղ�����
wire        s_ign_awready, s_ign_wready, s_ign_bvalid, s_ign_arready;
wire        s_ign_rvalid, s_ign_rlast;
wire [7:0]  s_ign_bid, s_ign_rid;
wire [1:0]  s_ign_bresp, s_ign_rresp;
wire [127:0] s_ign_rdata;
// ========================================================================
wire [AXI_ADDR_WIDTH-1:0]         s_axi_awaddr;
wire [7:0]                        s_axi_awlen;
wire [2:0]                        s_axi_awsize;
wire [1:0]                        s_axi_awburst;
wire [0:0]                        s_axi_awlock;
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
wire [0:0]                        s_axi_arlock;
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




////////////////////////////////////////////////////////////////
// System & Debugger
wire    w_arstn;
// wire	w_sysclk_mcu_arstn;
// wire	w_sysclk_mcu_arst;
wire	w_mipi_rx_pclk_arstn;
wire	w_mipi_rx_pclk_arst;

wire		       w_mipi_rx_vs;
wire		       w_mipi_rx_hs;
wire	       w_mipi_rx_de;
wire	[63:0]			w_mipi_rx_data	;

wire					io_systemReset;



//===================================================================================================
//reset module
//===================================================================================================

assign w_arstn  		       = i_pll_locked & pll_locked & user_pll_locked;
assign pll_inst1_RSTN  		= i_arstn;
assign USER_PLL_RSTN      		= i_arstn;
assign mipi_dsi_tx_pll_RSTN 	= i_arstn;
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



reg [25:0] cnt = 'd0;
always @( posedge core_clk)
begin 
       cnt <= cnt + 1'b1;
end
assign led[0]  = cal_done ? cnt[24] : 1'b0;

//========================================================================================================
//MIPI RX
//========================================================================================================
wire i_mipi_clk ;
assign i_mipi_clk = core_clk;

		assign	cam_d0_RST		= 1'b0;
		assign	cam_d1_RST		= 1'b0;
		assign  cam_d2_RST = 1'b0;
    assign  cam_d3_RST = 1'b0;
	
wire [15:0] mipi_debug_out;
		

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
              .fifo_rd_empty		({cam_d3_FIFO_EMPTY,cam_d2_FIFO_EMPTY,cam_d1_FIFO_EMPTY,cam_d0_FIFO_EMPTY}),
              .DLY_enable_D		       (),
              .DLY_inc_D			(),
              .u_dly_enable_D		(),
              .u_dly_inc_D		       (),
              
              .axi_clk			(1'b0),
              .axi_reset_n		       (1'b0),
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
              .vc				(),
              .word_count			(),
              .shortpkt_data_field        (),
              .datatype			(),
              .pixel_per_clk		(),
              .pixel_data			(w_mipi_rx_data),
              .pixel_data_valid	       (w_mipi_rx_de),
              .irq				(),
              .mipi_debug_out(mipi_debug_out)
		);

//     wire		       w1_mipi_rx_vs;
// wire		       w1_mipi_rx_hs;
// wire	       w1_mipi_rx_de;
// wire	[39:0]			w1_mipi_rx_data	;
// sensor_clipper  sensor_clipper_inst (
//     .clk(i_mipi_rx_pclk),
//     .i_vs(w_mipi_rx_vs),
//     .i_hs(w_mipi_rx_hs),
//     .i_de(w_mipi_rx_de),
//     .i_dat(w_mipi_rx_data[39:0]),

//     .o_hs(w1_mipi_rx_hs),
//     .o_vs(w1_mipi_rx_vs),
//     .o_de(w1_mipi_rx_de),
//     .o_dat(w1_mipi_rx_data)
   
//   );


wire mdebug_pixel_fifo_full     = mipi_debug_out[0] ;
wire mdebug_pixel_fifo_empty    = mipi_debug_out[1] ;
wire mdebug_crc_error           = mipi_debug_out[2] ;
wire mdebug_ecc_1bit_error      = mipi_debug_out[3] ;
wire mdebug_ecc_2bit_error      = mipi_debug_out[4] ;
wire mdebug_undersize_pkt_error = mipi_debug_out[5] ;
wire mdebug_line_vc0_error      = mipi_debug_out[6] ;
wire mdebug_frame_vc0_error    = mipi_debug_out[10];   
wire mdebug_receive_error      = mipi_debug_out[14];


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
  /*o*/.sda_padoen_o  (sda_padoen_o),

  // MERGE10: APB -> camera SCCB command channel (core_clk quasi-static data + toggle sync)
  /*i*/.apb_req_toggle(i2c_req_toggle),
  /*i*/.apb_rw        (i2c_rw_cmd),
  /*i*/.apb_dev       (7'd0),               // 0 => default device address 0x60
  /*i*/.apb_addr      (i2c_addr_cmd),
  /*i*/.apb_wdata     (i2c_wdata_cmd),
  /*o*/.busy          (i2c_busy_5m),
  /*o*/.done_toggle   (i2c_done_toggle_5m),
  /*o*/.rdata         (i2c_rdata_5m),
  /*o*/.ready         (i2c_ready_5m)
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

wire  [16-1:0] m_axis_tdata;
wire           m_axis_tvalid;
wire           m_axis_tready;
wire           m_axis_tlast;
wire           m_axis_tuser;
wire  fifo_rd_period;
// IMX219
  frame_buffer #(
.I_VID_WIDTH         (32),
.O_VID_WIDTH         (16),
.START_ADDR          (32'h1000000      ),
.AXI_DATA_WIDTH      ( AXI_DATA_WIDTH	),
.AXI_ADDR_WIDTH      ( AXI_ADDR_WIDTH	),
.WR_FIFO_DEPTH	      ( 1024		),    
.RD_FIFO_DEPTH 	      ( 1024 	),
.BURST_LEN  	        (127),
.FB_NUM	              (3),
.MAX_VID_WIDTH	      (960) ,
.MAX_VID_HIGHT	      (1080),
.O_FRAME_WIDTH      (960),
.O_FRAME_HEIGHT     (1080)

)checker0(
       .axi_clk		(core_clk 	        ),
       .rst_n			(vid_rst_n   ),

/*i*/.i_clk			(i_mipi_rx_pclk      ),
/*i*/.i_vs			(w_mipi_rx_vs	),
/*i*/.i_de			(w_mipi_rx_de & w_mipi_rx_hs	),
/*i*/.vin 			({w_mipi_rx_data[39:32],w_mipi_rx_data[29:22],w_mipi_rx_data[19:12],w_mipi_rx_data[9:2]}	),
                     
/*i*/.o_clk			(vid_clk_dvi2),//(i_mipi_rx_pclk	),                  
/*i*/.fifo_rd_period(fifo_rd_period),//(fifo_rd_period  ),

    .m_axis_tdata  (m_axis_tdata),
    .m_axis_tvalid (m_axis_tvalid),
    .m_axis_tready (m_axis_tready),
    .m_axis_tuser  (m_axis_tuser),
    .m_axis_tlast  (m_axis_tlast),
	

       .awid			(fb_axi_awid	),      
       .awaddr		(fb_axi_awaddr	),
       .awlen			(fb_axi_awlen	),
       .awsize		(fb_axi_awsize	),
       .awburst		(fb_axi_awburst),
       .awprot    (fb_axi_awprot ),
       .awcache   (fb_axi_awcache),
       .awlock		(fb_axi_awlock	),
       .awvalid		(fb_axi_awvalid),
       .awready		(fb_axi_awready),

       .arid			(fb_axi_arid	  ),
       .araddr		(fb_axi_araddr	),
       .arlen			(fb_axi_arlen	),
       .arsize		(fb_axi_arsize	),
       .arburst 	(fb_axi_arburst),

       .arprot    (fb_axi_arprot ),
       .arcache   (fb_axi_arcache),
       .arlock 		(fb_axi_arlock	),
       .arvalid		(fb_axi_arvalid),
       .arready		(fb_axi_arready),

       .wdata			(fb_axi_wdata	),
       .wstrb			(fb_axi_wstrb	),
       .wlast			(fb_axi_wlast	),
       .wvalid		(fb_axi_wvalid	),
       .wready		(fb_axi_wready	),


       .rid			  (fb_axi_rid	),
       .rdata			(fb_axi_rdata	),
       .rlast			(fb_axi_rlast	),
       .rvalid 		(fb_axi_rvalid	),
       .rready		(fb_axi_rready	),
       .rresp			(fb_axi_rresp	),

       .bid			  (fb_axi_bid	),
       .bvalid		(fb_axi_bvalid	),
       .bready	  (fb_axi_bready	)
);

		    
		    
cvo_axi # (
    .SYMBOL_WIDTH(8),
    .SYMBOL_NUM(1),
    .PIXEL_NUM(2),
    .HSYNC_POL(1),
    .VSYNC_POL(1),
    .FIFO_DEPTH(1024),
    .FIFO_ALMOST_FULL(1000),
    .MAX_H_VALID(1920),
    .MAX_V_VALID(1080)
  )
  cvo_axi_inst (
    .o_clk          (vid_clk_dvi2   ),
    .rst_n          (vid_rst_n      ),
    .fifo_rd_period (fifo_rd_period ),
    .s_axi_clk      (vid_clk_dvi2   ),
    .s_axis_tdata   (m_axis_tdata   ),
    .s_axis_tvalid  (m_axis_tvalid  ),
    .s_axis_tready  (m_axis_tready  ),
    .s_axis_tlast   (m_axis_tlast   ),
    .s_axis_tuser   (m_axis_tuser   ),
    .H_FRONT_PORCH  (HFP            ),
    .H_SYNC         (HSP            ),
    .H_VALID        (HACT           ),
    .H_BACK_PORCH   (HBP            ),
    .V_FRONT_PORCH  (VFP            ),
    .V_SYNC         (VSP            ),
    .V_VALID        (VACT           ),
    .V_BACK_PORCH   (VBP            ),
     .vout          ({ch0_b,ch0_g}  ),
    .o_hs           (ch0_hs         ),
    .o_vs           (ch0_vs         ),
    .o_de           (ch0_de         )
  );		       




// ---- VERI-1180���˿����Ӵ�����д������ͳһ�� tie �� ----
wire         tie0     = 1'b0;
wire         tie1     = 1'b1;
wire [1:0]   tie0_2   = 2'd0;
wire [2:0]   tie0_3   = 3'd0;
wire [3:0]   tie0_4   = 4'd0;
wire [7:0]   tie0_8   = 8'd0;
wire [9:0]   tie0_10  = 10'd0;
wire [15:0]  tie0_16  = 16'd0;
wire [31:0]  tie0_32  = 32'd0;
wire [127:0] tie0_128 = 128'd0;
// lane0 �� ID ֻ�� 4 λ���ŵ����඼�� 8 λ���ñ�����������չ/�ض�
wire [7:0] fb_bid_w, fb_rid_w;
assign fb_axi_bid = fb_bid_w[AXI_ID_WIDTH-1:0];
assign fb_axi_rid = fb_rid_w[AXI_ID_WIDTH-1:0];


// ===================== P2b: TinyML ���������� lane2��=====================
wire [7:0]   t_awid;   wire [31:0] t_awaddr; wire [7:0] t_awlen;
wire [2:0]   t_awsize; wire [1:0]  t_awburst; wire [0:0] t_awlock;
wire [3:0]   t_awcache; wire [2:0] t_awprot;
wire [127:0] t_wdata;  wire [15:0] t_wstrb;  wire [0:0] t_wlast;
wire [7:0]   t_arid;   wire [31:0] t_araddr; wire [7:0] t_arlen;
wire [2:0]   t_arsize; wire [1:0]  t_arburst; wire [0:0] t_arlock;
wire [3:0]   t_arcache; wire [2:0] t_arprot;
wire [0:0]   t_awvalid, t_wvalid, t_bready, t_arvalid, t_rready;
wire [0:0]   t_awready, t_wready, t_arready, t_bvalid, t_rvalid, t_rlast;
wire [7:0]   t_bid, t_rid;
wire [1:0]   t_bresp, t_rresp;
wire [127:0] t_rdata;
wire         soc_cmd_valid, soc_cmd_ready, soc_rsp_valid, soc_rsp_ready, soc_cmd_int;
wire [9:0]   soc_cmd_function;
wire [31:0]  soc_cmd_a, soc_cmd_b, soc_rsp_data;
// ===================== P2a: SapphireSoC + 3-lane bridge ==================
assign soc_arw_ready = soc_arw_write ? soc_awready : soc_arready;
assign soc_awvalid   = soc_arw_valid &&  soc_arw_write;
assign soc_arvalid   = soc_arw_valid && !soc_arw_write;
assign soc_awaddr    = soc_arw_addr;
assign soc_araddr    = soc_arw_addr;
assign soc_awlen     = soc_arw_len;    assign soc_arlen  = soc_arw_len;
assign soc_awsize    = soc_arw_size;   assign soc_arsize = soc_arw_size;
assign soc_awburst   = soc_arw_burst;  assign soc_arburst= soc_arw_burst;
assign soc_awlock    = soc_arw_lock;   assign soc_arlock = soc_arw_lock;
assign soc_awcache   = soc_arw_cache;  assign soc_arcache= soc_arw_cache;
assign soc_awprot    = soc_arw_prot;   assign soc_arprot = soc_arw_prot;
assign soc_awid      = soc_arw_id;     assign soc_arid   = soc_arw_id;


// ---- SoC APB ״̬�Ĵ�����loader �����ж� DDR ������----
wire [2:0] bridge_state;
reg  [31:0] soc_aw_cnt, soc_ar_cnt;
reg  [31:0] t_aw_cnt, t_ar_cnt, ci_cnt, irq_cnt;
reg  irq_prev;
always @(posedge core_clk or negedge w_arstn) begin
  if(!w_arstn) begin
    soc_aw_cnt <= 32'd0; soc_ar_cnt <= 32'd0;
    t_aw_cnt <= 32'd0; t_ar_cnt <= 32'd0;
    ci_cnt <= 32'd0; irq_cnt <= 32'd0; irq_prev <= 1'b0;
  end else begin
    if(soc_awvalid && soc_awready) soc_aw_cnt <= soc_aw_cnt + 32'd1;
    if(soc_arvalid && soc_arready) soc_ar_cnt <= soc_ar_cnt + 32'd1;
    if(t_awvalid && t_awready)     t_aw_cnt   <= t_aw_cnt + 32'd1;
    if(t_arvalid && t_arready)     t_ar_cnt   <= t_ar_cnt + 32'd1;
    if(soc_cmd_valid && soc_cmd_ready) ci_cnt  <= ci_cnt + 32'd1;
    if(soc_cmd_int && !irq_prev)       irq_cnt <= irq_cnt + 32'd1;
    irq_prev <= soc_cmd_int;
  end
end
// ---- OSD alarm: APB write (core_clk) -> video clock domain ----
reg osd_alarm_core;
always @(posedge core_clk or negedge w_arstn) begin
  if(!w_arstn) osd_alarm_core <= 1'b0;
  else if(soc_apb_psel && soc_apb_penable && soc_apb_pwrite &&
          soc_apb_paddr[6:2]==4'd9)
    osd_alarm_core <= soc_apb_pwdata[0];
end
reg osd_alarm_v1, osd_alarm_v2;
always @(posedge hdmi_tx_slow_clk or negedge vid_rst_n) begin
  if(!vid_rst_n) begin osd_alarm_v1 <= 1'b0; osd_alarm_v2 <= 1'b0; end
  else begin osd_alarm_v1 <= osd_alarm_core; osd_alarm_v2 <= osd_alarm_v1; end
end
// ---- AI raw score: APB reg10 (firmware writes {bit8=1, bits[7:0]=int8 person score}) -> video domain ----
reg [8:0] ai_score_core;
always @(posedge core_clk or negedge w_arstn) begin
  if(!w_arstn) ai_score_core <= 9'd0;
  else if(soc_apb_psel && soc_apb_penable && soc_apb_pwrite &&
          soc_apb_paddr[6:2]==4'd10)
    ai_score_core <= soc_apb_pwdata[8:0];
end
reg [8:0] ai_score_v1, ai_score_v2;
always @(posedge hdmi_tx_slow_clk or negedge vid_rst_n) begin
  if(!vid_rst_n) begin ai_score_v1 <= 9'd0; ai_score_v2 <= 9'd0; end
  else begin ai_score_v1 <= ai_score_core; ai_score_v2 <= ai_score_v1; end
end
// ========================================================================
// MERGE10: APB -> camera SCCB (16-bit register address, 8-bit data)
//   word16 (0x40) write I2C_CMD   : [31]=start [30]=rw [23:8]=reg addr [7:0]=wdata
//   word17 (0x44) read  I2C_STATUS: bit0=busy bit1=done(clear on read) bit2=ready
//   word18 (0x48) read  I2C_RDATA : [7:0]=last read data
// APB domain core_clk, I2C domain CLK_5M: command via toggle+2FF, status via 2FF.
// ========================================================================
wire        i2c_busy_5m, i2c_done_toggle_5m, i2c_ready_5m;
wire [7:0]  i2c_rdata_5m;

reg         i2c_req_toggle;
reg         i2c_rw_cmd;
reg  [15:0] i2c_addr_cmd;
reg  [7:0]  i2c_wdata_cmd;

wire i2c_cmd_wr    = soc_apb_psel && soc_apb_penable && soc_apb_pwrite &&
                     (soc_apb_paddr[6:2] == 5'd16);
wire i2c_status_rd = soc_apb_psel && soc_apb_penable && !soc_apb_pwrite &&
                     (soc_apb_paddr[6:2] == 5'd17);

// ---- CLK_5M -> core_clk : busy / done_toggle / rdata / ready ----
reg [1:0] i2c_busy_sync;
reg [1:0] i2c_ready_sync;
reg [1:0] i2c_done_sync;
reg [7:0] i2c_rdata_s1, i2c_rdata_s2;
always @(posedge core_clk or negedge w_arstn) begin
  if(!w_arstn) begin
    i2c_busy_sync  <= 2'd0;
    i2c_ready_sync <= 2'd0;
    i2c_done_sync  <= 2'd0;
    i2c_rdata_s1   <= 8'd0;
    i2c_rdata_s2   <= 8'd0;
  end else begin
    i2c_busy_sync  <= {i2c_busy_sync[0],  i2c_busy_5m};
    i2c_ready_sync <= {i2c_ready_sync[0], i2c_ready_5m};
    i2c_done_sync  <= {i2c_done_sync[0],  i2c_done_toggle_5m};
    i2c_rdata_s1   <= i2c_rdata_5m;
    i2c_rdata_s2   <= i2c_rdata_s1;
  end
end
wire i2c_busy_core  = i2c_busy_sync[1];
wire i2c_ready_core = i2c_ready_sync[1];
wire i2c_done_edge  = i2c_done_sync[1] ^ i2c_done_sync[0];
wire [7:0] i2c_rdata_core = i2c_rdata_s2;

// done sticky bit (cleared by reading 0x44)
reg i2c_done_sticky;
always @(posedge core_clk or negedge w_arstn) begin
  if(!w_arstn) i2c_done_sticky <= 1'b0;
  else if(i2c_done_edge) i2c_done_sticky <= 1'b1;
  else if(i2c_status_rd) i2c_done_sticky <= 1'b0;
end

// ---- command issue (core_clk): ignore when busy=1 or ready=0 ----
always @(posedge core_clk or negedge w_arstn) begin
  if(!w_arstn) begin
    i2c_req_toggle <= 1'b0;
    i2c_rw_cmd     <= 1'b0;
    i2c_addr_cmd   <= 16'd0;
    i2c_wdata_cmd  <= 8'd0;
  end else if(i2c_cmd_wr && soc_apb_pwdata[31] &&
              !i2c_busy_core && i2c_ready_core) begin
    i2c_rw_cmd     <= soc_apb_pwdata[30];
    i2c_addr_cmd   <= soc_apb_pwdata[23:8];
    i2c_wdata_cmd  <= soc_apb_pwdata[7:0];
    i2c_req_toggle <= ~i2c_req_toggle;
  end
end

// MERGE16: 白平衡/统计寄存器声明（core 域）
reg  [15:0] wb_r_core, wb_g_core, wb_b_core;
reg  [31:0] wb_r_c, wb_g_c, wb_b_c, wb_pix_c, wb_sat_c;
reg  [2:0]  wb_tgl_s;
wire [31:0] wb_sum_r, wb_sum_g, wb_sum_b, wb_pix, wb_sat;
wire        wb_tgl;
// MERGE16: 白平衡增益寄存器（字 19/20/21，默认 WBH7：R=0x158 G=0x118 B=0x170）
always @(posedge core_clk or negedge w_arstn) begin
  if (!w_arstn) begin
    wb_r_core <= 16'h158;
    wb_g_core <= 16'h118;
    wb_b_core <= 16'h1C8;   // MERGE17: B 增益复位默认 0x1C8（原 0x170）
  end else if (soc_apb_psel && soc_apb_penable && soc_apb_pwrite) begin
    case (soc_apb_paddr[6:2])
      5'd19: wb_r_core <= soc_apb_pwdata[15:0];
      5'd20: wb_g_core <= soc_apb_pwdata[15:0];
      5'd21: wb_b_core <= soc_apb_pwdata[15:0];
      default: ;
    endcase
  end
end

always @* begin
  case(soc_apb_paddr[6:2])
    5'd0: soc_apb_prdata = {31'd0, cal_done};
    5'd1: soc_apb_prdata = soc_aw_cnt;
    5'd2: soc_apb_prdata = soc_ar_cnt;
    5'd3: soc_apb_prdata = {29'd0, bridge_state};
    5'd4: soc_apb_prdata = t_aw_cnt;
    5'd5: soc_apb_prdata = t_ar_cnt;
    5'd6: soc_apb_prdata = ci_cnt;
    5'd7: soc_apb_prdata = irq_cnt;
    5'd8: soc_apb_prdata = {31'd0, soc_system_reset};
    5'd9: soc_apb_prdata = {31'd0, osd_alarm_core};
    5'd10: soc_apb_prdata = {23'd0, ai_score_core};
    5'd11: soc_apb_prdata = apb_ext_prdata;   // MERGE11: word11 motion/IR evidence
    5'd12: soc_apb_prdata = apb_ext_prdata;   // MERGE11: word12 environment
    5'd13: soc_apb_prdata = apb_ext_prdata;   // MERGE11: word13 fusion/low-power/alarm status
    5'd16: soc_apb_prdata = 32'd0;   // MERGE10: I2C_CMD (write-only)
    5'd17: soc_apb_prdata = {29'd0, i2c_ready_core, i2c_done_sticky, i2c_busy_core}; // I2C_STATUS
    5'd18: soc_apb_prdata = {24'd0, i2c_rdata_core};                                   // I2C_RDATA
    // MERGE16: WB 增益回读 + 通道统计
    5'd19: soc_apb_prdata = {16'd0, wb_r_core};
    5'd20: soc_apb_prdata = {16'd0, wb_g_core};
    5'd21: soc_apb_prdata = {16'd0, wb_b_core};
    5'd22: soc_apb_prdata = wb_r_c;
    5'd23: soc_apb_prdata = wb_g_c;
    5'd24: soc_apb_prdata = wb_b_c;
    5'd25: soc_apb_prdata = wb_pix_c;
    5'd26: soc_apb_prdata = wb_sat_c;
    default: soc_apb_prdata = 32'd0;
  endcase
end


tinyml_accelerator_channels #(.AXI_DW_M(128)) u_tinyml_accel(
 .clk(core_clk), .reset(soc_system_reset),
 .m_axi_clk(core_clk), .m_axi_rstn(!soc_system_reset),
 .cmd_valid(soc_cmd_valid), .cmd_ready(soc_cmd_ready),
 .cmd_function_id(soc_cmd_function),
 .cmd_inputs_0(soc_cmd_a), .cmd_inputs_1(soc_cmd_b),
 .cmd_int(soc_cmd_int),
 .rsp_valid(soc_rsp_valid), .rsp_ready(soc_rsp_ready),
 .rsp_outputs_0(soc_rsp_data),
 .m_axi_awid(t_awid), .m_axi_awaddr(t_awaddr), .m_axi_awlen(t_awlen),
 .m_axi_awsize(t_awsize), .m_axi_awburst(t_awburst), .m_axi_awlock(t_awlock),
 .m_axi_awcache(t_awcache), .m_axi_awprot(t_awprot),
 .m_axi_wdata(t_wdata), .m_axi_wstrb(t_wstrb), .m_axi_wlast(t_wlast),
 .m_axi_arid(t_arid), .m_axi_araddr(t_araddr), .m_axi_arlen(t_arlen),
 .m_axi_arsize(t_arsize), .m_axi_arburst(t_arburst), .m_axi_arlock(t_arlock),
 .m_axi_arcache(t_arcache), .m_axi_arprot(t_arprot),
 .m_axi_awvalid(t_awvalid), .m_axi_wvalid(t_wvalid), .m_axi_bready(t_bready),
 .m_axi_arvalid(t_arvalid), .m_axi_rready(t_rready),
 .m_axi_awready(t_awready), .m_axi_wready(t_wready),
 .m_axi_bresp(t_bresp), .m_axi_bvalid(t_bvalid),
 .m_axi_arready(t_arready),
 .m_axi_rdata(t_rdata), .m_axi_rresp(t_rresp),
 .m_axi_rlast(t_rlast), .m_axi_rvalid(t_rvalid)
);

SapphireSoc u_soc(
 .io_systemClk(core_clk),
 .io_peripheralClk(core_clk),
 .io_memoryClk(core_clk),
 .io_asyncReset(!w_arstn),
 .io_systemReset(soc_system_reset),
 .io_memoryReset(soc_memory_reset),
 .io_peripheralReset(),
 .io_ddrA_arw_payload_addr(soc_arw_addr),
 .io_ddrA_arw_payload_len(soc_arw_len),
 .io_ddrA_arw_payload_size(soc_arw_size),
 .io_ddrA_arw_payload_burst(soc_arw_burst),
 .io_ddrA_arw_payload_lock(soc_arw_lock),
 .io_ddrA_arw_payload_cache(soc_arw_cache),
 .io_ddrA_arw_payload_prot(soc_arw_prot),
 .io_ddrA_arw_payload_id(soc_arw_id),
 .io_ddrA_arw_payload_write(soc_arw_write),
 .io_ddrA_arw_payload_qos(),
 .io_ddrA_arw_payload_region(),
 .io_ddrA_arw_valid(soc_arw_valid),
 .io_ddrA_arw_ready(soc_arw_ready),
 .io_ddrA_w_payload_data(soc_wdata),
 .io_ddrA_w_payload_strb(soc_wstrb),
 .io_ddrA_w_payload_last(soc_wlast),
 .io_ddrA_w_payload_id(),
 .io_ddrA_w_valid(soc_wvalid),
 .io_ddrA_w_ready(soc_wready),
 .io_ddrA_b_payload_resp(soc_bresp),
 .io_ddrA_b_payload_id(soc_bid),
 .io_ddrA_b_valid(soc_bvalid),
 .io_ddrA_b_ready(soc_bready),
 .io_ddrA_r_payload_data(soc_rdata),
 .io_ddrA_r_payload_resp(soc_rresp),
 .io_ddrA_r_payload_id(soc_rid),
 .io_ddrA_r_payload_last(soc_rlast),
 .io_ddrA_r_valid(soc_rvalid),
 .io_ddrA_r_ready(soc_rready),
 // UART��P2a �Ȳ�������peri.xml ������
 .system_uart_0_io_txd(uart_txd),
 .system_uart_0_io_rxd(uart_rxd),
 // δ�����裬ȫ�������н�
 .system_spi_0_io_data_0_read(tie1), .system_spi_0_io_data_0_write(),
 .system_spi_0_io_data_0_writeEnable(),
 .system_spi_0_io_data_1_read(tie1), .system_spi_0_io_data_1_write(),
 .system_spi_0_io_data_1_writeEnable(),
 .system_spi_0_io_data_2_read(tie1), .system_spi_0_io_data_2_write(),
 .system_spi_0_io_data_2_writeEnable(),
 .system_spi_0_io_data_3_read(tie1), .system_spi_0_io_data_3_write(),
 .system_spi_0_io_data_3_writeEnable(),
 .system_spi_0_io_sclk_write(), .system_spi_0_io_ss(),
 .system_i2c_0_io_scl_read(tie1), .system_i2c_0_io_scl_write(),
 .system_i2c_0_io_sda_read(tie1), .system_i2c_0_io_sda_write(),
 .jtagCtrl_enable(tie0), .jtagCtrl_tdi(tie0), .jtagCtrl_capture(tie0),
 .jtagCtrl_shift(tie0), .jtagCtrl_update(tie0), .jtagCtrl_reset(tie1),
 .jtagCtrl_tdo(), .jtagCtrl_tck(core_clk),
 .io_apbSlave_1_PADDR(), .io_apbSlave_1_PENABLE(), .io_apbSlave_1_PSEL(),
 .io_apbSlave_1_PWDATA(), .io_apbSlave_1_PWRITE(),
 .io_apbSlave_1_PRDATA(tie0_32), .io_apbSlave_1_PREADY(tie1),
 .io_apbSlave_1_PSLVERROR(tie1),
 .io_apbSlave_0_PADDR(soc_apb_paddr), .io_apbSlave_0_PENABLE(soc_apb_penable),
 .io_apbSlave_0_PSEL(soc_apb_psel), .io_apbSlave_0_PWRITE(soc_apb_pwrite),
 .io_apbSlave_0_PWDATA(soc_apb_pwdata), .io_apbSlave_0_PRDATA(soc_apb_prdata),
 .io_apbSlave_0_PREADY(tie1), .io_apbSlave_0_PSLVERROR(tie0),
 // �Զ���ָ��ڣ�P2a ��û�� TinyML��ȫ������
 .cpu0_customInstruction_cmd_valid(soc_cmd_valid),
 .cpu0_customInstruction_cmd_ready(soc_cmd_ready),
 .cpu0_customInstruction_function_id(soc_cmd_function),
 .cpu0_customInstruction_inputs_0(soc_cmd_a),
 .cpu0_customInstruction_inputs_1(soc_cmd_b),
 .cpu0_customInstruction_rsp_valid(soc_rsp_valid),
 .cpu0_customInstruction_rsp_ready(soc_rsp_ready),
 .cpu0_customInstruction_outputs_0(soc_rsp_data),
 .userInterruptA(soc_cmd_int),
 .userInterruptB(tie0)
);

// lane0=frame_buffer, lane1=SoC, lane2=TinyML(���ֶ� 0)
mmt_ai_mem_bridge3 u_mem_bridge(
 .clk(core_clk), .rst_n(w_arstn), .debug_state(bridge_state),
 .s_awid  ({t_awid, soc_awid,   {tie0_4, fb_axi_awid}  }),
 .s_awaddr({t_awaddr, soc_awaddr, fb_axi_awaddr}),
 .s_awlen ({t_awlen, soc_awlen,  fb_axi_awlen}),
 .s_awsize({t_awsize, soc_awsize, fb_axi_awsize}),
 .s_awburst({t_awburst, soc_awburst, fb_axi_awburst}),
 .s_awlock({t_awlock, soc_awlock, fb_axi_awlock}),
 .s_awcache({t_awcache, soc_awcache, fb_axi_awcache}),
 .s_awprot({t_awprot, soc_awprot, fb_axi_awprot}),
 .s_wdata ({t_wdata, soc_wdata, fb_axi_wdata}),
 .s_wstrb ({t_wstrb, soc_wstrb, fb_axi_wstrb}),
 .s_wlast ({t_wlast, soc_wlast, fb_axi_wlast}),
 .s_arid  ({t_arid, soc_arid,   {tie0_4, fb_axi_arid}  }),
 .s_araddr({t_araddr, soc_araddr, fb_axi_araddr}),
 .s_arlen ({t_arlen, soc_arlen,  fb_axi_arlen}),
 .s_arsize({t_arsize, soc_arsize, fb_axi_arsize}),
 .s_arburst({t_arburst, soc_arburst, fb_axi_arburst}),
 .s_arlock({t_arlock, soc_arlock, fb_axi_arlock}),
 .s_arcache({t_arcache, soc_arcache, fb_axi_arcache}),
 .s_arprot({t_arprot, soc_arprot, fb_axi_arprot}),
 .s_awvalid({t_awvalid, soc_awvalid, fb_axi_awvalid}),
 .s_wvalid ({t_wvalid, soc_wvalid,  fb_axi_wvalid}),
 .s_bready ({t_bready, soc_bready,  fb_axi_bready}),
 .s_arvalid({t_arvalid, soc_arvalid, fb_axi_arvalid}),
 .s_rready ({t_rready, soc_rready,  fb_axi_rready}),
 .s_awready({t_awready, soc_awready, fb_axi_awready}),
 .s_wready ({t_wready,  soc_wready,  fb_axi_wready}),
 .s_bid    ({t_bid, soc_bid, fb_bid_w}),
 .s_bresp  ({t_bresp, soc_bresp, fb_axi_bresp}),
 .s_bvalid ({t_bvalid, soc_bvalid, fb_axi_bvalid}),
 .s_arready({t_arready, soc_arready, fb_axi_arready}),
 .s_rid    ({t_rid, soc_rid, fb_rid_w}),
 .s_rdata  ({t_rdata, soc_rdata, fb_axi_rdata}),
 .s_rresp  ({t_rresp, soc_rresp, fb_axi_rresp}),
 .s_rlast  ({t_rlast, soc_rlast, fb_axi_rlast}),
 .s_rvalid ({t_rvalid, soc_rvalid, fb_axi_rvalid}),
 // ---- ���� �� ddr3_top ----
 .m_awid(s_axi_awid), .m_awaddr(s_axi_awaddr), .m_awlen(s_axi_awlen),
 .m_awsize(s_axi_awsize), .m_awburst(s_axi_awburst), .m_awlock(s_axi_awlock),
 .m_awcache(s_axi_awcache), .m_awprot(s_axi_awprot),
 .m_wdata(s_axi_wdata), .m_wstrb(s_axi_wstrb), .m_wlast(s_axi_wlast),
 .m_arid(s_axi_arid), .m_araddr(s_axi_araddr), .m_arlen(s_axi_arlen),
 .m_arsize(s_axi_arsize), .m_arburst(s_axi_arburst), .m_arlock(s_axi_arlock),
 .m_arcache(s_axi_arcache), .m_arprot(s_axi_arprot),
 .m_awvalid(s_axi_awvalid), .m_wvalid(s_axi_wvalid), .m_bready(s_axi_bready),
 .m_arvalid(s_axi_arvalid), .m_rready(s_axi_rready),
 .m_awready(s_axi_awready), .m_wready(s_axi_wready),
 .m_bid(s_axi_bid), .m_bresp(s_axi_bresp), .m_bvalid(s_axi_bvalid),
 .m_arready(s_axi_arready),
 .m_rid(s_axi_rid), .m_rdata(s_axi_rdata), .m_rresp(s_axi_rresp),
 .m_rlast(s_axi_rlast), .m_rvalid(s_axi_rvalid)
);
// ========================================================================

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
.s_axi_awlock                   (s_axi_awlock      ),
.s_axi_awcache                  (s_axi_awcache     ),
.s_axi_awprot                   (s_axi_awprot      ),
.s_axi_awqos                    (4'h0              ),
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
.s_axi_arlock                   (s_axi_arlock      ),
.s_axi_arcache                  (s_axi_arcache     ),
.s_axi_arprot                   (s_axi_arprot      ),
.s_axi_arqos                    (4'h0              ),
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
wire [15:0] r_gain;
wire [15:0] g_gain;
wire [15:0] b_gain;
// MERGE16: VIO 不再驱动白平衡（保留探针但不使用）
wire [15:0] vio_r_gain_unused;
wire [15:0] vio_g_gain_unused;
wire [15:0] vio_b_gain_unused;
wire [7:0]  hot_cnt_v;
wire signed [15:0] body_x10_v;

// ========================================================================
// MERGE16: 白平衡增益（APB 字 19/20/21）与通道统计（字 22..26）
//   - 增益：core 域寄存器 -> 2FF 同步到 vid_clk_dvi2 域 -> 每帧(rgb_vs)锁存
//   - 统计：debayer 内 v7_wb_stat（vid_clk_dvi2 域）-> toggle 握手到 core 域
// ========================================================================
reg [15:0] wb_r_s1, wb_r_s2, wb_g_s1, wb_g_s2, wb_b_s1, wb_b_s2;
reg [15:0] wb_r_v, wb_g_v, wb_b_v;
reg        rgb_vs_d_dvi;
wire       rgb_vs_rise_dvi = rgb_vs & ~rgb_vs_d_dvi;
always @(posedge vid_clk_dvi2 or negedge vid_rst_n) begin
	if (!vid_rst_n) begin
		wb_r_s1 <= 16'h158; wb_r_s2 <= 16'h158;
		wb_g_s1 <= 16'h118; wb_g_s2 <= 16'h118;
		wb_b_s1 <= 16'h170; wb_b_s2 <= 16'h170;
		wb_r_v  <= 16'h158; wb_g_v  <= 16'h118; wb_b_v  <= 16'h170;
		rgb_vs_d_dvi <= 1'b0;
	end else begin
		wb_r_s1 <= wb_r_core; wb_r_s2 <= wb_r_s1;
		wb_g_s1 <= wb_g_core; wb_g_s2 <= wb_g_s1;
		wb_b_s1 <= wb_b_core; wb_b_s2 <= wb_b_s1;
		rgb_vs_d_dvi <= rgb_vs;
		if (rgb_vs_rise_dvi) begin
			wb_r_v <= wb_r_s2; wb_g_v <= wb_g_s2; wb_b_v <= wb_b_s2;
		end
	end
end

always @(posedge core_clk or negedge w_arstn) begin
	if (!w_arstn) begin
		wb_tgl_s <= 3'd0;
		wb_r_c <= 32'd0; wb_g_c <= 32'd0; wb_b_c <= 32'd0;
		wb_pix_c <= 32'd0; wb_sat_c <= 32'd0;
	end else begin
		wb_tgl_s <= {wb_tgl_s[1:0], wb_tgl};
		if (wb_tgl_s[1] ^ wb_tgl_s[2]) begin
			wb_r_c <= wb_sum_r; wb_g_c <= wb_sum_g; wb_b_c <= wb_sum_b;
			wb_pix_c <= wb_pix; wb_sat_c <= wb_sat;
		end
	end
end

debayer_top_2to1 debayer_top
(
	.in_pclk		  (vid_clk_dvi2),//(i_mipi_rx_pclk ),
	.in_rstn		  (vid_rst_n	),
	
	.raw_vs_i		  (ch0_vs		      ),
	.raw_hs_i		  (ch0_hs		      ),
	.raw_de_i		  (ch0_de		      ),
	.raw_valid_i	(ch0_de	        ),
	.raw_datax4_i	({ch0_b,ch0_g}	),
	.r_gain       (wb_r_v         ),
	.g_gain       (wb_g_v         ),
	.b_gain       (wb_b_v         ),
	.rgb_vs_o		  (rgb_vs         ),
	.rgb_hs_o		  (rgb_hs         ),
	.rgb_de_o		  (rgb_de         ),
	.rgb_valid_o	(rgb_valid      ),
	.rgb_datax2_o (rgb_datax2     ),//b,g,r,b,g,r
	.wb_sum_r(wb_sum_r), .wb_sum_g(wb_sum_g), .wb_sum_b(wb_sum_b),
	.wb_pix(wb_pix), .wb_sat(wb_sat), .wb_tgl(wb_tgl)
);
reg rgb_vs_r = 'd0;
always @( posedge hdmi_tx_slow_clk )
begin
  rgb_vs_r <= rgb_vs;
end
assign pos_vs = {rgb_vs_r,rgb_vs} == 2'b01;
reg vid_cnt = 'd0;
reg [7:0] hdmi_tx_rdata ;
reg [7:0] hdmi_tx_gdata ;
reg [7:0] hdmi_tx_bdata ;
reg hdmi_tx_vs;
reg hdmi_tx_hs;
reg hdmi_tx_de;
always @( posedge hdmi_tx_slow_clk )
begin
    if( pos_vs )
      vid_cnt <= 1'b1;
    else if( rgb_de )
      vid_cnt <= ~vid_cnt ;

    if( vid_cnt )
      {hdmi_tx_bdata,hdmi_tx_gdata,hdmi_tx_rdata} <= rgb_datax2[23:0];
    else 
      {hdmi_tx_bdata,hdmi_tx_gdata,hdmi_tx_rdata} <= rgb_datax2[47:24];

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
assign w_confdone = 1'b1;

assign  LCD_POWER 			= i_arstn;
assign	LCD_RST_P	      = ~w_arstn;//~r_rst_cnt[23]; LCD复位先释放，然后再释放MIPI 的复�?assign	mipi_dp_clk_RST		= ~i_arstn;
assign	mipi_dp_data0_RST	= ~i_arstn;
assign	mipi_dp_data1_RST	= ~i_arstn;
assign	mipi_dp_data2_RST	= ~i_arstn;
assign	mipi_dp_data3_RST	= ~i_arstn;
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

always @( posedge vid_clk_dvi2 or negedge w_arstn )
begin
  if( !w_arstn )
    dly_cnt <= 'd0;
  else if( w_confdone )
    dly_cnt <= dly_cnt[26] ? dly_cnt :(dly_cnt + 1'b1);
  else 
    dly_cnt <= 'd0;
end 

assign vid_rst_n = dly_cnt[26];




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
  // /*o*/.rgb_r	(rgb_r),    //像素数据、红色分�?  // /*o*/.rgb_g	(rgb_g),    //像素数据、绿色分�?  // /*o*/.rgb_b (rgb_b)    //像素数据、蓝色分�?  
  // );

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
wire [7:0] gamma_rdata ;
wire [7:0] gamma_gdata ;
wire [7:0] gamma_bdata ;
wire gamma_valid;
wire gamma_hs;
wire gamma_vs;
wire gamma_sel;

wire [7:0] con_rdata ;
wire [7:0] con_gdata ;
wire [7:0] con_bdata ;
wire con_de;
wire con_hs;
wire con_vs;
wire con_sel;

wire [7:0] BRIGHT_SIG    ;
wire CONTRAST_SIG_G;
wire CONTRAST_SIG_R;
wire [7:0] CONTRAST_G    ;
wire CONTRAST_SIG_B;
wire [7:0] BRIGHT        ;
wire [7:0] CONTRAST_R    ;


wire CONTRAST_B    ;


gamma_correction
#(
	.DATA_WIDTH		(8),
	.GAMMA_CURVE	("./rtl/gamma_conrrection/2P2.mem")
)
inst_gamma_correction
(
	.i_pclk		(hdmi_tx_slow_clk),
	.i_rstn		(vid_rst_n),
	
	.i_red		(hdmi_tx_rdata),//(con_rdata  ),//
	.i_green	(hdmi_tx_gdata),//(con_gdata  ),//
	.i_blue		(hdmi_tx_bdata),//(con_bdata  ),//
  .i_valid	(hdmi_tx_de   ),//(con_de     ),//
  .i_hs     (hdmi_tx_hs   ),//(con_hs     ),//
  .i_vs     (hdmi_tx_vs   ),//(con_vs     ),//
	.o_blue		(gamma_bdata		),
  .o_green	(gamma_gdata	  ),
	.o_red		(gamma_rdata		),
	.o_valid	(gamma_valid	  ),
  .o_hs     (gamma_hs       ),
  .o_vs     (gamma_vs       )
);


// ---- merged: pixels before OSD (same gamma select and R/B crossing as the original mmt_osd_demo input) ----
wire [7:0] enc_r_in = gamma_sel ? gamma_rdata : hdmi_tx_bdata;
wire [7:0] enc_g_in = gamma_sel ? gamma_gdata : hdmi_tx_gdata;
wire [7:0] enc_b_in = gamma_sel ? gamma_bdata : hdmi_tx_rdata;
wire       enc_de_in = gamma_sel ? gamma_valid : hdmi_tx_de;
wire       enc_hs_in = gamma_sel ? gamma_hs    : hdmi_tx_hs;
wire       enc_vs_in = gamma_sel ? gamma_vs    : hdmi_tx_vs;
wire [7:0] osd_r,osd_g,osd_b;
wire osd_de,osd_hs,osd_vs;
wire        mmt_alarm_active;
wire [1:0]  mmt_led;
wire        mmt_txt_we; wire [7:0] mmt_txt_wa, mmt_txt_wd;
wire        mmt_th_we;  wire [9:0] mmt_th_wa;  wire [7:0] mmt_th_wd;
// ai_person = person decision bit written by firmware (TinyML), APB reg9 bit0, 2-FF synced into hdmi_tx_slow_clk
// ========================================================================
// MERGE11: APB words 11..15 -- RISC-V decision (item 2) + low-power status (item 5)
//   word11/12/13 read-only evidence; word14/15 write firmware decision/control
//   CDC: evidence video->core (per-frame toggle handshake), controls core->video (2 FF)
// ========================================================================
reg vs_d_v;
always @(posedge hdmi_tx_slow_clk or negedge vid_rst_n) begin
  if(!vid_rst_n) vs_d_v <= 1'b0;
  else           vs_d_v <= enc_vs_in;
end
wire vs_rise_v = enc_vs_in & ~vs_d_v;

wire [31:0] obs_evt_v, obs_env_v, obs_st_v;
wire        apb_ext_hit;
wire [31:0] apb_ext_prdata;
wire        fw_decision_enable_v, fw_alarm_req_v;
wire [7:0]  fw_evt_v;
v7_apb_ext u_apb_ext (
  .core_clk(core_clk), .core_rst_n(w_arstn),
  .paddr(soc_apb_paddr), .pwdata(soc_apb_pwdata),
  .psel(soc_apb_psel), .penable(soc_apb_penable), .pwrite(soc_apb_pwrite),
  .prdata(apb_ext_prdata), .hit(apb_ext_hit),
  .vid_clk(hdmi_tx_slow_clk), .vid_rst_n(vid_rst_n),
  .vs_rise(vs_rise_v),
  .evt_v(obs_evt_v), .env_v(obs_env_v), .st_v(obs_st_v),
  .fw_decision_enable_v(fw_decision_enable_v), .fw_alarm_req_v(fw_alarm_req_v),
  .fw_evt_v(fw_evt_v),
  .fw_decision_enable(), .fw_alarm_req()
);

v7_mmt_core #(.AI_MODE(1)) u_v7_mmt (
	.clk(hdmi_tx_slow_clk), .rst_n(vid_rst_n),
	.in_r(enc_r_in), .in_g(enc_g_in), .in_b(enc_b_in),
	.in_de(enc_de_in), .in_hs(enc_hs_in), .in_vs(enc_vs_in),
	.ai_person(osd_alarm_v2), .ai_score(ai_score_v2[7:0]), .ai_alive(ai_score_v2[8]), .key_night_n(key_night_n), .key_learn_n(key_learn_n),
	.fw_evt(fw_evt_v),
	.fw_decision_enable(fw_decision_enable_v), .fw_alarm_req(fw_alarm_req_v),
	.scl_i(io_sns_scl_IN), .sda_i(io_sns_sda_IN),
	.scl_o(io_sns_scl_OUT), .scl_oe(io_sns_scl_OE), .sda_o(io_sns_sda_OUT), .sda_oe(io_sns_sda_OE),
	.buzzer(sns_buzzer), .led(mmt_led), .alarm_active(mmt_alarm_active),
	.obs_evt(obs_evt_v), .obs_env(obs_env_v), .obs_st(obs_st_v),
	.txt_we(mmt_txt_we), .txt_wa(mmt_txt_wa), .txt_wd(mmt_txt_wd),
	.th_we(mmt_th_we), .th_wa(mmt_th_wa), .th_wd(mmt_th_wd),
	.hot_cnt_o(hot_cnt_v), .body_x10_o(body_x10_v)
);
assign led[1] = mmt_led[1];
v7_osd_top u_v7_osd (
	.vclk   (hdmi_tx_slow_clk),
	.vrst_n (vid_rst_n),
	.i_r (enc_r_in), .i_g (enc_g_in), .i_b (enc_b_in),
	.i_de(enc_de_in), .i_hs(enc_hs_in), .i_vs(enc_vs_in),
	.o_r (osd_r), .o_g (osd_g), .o_b (osd_b),
	.o_de(osd_de), .o_hs(osd_hs), .o_vs(osd_vs),
	.alarm_in(mmt_alarm_active),
	.txt_we(mmt_txt_we), .txt_wa(mmt_txt_wa), .txt_wd(mmt_txt_wd),
	.th_we(mmt_th_we), .th_wa(mmt_th_wa), .th_wd(mmt_th_wd),
	.hot_cnt(hot_cnt_v), .body_x10(body_x10_v)
);

dvi_encoder dvi_encoder_m0
(
	.pixelclk      		(hdmi_tx_slow_clk          ),// system clock
	.rst_p         		(~vid_rst_n      ),// reset
	.i_bdata      		(osd_b),//(hdmi_tx_rdata ),//(video_b            ),//(bdata_in	),   //
	.i_gdata     		  (osd_g),//(hdmi_tx_gdata ),//(video_g            ),//(gdata_in	),   //   
	.i_rdata       		(osd_r),//(hdmi_tx_bdata ),//(video_r            ),//(rdata_in	),   //   
  .i_de            	(osd_de),//(hdmi_tx_de    ),//(video_de           ),//(rx_de		  ),   //
	.i_hs         		(osd_hs),//(video_hs           ),//(rx_hsync	),   //   
	.i_vs         		(osd_vs),//(video_vs           ),//(rx_vsync	),   //  
	
  .video_format     (video_format), //// 00 = RGB, 01 = YCbCr 4:2:2, 10 = YCbCr 4:4:4
  .video_VIC        (0),
	.audio_L			    (audio_L),
  .audio_R			    (audio_R),
  .audio_valid		  (audio_valid),
  .audio_N                (6144),     //(20'h01880),//     
  .audio_CTS              (148500),      //(20'h28488),//      
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

debug_edb_top debug_edb_top_inst (
    .bscan_CAPTURE      ( jtag_inst1_CAPTURE  ),
    .bscan_DRCK         ( jtag_inst1_DRCK     ),
    .bscan_RESET        ( jtag_inst1_RESET    ),
    .bscan_RUNTEST      ( jtag_inst1_RUNTEST  ),
    .bscan_SEL          ( jtag_inst1_SEL      ),
    .bscan_SHIFT        ( jtag_inst1_SHIFT    ),
    .bscan_TCK          ( jtag_inst1_TCK      ),
    .bscan_TDI          ( jtag_inst1_TDI      ),
    .bscan_TMS          ( jtag_inst1_TMS      ),
    .bscan_UPDATE       ( jtag_inst1_UPDATE   ),
    .bscan_TDO          ( jtag_inst1_TDO      ),
    .vio0_clk           ( vid_clk_dvi2        ),
    .vio0_r_gain        ( vio_r_gain_unused   ),
    .vio0_g_gain        ( vio_g_gain_unused   ),
    .vio0_b_gain        ( vio_b_gain_unused   ),

    .vio0_gamma_sel     (gamma_sel),
    .la0_clk            ( vid_clk_dvi2        ),
    .la0_ch0_g          ( ch0_g               ),
    .la0_ch0_b          ( ch0_b               ),
    .la0_ch0_de         ( ch0_de              ),
    .la0_cal_done       ( cal_done            )
);

endmodule


