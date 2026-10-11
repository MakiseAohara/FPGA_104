// ============================================================================
//  dut_axi_ic.v -- drop-in socket for the DDR3 AXI interconnect
// ----------------------------------------------------------------------------
//  The port list below is a byte-for-byte copy of the *plaintext* wrapper of
//  the vendor IP (ip/axi_interconnect/axi_interconnect.v, lines 49-140).
//  Because this socket has exactly the same interface, pointing the testbench
//  at the REAL IP is a one-line change:
//
//      //  axi_ic_semantic_model #(.ARB_ORDER(..), .ROUTE_POLICY(..)) u_model (
//      axi_interconnect u_model (                 // <-- vendor IP, needs a
//                                                 //     pragma-protect capable
//                                                 //     simulator
//
//  Today the body instantiates axi_ic_semantic_model, a behavioural model,
//  because iverilog cannot compile the encrypted vendor RTL.
// ============================================================================
`timescale 1ns/1ps

module dut_axi_ic #(
    parameter ARB_ORDER    = 0,
    parameter ROUTE_POLICY = 0,
    parameter VERBOSE      = 1
)(
    input  wire             rst_n,
    input  wire             clk,
    input  wire [2:0]       s_axi_awvalid,
    input  wire [95:0]      s_axi_awaddr,
    input  wire [5:0]       s_axi_awlock,
    output wire [2:0]       s_axi_awready,
    input  wire [2:0]       s_axi_arvalid,
    input  wire [95:0]      s_axi_araddr,
    input  wire [5:0]       s_axi_arlock,
    output wire [2:0]       s_axi_arready,
    input  wire [2:0]       s_axi_wvalid,
    input  wire [2:0]       s_axi_wlast,
    input  wire [11:0]      s_axi_wid,
    input  wire [2:0]       s_axi_bready,
    output wire [5:0]       s_axi_bresp,
    input  wire [2:0]       s_axi_rready,
    output wire [11:0]      s_axi_bid,
    output wire [11:0]      s_axi_rid,
    input  wire [383:0]     s_axi_wdata,
    output wire [383:0]     s_axi_rdata,
    output wire [5:0]       s_axi_rresp,
    output wire [2:0]       s_axi_bvalid,
    output wire [2:0]       s_axi_rvalid,
    output wire [2:0]       s_axi_rlast,
    input  wire [47:0]      s_axi_wstrb,
    output wire [0:0]       m_axi_awvalid,
    output wire [31:0]      m_axi_awaddr,
    output wire [1:0]       m_axi_awlock,
    input  wire [0:0]       m_axi_awready,
    output wire [0:0]       m_axi_arvalid,
    output wire [31:0]      m_axi_araddr,
    output wire [1:0]       m_axi_arlock,
    input  wire [0:0]       m_axi_arready,
    output wire [0:0]       m_axi_wvalid,
    output wire [0:0]       m_axi_wlast,
    output wire [0:0]       m_axi_bready,
    input  wire [1:0]       m_axi_bresp,
    output wire [0:0]       m_axi_rready,
    input  wire [3:0]       m_axi_bid,
    input  wire [3:0]       m_axi_rid,
    output wire [127:0]     m_axi_wdata,
    input  wire [127:0]     m_axi_rdata,
    input  wire [1:0]       m_axi_rresp,
    input  wire [0:0]       m_axi_bvalid,
    input  wire [0:0]       m_axi_rvalid,
    input  wire [0:0]       m_axi_rlast,
    output wire [15:0]      m_axi_wstrb,
    input  wire [0:0]       m_axi_wready,
    output wire [2:0]       s_axi_wready,
    input  wire [8:0]       s_axi_awprot,
    input  wire [11:0]      s_axi_awcache,
    input  wire [11:0]      s_axi_awqos,
    input  wire [2:0]       s_axi_awuser,
    input  wire [11:0]      s_axi_arqos,
    input  wire [11:0]      s_axi_arcache,
    output wire [2:0]       m_axi_awprot,
    input  wire [11:0]      s_axi_arid,
    input  wire [8:0]       s_axi_arsize,
    input  wire [23:0]      s_axi_arlen,
    input  wire [5:0]       s_axi_arburst,
    input  wire [8:0]       s_axi_arprot,
    input  wire [11:0]      s_axi_awid,
    input  wire [5:0]       s_axi_awburst,
    input  wire [23:0]      s_axi_awlen,
    input  wire [8:0]       s_axi_awsize,
    output wire [3:0]       m_axi_awid,
    output wire [1:0]       m_axi_awburst,
    output wire [7:0]       m_axi_awlen,
    output wire [2:0]       m_axi_awsize,
    output wire [3:0]       m_axi_awcache,
    output wire [3:0]       m_axi_awqos,
    output wire [0:0]       m_axi_awuser,
    output wire [2:0]       m_axi_arprot,
    output wire [1:0]       m_axi_arburst,
    output wire [7:0]       m_axi_arlen,
    output wire [2:0]       m_axi_arsize,
    output wire [3:0]       m_axi_arcache,
    output wire [3:0]       m_axi_arqos,
    output wire [0:0]       m_axi_aruser,
    output wire [3:0]       m_axi_awregion,
    output wire [3:0]       m_axi_arregion,
    output wire [3:0]       m_axi_arid,
    output wire [0:0]       m_axi_wuser,
    input  wire [0:0]       m_axi_ruser,
    input  wire [0:0]       m_axi_buser,
    input  wire [2:0]       s_axi_aruser,
    input  wire [2:0]       s_axi_wuser,
    output wire [2:0]       s_axi_buser,
    output wire [2:0]       s_axi_ruser,
    output wire             decode_err_aw,
    output wire             decode_err_ar,
    output wire [31:0]      aw_grant_count,
    output wire [31:0]      ar_grant_count
);

    axi_ic_semantic_model #(
        .ARB_ORDER    (ARB_ORDER),
        .ROUTE_POLICY (ROUTE_POLICY),
        .VERBOSE      (VERBOSE)
    ) u_model (
        .clk             (clk),
        .rst_n           (rst_n),
        .s_axi_awvalid   (s_axi_awvalid),
        .s_axi_awaddr    (s_axi_awaddr),
        .s_axi_awid      (s_axi_awid),
        .s_axi_awready   (s_axi_awready),
        .s_axi_wvalid    (s_axi_wvalid),
        .s_axi_wlast     (s_axi_wlast),
        .s_axi_wdata     (s_axi_wdata),
        .s_axi_wstrb     (s_axi_wstrb),
        .s_axi_wready    (s_axi_wready),
        .s_axi_bvalid    (s_axi_bvalid),
        .s_axi_bresp     (s_axi_bresp),
        .s_axi_bid       (s_axi_bid),
        .s_axi_bready    (s_axi_bready),
        .s_axi_arvalid   (s_axi_arvalid),
        .s_axi_araddr    (s_axi_araddr),
        .s_axi_arid      (s_axi_arid),
        .s_axi_arready   (s_axi_arready),
        .s_axi_rvalid    (s_axi_rvalid),
        .s_axi_rdata     (s_axi_rdata),
        .s_axi_rresp     (s_axi_rresp),
        .s_axi_rid       (s_axi_rid),
        .s_axi_rlast     (s_axi_rlast),
        .s_axi_rready    (s_axi_rready),
        .m_axi_awvalid   (m_axi_awvalid),
        .m_axi_awaddr    (m_axi_awaddr),
        .m_axi_awid      (m_axi_awid),
        .m_axi_awlen     (m_axi_awlen),
        .m_axi_awsize    (m_axi_awsize),
        .m_axi_awburst   (m_axi_awburst),
        .m_axi_awready   (m_axi_awready[0]),
        .m_axi_wvalid    (m_axi_wvalid),
        .m_axi_wdata     (m_axi_wdata),
        .m_axi_wstrb     (m_axi_wstrb),
        .m_axi_wlast     (m_axi_wlast),
        .m_axi_wready    (m_axi_wready[0]),
        .m_axi_bvalid    (m_axi_bvalid[0]),
        .m_axi_bid       (m_axi_bid),
        .m_axi_bresp     (m_axi_bresp),
        .m_axi_bready    (m_axi_bready),
        .m_axi_arvalid   (m_axi_arvalid),
        .m_axi_araddr    (m_axi_araddr),
        .m_axi_arid      (m_axi_arid),
        .m_axi_arlen     (m_axi_arlen),
        .m_axi_arsize    (m_axi_arsize),
        .m_axi_arburst   (m_axi_arburst),
        .m_axi_arready   (m_axi_arready[0]),
        .m_axi_rvalid    (m_axi_rvalid[0]),
        .m_axi_rdata     (m_axi_rdata),
        .m_axi_rid       (m_axi_rid),
        .m_axi_rresp     (m_axi_rresp),
        .m_axi_rlast     (m_axi_rlast[0]),
        .m_axi_rready    (m_axi_rready),
        .decode_err_aw   (decode_err_aw),
        .decode_err_ar   (decode_err_ar),
        .aw_grant_count  (aw_grant_count),
        .ar_grant_count  (ar_grant_count)
    );

    // signals the model does not drive -- tied off, exactly as the DDR3
    // controller ignores them (see mmt_top.v:816/824/840/848)
    assign m_axi_awlock   = 2'b00;
    assign m_axi_arlock   = 2'b00;
    assign m_axi_awprot   = 3'b000;
    assign m_axi_arprot   = 3'b000;
    assign m_axi_awcache  = 4'h0;
    assign m_axi_arcache  = 4'h0;
    assign m_axi_awqos    = 4'h0;
    assign m_axi_arqos    = 4'h0;
    assign m_axi_awuser   = 1'b0;
    assign m_axi_aruser   = 1'b0;
    assign m_axi_wuser    = 1'b0;
    assign m_axi_awregion = 4'h0;
    assign m_axi_arregion = 4'h0;
    assign s_axi_buser    = 3'b000;
    assign s_axi_ruser    = 3'b000;

endmodule
