`timescale 1ns/1ps
// ============================================================================
//  mmt_ai_mem_bridge3 —— 3 主口 → 1 主口 AXI 仲裁桥
//
//  由已验证的 2 主口版 mmt_ai_mem_bridge.v 扩展而来（bridge-test-06 全绿）：
//    · 端口全部按 "每主口一个 lane" 摊平：ID 8bit / ADDR 32bit / DATA 128bit
//    · 仲裁：round-robin，指针在授权后前移一格（保证公平，不会单口饿死）
//    · 读写通道各自独立走状态机，各自只有一个未完成事务（与 2 主口版一致）
//    · 背压下地址/数据保持稳定（TB 里有断言）
//
//  lane 0 = 建议接 frame_buffer（视频写/读，ID 取低 4 位）
//  lane 1 = 建议接 SapphireSoC
//  lane 2 = 建议接 TinyML 加速器
// ============================================================================
module mmt_ai_mem_bridge3(
input wire clk,rst_n,
output wire [2:0] debug_state,

// ---------------- slave side: 3 lanes ----------------
input wire [23:0] s_awid,
input wire [95:0] s_awaddr,
input wire [23:0] s_awlen,
input wire [8:0]  s_awsize,
input wire [5:0]  s_awburst,
input wire [2:0]  s_awlock,
input wire [11:0] s_awcache,
input wire [8:0]  s_awprot,
input wire [383:0] s_wdata,
input wire [47:0] s_wstrb,
input wire [2:0]  s_wlast,
input wire [23:0] s_arid,
input wire [95:0] s_araddr,
input wire [23:0] s_arlen,
input wire [8:0]  s_arsize,
input wire [5:0]  s_arburst,
input wire [2:0]  s_arlock,
input wire [11:0] s_arcache,
input wire [8:0]  s_arprot,
input wire [2:0]  s_awvalid,
input wire [2:0]  s_wvalid,
input wire [2:0]  s_bready,
input wire [2:0]  s_arvalid,
input wire [2:0]  s_rready,

output reg [2:0]  s_awready,
output reg [2:0]  s_wready,
output reg [23:0] s_bid,
output reg [5:0]  s_bresp,
output reg [2:0]  s_bvalid,
output reg [2:0]  s_arready,
output reg [23:0] s_rid,
output reg [383:0] s_rdata,
output reg [5:0]  s_rresp,
output reg [2:0]  s_rlast,
output reg [2:0]  s_rvalid,

// ---------------- master side: 1 lane ----------------
output reg [7:0]   m_awid,
output reg [31:0]  m_awaddr,
output reg [7:0]   m_awlen,
output reg [2:0]   m_awsize,
output reg [1:0]   m_awburst,
output reg [0:0]   m_awlock,
output reg [3:0]   m_awcache,
output reg [2:0]   m_awprot,
output reg [127:0] m_wdata,
output reg [15:0]  m_wstrb,
output reg [0:0]   m_wlast,
output reg [7:0]   m_arid,
output reg [31:0]  m_araddr,
output reg [7:0]   m_arlen,
output reg [2:0]   m_arsize,
output reg [1:0]   m_arburst,
output reg [0:0]   m_arlock,
output reg [3:0]   m_arcache,
output reg [2:0]   m_arprot,
output reg [0:0]   m_awvalid,
output reg [0:0]   m_wvalid,
output reg [0:0]   m_bready,
output reg [0:0]   m_arvalid,
output reg [0:0]   m_rready,
input wire [0:0]   m_awready,
input wire [0:0]   m_wready,
input wire [7:0]   m_bid,
input wire [1:0]   m_bresp,
input wire [0:0]   m_bvalid,
input wire [0:0]   m_arready,
input wire [7:0]   m_rid,
input wire [127:0] m_rdata,
input wire [1:0]   m_rresp,
input wire [0:0]   m_rlast,
input wire [0:0]   m_rvalid
);

localparam IDLE=0, WRITE_ADDR=1, WRITE_DATA=2, WRITE_RESP=3;
localparam READ_IDLE=0, READ_ADDR=1, READ_DATA=2;

reg [1:0] wstate,rstate;
reg [1:0] wowner,rowner;
reg [1:0] wrr,rrr;              // round-robin 指针
reg [7:0] write_id,read_id;

// ---- round-robin：从当前指针起找第一个 requester ----
wire [1:0] w_n1 = (wrr==2'd2) ? 2'd0 : wrr + 2'd1;
wire [1:0] w_n2 = (w_n1==2'd2) ? 2'd0 : w_n1 + 2'd1;
wire [1:0] r_n1 = (rrr==2'd2) ? 2'd0 : rrr + 2'd1;
wire [1:0] r_n2 = (r_n1==2'd2) ? 2'd0 : r_n1 + 2'd1;

wire [1:0] wgrant = s_awvalid[wrr] ? wrr : (s_awvalid[w_n1] ? w_n1 : w_n2);
wire [1:0] rgrant = s_arvalid[rrr] ? rrr : (s_arvalid[r_n1] ? r_n1 : r_n2);

assign debug_state = {rstate != READ_IDLE, wstate};

always @* begin
  s_awready='0; s_wready='0; s_bid='0; s_bresp='0; s_bvalid='0;
  s_arready='0; s_rid='0; s_rdata='0; s_rresp='0; s_rlast='0; s_rvalid='0;
  m_awid='0; m_awaddr='0; m_awlen='0; m_awsize='0; m_awburst='0;
  m_awlock='0; m_awcache='0; m_awprot='0;
  m_wdata='0; m_wstrb='0; m_wlast='0;
  m_arid='0; m_araddr='0; m_arlen='0; m_arsize='0; m_arburst='0;
  m_arlock='0; m_arcache='0; m_arprot='0;
  m_awvalid='0; m_wvalid='0; m_bready='0; m_arvalid='0; m_rready='0;
  if(rst_n) begin
    case(wstate)
    WRITE_ADDR: begin
      m_awaddr  = s_awaddr [wowner*32  +: 32];
      m_awlen   = s_awlen  [wowner*8   +: 8 ];
      m_awsize  = s_awsize [wowner*3   +: 3 ];
      m_awburst = s_awburst[wowner*2   +: 2 ];
      m_awlock  = s_awlock [wowner*1   +: 1 ];
      m_awcache = s_awcache[wowner*4   +: 4 ];
      m_awprot  = s_awprot [wowner*3   +: 3 ];
      m_awvalid = s_awvalid[wowner];
      s_awready[wowner] = m_awready;
    end
    WRITE_DATA: begin
      m_wdata = s_wdata[wowner*128 +: 128];
      m_wstrb = s_wstrb[wowner*16  +: 16 ];
      m_wlast = s_wlast[wowner];
      m_wvalid= s_wvalid[wowner];
      s_wready[wowner] = m_wready;
    end
    WRITE_RESP: begin
      s_bid  [wowner*8 +: 8] = write_id;
      s_bvalid[wowner]       = m_bvalid;
      s_bresp[wowner*2 +: 2] = m_bresp;
      m_bready               = s_bready[wowner];
    end
    endcase
    case(rstate)
    READ_ADDR: begin
      m_araddr  = s_araddr [rowner*32  +: 32];
      m_arlen   = s_arlen  [rowner*8   +: 8 ];
      m_arsize  = s_arsize [rowner*3   +: 3 ];
      m_arburst = s_arburst[rowner*2   +: 2 ];
      m_arlock  = s_arlock [rowner*1   +: 1 ];
      m_arcache = s_arcache[rowner*4   +: 4 ];
      m_arprot  = s_arprot [rowner*3   +: 3 ];
      m_arvalid = s_arvalid[rowner];
      s_arready[rowner] = m_arready;
    end
    READ_DATA: begin
      s_rid  [rowner*8 +: 8]  = read_id;
      s_rdata[rowner*128 +: 128] = m_rdata;
      s_rresp[rowner*2 +: 2]  = m_rresp;
      s_rlast[rowner]         = m_rlast;
      s_rvalid[rowner]        = m_rvalid;
      m_rready                = s_rready[rowner];
    end
    endcase
  end
end

always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
    wstate<=IDLE; rstate<=READ_IDLE;
    wowner<=0; rowner<=0; wrr<=0; rrr<=0;
    write_id<=0; read_id<=0;
  end else begin
    case(wstate)
    IDLE: if(|s_awvalid) begin
            wowner<=wgrant; wstate<=WRITE_ADDR;
          end
    WRITE_ADDR: if(m_awvalid && m_awready) begin
            write_id <= s_awid[wowner*8 +: 8];
            wrr      <= (wowner==2'd2) ? 2'd0 : wowner + 2'd1;
            wstate   <= WRITE_DATA;
          end
    WRITE_DATA: if(m_wvalid && m_wready && m_wlast) wstate<=WRITE_RESP;
    WRITE_RESP: if(m_bvalid && m_bready)            wstate<=IDLE;
    endcase
    case(rstate)
    READ_IDLE: if(|s_arvalid) begin
            rowner<=rgrant; rstate<=READ_ADDR;
          end
    READ_ADDR: if(m_arvalid && m_arready) begin
            read_id <= s_arid[rowner*8 +: 8];
            rrr     <= (rowner==2'd2) ? 2'd0 : rowner + 2'd1;
            rstate  <= READ_DATA;
          end
    READ_DATA: if(m_rvalid && m_rready && m_rlast) rstate<=READ_IDLE;
    endcase
  end
end
endmodule
