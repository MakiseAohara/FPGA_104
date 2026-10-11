// ============================================================================
//  tb_axi_ic.v -- testbench for the 3-master / 1-slave DDR3 AXI interconnect
// ----------------------------------------------------------------------------
//  DUT: dut_axi_ic (see dut_axi_ic.v) which today wraps the behavioural model
//       axi_ic_semantic_model.  Its port list is identical to the plaintext
//       wrapper of the vendor IP, so the same testbench can be pointed at the
//       real axi_interconnect on a simulator that can decrypt pragma-protect.
//
//  Master models reproduce the actual ID widths and the top-level truncation of
//  rtl/mm/mmt_top.v:
//      s0 = frame_buffer   native ID 6 bits, hardwired 0
//                          (frame_buffer/ddr_rd_buffer.v:227 arid = 6'h00,
//                           frame_buffer/ddr_wr_buffer.v:494 awid = 8'd0)
//      s1 = Sapphire SoC   native ID 8 bits
//      s2 = TinyML         native ID 8 bits, no ID source -> 0
//
//  Run with:  pwsh -File sim\axi_ic\run_axi_ic.ps1
// ============================================================================
`timescale 1ns/1ps

`ifndef ARB_ORDER_VAL
 `define ARB_ORDER_VAL 0
`endif
`ifndef ROUTE_POLICY_VAL
 `define ROUTE_POLICY_VAL 0
`endif

module tb_axi_ic;

    localparam integer ARB_ORDER    = `ARB_ORDER_VAL;
    localparam integer ROUTE_POLICY = `ROUTE_POLICY_VAL;

    localparam integer ID_W0 = 6;      // frame_buffer
    localparam integer ID_W1 = 8;      // Sapphire SoC
    localparam integer ID_W2 = 8;      // TinyML
    localparam integer DW    = 128;

    // ---------------- addressing / data ------------------------------------
    localparam [31:0] A0  = 32'h0000_1000;
    localparam [31:0] A1  = 32'h0010_0000;
    localparam [31:0] A2  = 32'h0020_0000;
    localparam [31:0] AC0 = 32'h0000_2000;
    localparam [31:0] AC2 = 32'h0020_1000;
    localparam [31:0] AX  = 32'h1000_0000;   // outside the 0x0/2^28 window

    localparam [127:0] D0  = 128'h000000000000000000000000DEAD0000;
    localparam [127:0] D1  = 128'h000000000000000000000000BEEF0001;
    localparam [127:0] D2  = 128'h000000000000000000000000CAFE0002;
    localparam [127:0] DC0 = 128'h000000000000000000000000C0110000;
    localparam [127:0] DC2 = 128'h000000000000000000000000C0220002;
    localparam [127:0] DW0 = 128'h000000000000000000000000D00D0000;
    localparam [127:0] DW2 = 128'h000000000000000000000000D00D0002;

    localparam [5:0]  ID0 = 6'h00;     // frame_buffer: hardwired 0
    localparam [7:0]  ID1 = 8'h05;     // SoC, fits in 4 bits
    localparam [7:0]  ID2 = 8'h0A;     // TinyML, fits in 4 bits

    // ---------------- clock / reset ----------------------------------------
    reg clk, rst_n;
    initial begin clk = 1'b0; forever #5 clk = ~clk; end
    initial begin
        rst_n = 1'b0;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
    end

    // ---------------- DUT-facing slave-side buses --------------------------
    wire [2:0]   s_awvalid, s_awready;
    wire [95:0]  s_awaddr;
    wire [11:0]  s_awid;
    wire [23:0]  s_awlen;
    wire [8:0]   s_awsize;
    wire [5:0]   s_awburst;
    wire [2:0]   s_wvalid, s_wready, s_wlast;
    wire [383:0] s_wdata;
    wire [47:0]  s_wstrb;
    wire [2:0]   s_bvalid, s_bready;
    wire [11:0]  s_bid;
    wire [5:0]   s_bresp;
    wire [2:0]   s_arvalid, s_arready;
    wire [95:0]  s_araddr;
    wire [11:0]  s_arid;
    wire [23:0]  s_arlen;
    wire [8:0]   s_arsize;
    wire [5:0]   s_arburst;
    wire [2:0]   s_rvalid, s_rready, s_rlast;
    wire [383:0] s_rdata;
    wire [11:0]  s_rid;
    wire [5:0]   s_rresp;

    // ---------------- DUT master port --------------------------------------
    wire         m_awvalid, m_awready, m_wvalid, m_wready;
    wire         m_bvalid, m_bready, m_arvalid, m_arready;
    wire         m_rvalid, m_rready, m_rlast;
    wire [31:0]  m_awaddr, m_araddr;
    wire [3:0]   m_awid, m_arid, m_bid, m_rid;
    wire [127:0] m_wdata, m_rdata;
    wire [15:0]  m_wstrb;
    wire [7:0]   m_awlen, m_arlen;
    wire [2:0]   m_awsize, m_arsize;
    wire [1:0]   m_awburst, m_arburst, m_bresp, m_rresp;

    // ---------------- global counters from the model ------------------------
    wire         decode_err_aw, decode_err_ar;
    wire [31:0]  aw_grant_count, ar_grant_count;

    // ---------------- master BFM command buses ------------------------------
    reg  [2:0]     m_start;
    reg  [2:0]     m_isw;
    reg  [95:0]    m_addr;
    reg  [ID_W0-1:0] m_id0;
    reg  [ID_W1-1:0] m_id1;
    reg  [ID_W2-1:0] m_id2;
    reg  [383:0]   m_wdata_cmd;
    wire [2:0]     m_done;
    wire [2:0]     m_err;
    wire [23:0]    m_errcode;      // 8 bits per port
    wire [11:0]    m_respid;       // 4 bits per port
    wire [383:0]   m_rdata_cmd;    // 128 bits per port

    // ---------------- AXI between BFMs and DUT ------------------------------
    wire [2:0]   ax_awvalid, ax_awready;
    wire [95:0]  ax_awaddr;
    wire [11:0]  ax_awid;
    wire [23:0]  ax_awlen;
    wire [8:0]   ax_awsize;
    wire [5:0]   ax_awburst;
    wire [2:0]   ax_wvalid, ax_wready, ax_wlast;
    wire [383:0] ax_wdata;
    wire [47:0]  ax_wstrb;
    wire [2:0]   ax_bvalid, ax_bready;
    wire [11:0]  ax_bid;
    wire [5:0]   ax_bresp;
    wire [2:0]   ax_arvalid, ax_arready;
    wire [95:0]  ax_araddr;
    wire [11:0]  ax_arid;
    wire [23:0]  ax_arlen;
    wire [8:0]   ax_arsize;
    wire [5:0]   ax_arburst;
    wire [2:0]   ax_rvalid, ax_rready, ax_rlast;
    wire [383:0] ax_rdata;
    wire [11:0]  ax_rid;
    wire [5:0]   ax_rresp;

    assign s_awvalid = ax_awvalid;
    assign s_awaddr  = ax_awaddr;
    assign s_awid    = ax_awid;
    assign s_awlen   = ax_awlen;
    assign s_awsize  = ax_awsize;
    assign s_awburst = ax_awburst;
    assign s_wvalid  = ax_wvalid;
    assign s_wlast   = ax_wlast;
    assign s_wdata   = ax_wdata;
    assign s_wstrb   = ax_wstrb;
    assign s_bready  = ax_bready;
    assign s_arvalid = ax_arvalid;
    assign s_araddr  = ax_araddr;
    assign s_arid    = ax_arid;
    assign s_arlen   = ax_arlen;
    assign s_arsize  = ax_arsize;
    assign s_arburst = ax_arburst;
    assign s_rready  = ax_rready;
    assign ax_awready = s_awready;
    assign ax_wready  = s_wready;
    assign ax_bvalid  = s_bvalid;
    assign ax_bid     = s_bid;
    assign ax_bresp   = s_bresp;
    assign ax_arready = s_arready;
    assign ax_rvalid  = s_rvalid;
    assign ax_rdata   = s_rdata;
    assign ax_rresp   = s_rresp;
    assign ax_rid     = s_rid;
    assign ax_rlast   = s_rlast;

    // ---------------- DUT ---------------------------------------------------
    dut_axi_ic #(
        .ARB_ORDER    (ARB_ORDER),
        .ROUTE_POLICY (ROUTE_POLICY),
        .VERBOSE      (1)
    ) u_dut (
        .rst_n          (rst_n),
        .clk            (clk),
        .s_axi_awvalid  (s_awvalid),  .s_axi_awaddr (s_awaddr),
        .s_axi_awlock   (6'h00),      .s_axi_awready(s_awready),
        .s_axi_arvalid  (s_arvalid),  .s_axi_araddr (s_araddr),
        .s_axi_arlock   (6'h00),      .s_axi_arready(s_arready),
        .s_axi_wvalid   (s_wvalid),   .s_axi_wlast  (s_wlast),
        .s_axi_wid      (12'h000),    .s_axi_bready (s_bready),
        .s_axi_bresp    (s_bresp),    .s_axi_rready (s_rready),
        .s_axi_bid      (s_bid),      .s_axi_rid    (s_rid),
        .s_axi_wdata    (s_wdata),    .s_axi_rdata  (s_rdata),
        .s_axi_rresp    (s_rresp),    .s_axi_bvalid (s_bvalid),
        .s_axi_rvalid   (s_rvalid),   .s_axi_rlast  (s_rlast),
        .s_axi_wstrb    (s_wstrb),
        .s_axi_awid     (s_awid),     .s_axi_arid   (s_arid),
        .s_axi_awlen    (s_awlen),    .s_axi_arlen  (s_arlen),
        .s_axi_awsize   (s_awsize),   .s_axi_arsize (s_arsize),
        .s_axi_awburst  (s_awburst),  .s_axi_arburst(s_arburst),
        .s_axi_wready   (s_wready),
        .s_axi_awprot   (9'h000),     .s_axi_awcache(12'h000),
        .s_axi_awqos    (12'h000),    .s_axi_awuser (3'h0),
        .s_axi_arqos    (12'h000),    .s_axi_arcache(12'h000),
        .s_axi_arprot   (9'h000),     .s_axi_aruser (3'h0),
        .s_axi_wuser    (3'h0),
        .s_axi_buser    (),           .s_axi_ruser  (),
        .m_axi_awvalid  (m_awvalid),  .m_axi_awaddr (m_awaddr),
        .m_axi_awlock   (m_awlock),   .m_axi_awready(m_awready),
        .m_axi_awid     (m_awid),     .m_axi_awlen  (m_awlen),
        .m_axi_awsize   (m_awsize),   .m_axi_awburst(m_awburst),
        .m_axi_awprot   (m_awprot),   .m_axi_awcache(m_awcache),
        .m_axi_awqos    (m_awqos),    .m_axi_awuser (m_awuser),
        .m_axi_awregion (m_awregion),
        .m_axi_wvalid   (m_wvalid),   .m_axi_wdata  (m_wdata),
        .m_axi_wstrb    (m_wstrb),    .m_axi_wlast  (m_wlast),
        .m_axi_wready   (m_wready),   .m_axi_wuser  (m_wuser),
        .m_axi_bvalid   (m_bvalid),   .m_axi_bready (m_bready),
        .m_axi_bid      (m_bid),      .m_axi_bresp  (m_bresp),
        .m_axi_buser    (1'b0),
        .m_axi_arvalid  (m_arvalid),  .m_axi_araddr (m_araddr),
        .m_axi_arlock   (m_arlock),   .m_axi_arready(m_arready),
        .m_axi_arid     (m_arid),     .m_axi_arlen  (m_arlen),
        .m_axi_arsize   (m_arsize),   .m_axi_arburst(m_arburst),
        .m_axi_arprot   (m_arprot),   .m_axi_arcache(m_arcache),
        .m_axi_arqos    (m_arqos),    .m_axi_aruser (m_aruser),
        .m_axi_arregion (m_arregion),
        .m_axi_rvalid   (m_rvalid),   .m_axi_rready (m_rready),
        .m_axi_rdata    (m_rdata),    .m_axi_rid    (m_rid),
        .m_axi_rresp    (m_rresp),    .m_axi_rlast  (m_rlast),
        .m_axi_ruser    (1'b0),
        .decode_err_aw  (decode_err_aw),
        .decode_err_ar  (decode_err_ar),
        .aw_grant_count (aw_grant_count),
        .ar_grant_count (ar_grant_count)
    );

    wire [1:0] m_awlock, m_arlock;
    wire [2:0] m_awprot, m_arprot;
    wire [3:0] m_awcache, m_arcache, m_awqos, m_arqos;
    wire [0:0] m_awuser, m_aruser, m_wuser;
    wire [3:0] m_awregion, m_arregion;

    // ---------------- the DDR3 controller stand-in --------------------------
    axi4_slave_model #(
        .DATA_W(DW), .ADDR_W(32), .ID_W(4), .CAM_N(256),
        .B_LAT(2), .R_LAT(3), .VERBOSE(1)
    ) u_slave (
        .clk(clk), .rst_n(rst_n),
        .s_awid(m_awid), .s_awaddr(m_awaddr), .s_awlen(m_awlen),
        .s_awsize(m_awsize), .s_awburst(m_awburst),
        .s_awvalid(m_awvalid), .s_awready(m_awready),
        .s_wdata(m_wdata), .s_wstrb(m_wstrb), .s_wlast(m_wlast),
        .s_wvalid(m_wvalid), .s_wready(m_wready),
        .s_bvalid(m_bvalid), .s_bid(m_bid), .s_bresp(m_bresp),
        .s_bready(m_bready),
        .s_arid(m_arid), .s_araddr(m_araddr), .s_arlen(m_arlen),
        .s_arsize(m_arsize), .s_arburst(m_arburst),
        .s_arvalid(m_arvalid), .s_arready(m_arready),
        .s_rvalid(m_rvalid), .s_rid(m_rid), .s_rdata(m_rdata),
        .s_rresp(m_rresp), .s_rlast(m_rlast), .s_rready(m_rready),
        .aw_accepted(), .ar_accepted(), .b_returned(), .r_returned()
    );

    // ---------------- master BFMs -------------------------------------------
    axi_master_bfm #(.ID_W(ID_W0), .DATA_W(DW), .ADDR_W(32), .MID(0), .TIMEOUT(1200)) u_m0 (
        .clk(clk), .rst_n(rst_n),
        .cmd_start(m_start[0]), .cmd_is_write(m_isw[0]),
        .cmd_addr(m_addr[0*32 +: 32]), .cmd_id(m_id0),
        .cmd_wdata(m_wdata_cmd[0*128 +: 128]),
        .cmd_done(m_done[0]), .cmd_err(m_err[0]),
        .cmd_err_code(m_errcode[0*8 +: 8]),
        .cmd_resp_id(m_respid[0*4 +: 4]),
        .cmd_rdata(m_rdata_cmd[0*128 +: 128]),
        .axi_awid(ax_awid[0*4 +: 4]), .axi_awaddr(ax_awaddr[0*32 +: 32]),
        .axi_awlen(ax_awlen[0*8 +: 8]), .axi_awsize(ax_awsize[0*3 +: 3]),
        .axi_awburst(ax_awburst[0*2 +: 2]), .axi_awvalid(ax_awvalid[0]),
        .axi_awready(ax_awready[0]),
        .axi_wdata(ax_wdata[0*128 +: 128]), .axi_wstrb(ax_wstrb[0*16 +: 16]),
        .axi_wlast(ax_wlast[0]), .axi_wvalid(ax_wvalid[0]),
        .axi_wready(ax_wready[0]),
        .axi_bready(ax_bready[0]), .axi_bid(ax_bid[0*4 +: 4]),
        .axi_bresp(ax_bresp[0*2 +: 2]), .axi_bvalid(ax_bvalid[0]),
        .axi_arid(ax_arid[0*4 +: 4]), .axi_araddr(ax_araddr[0*32 +: 32]),
        .axi_arlen(ax_arlen[0*8 +: 8]), .axi_arsize(ax_arsize[0*3 +: 3]),
        .axi_arburst(ax_arburst[0*2 +: 2]), .axi_arvalid(ax_arvalid[0]),
        .axi_arready(ax_arready[0]),
        .axi_rready(ax_rready[0]), .axi_rid(ax_rid[0*4 +: 4]),
        .axi_rdata(ax_rdata[0*128 +: 128]), .axi_rresp(ax_rresp[0*2 +: 2]),
        .axi_rvalid(ax_rvalid[0]), .axi_rlast(ax_rlast[0])
    );

    axi_master_bfm #(.ID_W(ID_W1), .DATA_W(DW), .ADDR_W(32), .MID(1), .TIMEOUT(1200)) u_m1 (
        .clk(clk), .rst_n(rst_n),
        .cmd_start(m_start[1]), .cmd_is_write(m_isw[1]),
        .cmd_addr(m_addr[1*32 +: 32]), .cmd_id(m_id1),
        .cmd_wdata(m_wdata_cmd[1*128 +: 128]),
        .cmd_done(m_done[1]), .cmd_err(m_err[1]),
        .cmd_err_code(m_errcode[1*8 +: 8]),
        .cmd_resp_id(m_respid[1*4 +: 4]),
        .cmd_rdata(m_rdata_cmd[1*128 +: 128]),
        .axi_awid(ax_awid[1*4 +: 4]), .axi_awaddr(ax_awaddr[1*32 +: 32]),
        .axi_awlen(ax_awlen[1*8 +: 8]), .axi_awsize(ax_awsize[1*3 +: 3]),
        .axi_awburst(ax_awburst[1*2 +: 2]), .axi_awvalid(ax_awvalid[1]),
        .axi_awready(ax_awready[1]),
        .axi_wdata(ax_wdata[1*128 +: 128]), .axi_wstrb(ax_wstrb[1*16 +: 16]),
        .axi_wlast(ax_wlast[1]), .axi_wvalid(ax_wvalid[1]),
        .axi_wready(ax_wready[1]),
        .axi_bready(ax_bready[1]), .axi_bid(ax_bid[1*4 +: 4]),
        .axi_bresp(ax_bresp[1*2 +: 2]), .axi_bvalid(ax_bvalid[1]),
        .axi_arid(ax_arid[1*4 +: 4]), .axi_araddr(ax_araddr[1*32 +: 32]),
        .axi_arlen(ax_arlen[1*8 +: 8]), .axi_arsize(ax_arsize[1*3 +: 3]),
        .axi_arburst(ax_arburst[1*2 +: 2]), .axi_arvalid(ax_arvalid[1]),
        .axi_arready(ax_arready[1]),
        .axi_rready(ax_rready[1]), .axi_rid(ax_rid[1*4 +: 4]),
        .axi_rdata(ax_rdata[1*128 +: 128]), .axi_rresp(ax_rresp[1*2 +: 2]),
        .axi_rvalid(ax_rvalid[1]), .axi_rlast(ax_rlast[1])
    );

    axi_master_bfm #(.ID_W(ID_W2), .DATA_W(DW), .ADDR_W(32), .MID(2), .TIMEOUT(1200)) u_m2 (
        .clk(clk), .rst_n(rst_n),
        .cmd_start(m_start[2]), .cmd_is_write(m_isw[2]),
        .cmd_addr(m_addr[2*32 +: 32]), .cmd_id(m_id2),
        .cmd_wdata(m_wdata_cmd[2*128 +: 128]),
        .cmd_done(m_done[2]), .cmd_err(m_err[2]),
        .cmd_err_code(m_errcode[2*8 +: 8]),
        .cmd_resp_id(m_respid[2*4 +: 4]),
        .cmd_rdata(m_rdata_cmd[2*128 +: 128]),
        .axi_awid(ax_awid[2*4 +: 4]), .axi_awaddr(ax_awaddr[2*32 +: 32]),
        .axi_awlen(ax_awlen[2*8 +: 8]), .axi_awsize(ax_awsize[2*3 +: 3]),
        .axi_awburst(ax_awburst[2*2 +: 2]), .axi_awvalid(ax_awvalid[2]),
        .axi_awready(ax_awready[2]),
        .axi_wdata(ax_wdata[2*128 +: 128]), .axi_wstrb(ax_wstrb[2*16 +: 16]),
        .axi_wlast(ax_wlast[2]), .axi_wvalid(ax_wvalid[2]),
        .axi_wready(ax_wready[2]),
        .axi_bready(ax_bready[2]), .axi_bid(ax_bid[2*4 +: 4]),
        .axi_bresp(ax_bresp[2*2 +: 2]), .axi_bvalid(ax_bvalid[2]),
        .axi_arid(ax_arid[2*4 +: 4]), .axi_araddr(ax_araddr[2*32 +: 32]),
        .axi_arlen(ax_arlen[2*8 +: 8]), .axi_arsize(ax_arsize[2*3 +: 3]),
        .axi_arburst(ax_arburst[2*2 +: 2]), .axi_arvalid(ax_arvalid[2]),
        .axi_arready(ax_arready[2]),
        .axi_rready(ax_rready[2]), .axi_rid(ax_rid[2*4 +: 4]),
        .axi_rdata(ax_rdata[2*128 +: 128]), .axi_rresp(ax_rresp[2*2 +: 2]),
        .axi_rvalid(ax_rvalid[2]), .axi_rlast(ax_rlast[2])
    );

    // ---------------- latched completion flags ------------------------------
    // m_done is a one-cycle pulse; the sequencer may test it later, so latch it.
    reg [2:0] done_sticky;
    reg [2:0] done_ack;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) done_sticky <= 3'b000;
        else        done_sticky <= (done_sticky & ~done_ack) | m_done;
    end
    // ---------------- grant-order monitor -----------------------------------
    reg  [1:0] ar_ord [0:31];
    reg  [1:0] aw_ord [0:31];
    reg  [5:0] ar_n, aw_n;
    reg        clr_ord;
    integer    mi;
    reg        got;

    initial begin
        clr_ord = 1'b0;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            ar_n <= 6'd0;
            aw_n <= 6'd0;
        end else if (clr_ord) begin
            ar_n <= 6'd0;
            aw_n <= 6'd0;
        end else begin
            got = 1'b0;
            for (mi = 2; mi >= 0; mi = mi - 1) begin
                if (!got && s_arvalid[mi] && s_arready[mi] && (ar_n < 6'd32)) begin
                    ar_ord[ar_n] <= mi[1:0];
                    ar_n <= ar_n + 6'd1;
                    got = 1'b1;
                end
            end
            got = 1'b0;
            for (mi = 2; mi >= 0; mi = mi - 1) begin
                if (!got && s_awvalid[mi] && s_awready[mi] && (aw_n < 6'd32)) begin
                    aw_ord[aw_n] <= mi[1:0];
                    aw_n <= aw_n + 6'd1;
                    got = 1'b1;
                end
            end
        end
    end

    // ---------------- scoreboard --------------------------------------------
    integer tc_pass, tc_fail, tc_note;
    integer pj;

    task chk;
        input [8*64-1:0] nm;
        input            ok;
        begin
            if (ok) begin
                tc_pass = tc_pass + 1;
                $display("[PASS] %0s", nm);
            end else begin
                tc_fail = tc_fail + 1;
                $display("[FAIL] %0s", nm);
            end
        end
    endtask

    task note;
        input [8*96-1:0] nm;
        begin
            tc_note = tc_note + 1;
            $display("[NOTE] %0s", nm);
        end
    endtask

    task wait_p;
        input integer p;
        integer g;
        begin
            g = 0;
            while (!done_sticky[p] && g < 3000) begin
                @(posedge clk);
                g = g + 1;
            end
            if (g >= 3000)
                $display("[TB] *** TIMEOUT waiting for port %0d at t=%0t (done=%b) ***", p, $time, done_sticky);
        end
    endtask

    task issue_p;
        input integer    p;
        input            isw;
        input [31:0]     a;
        input [7:0]      idv;
        input [127:0]    d;
        begin
            // Align to a negedge first, then hold cmd_start across a full
            // posedge so the edge-triggered BFM actually samples it.
            @(negedge clk);
            done_ack[p]           = 1'b1;
            m_isw[p]              = isw;
            m_addr[p*32 +: 32]    = a;
            m_wdata_cmd[p*128 +: 128] = d;
            case (p)
                0: m_id0 = idv[ID_W0-1:0];
                1: m_id1 = idv[ID_W1-1:0];
                default: m_id2 = idv[ID_W2-1:0];
            endcase
            m_start[p] = 1'b1;
            @(negedge clk);
            m_start[p] = 1'b0;
            done_ack[p] = 1'b0;
        end
    endtask

    task arm_all;
        begin
            @(negedge clk);
            done_ack = 3'b111;
            @(negedge clk);
            done_ack = 3'b000;
        end
    endtask

    task clear_ord;
        begin
            @(negedge clk);
            clr_ord = 1'b1;
            @(negedge clk);
            clr_ord = 1'b0;
        end
    endtask

    task show_ord;
        input [8*24-1:0] nm;
        begin
            $write("[ARB] %0s AR:", nm);
            for (pj = 0; pj < ar_n && pj < 32; pj = pj + 1) $write(" s%0d", ar_ord[pj]);
            $write("   AW:");
            for (pj = 0; pj < aw_n && pj < 32; pj = pj + 1) $write(" s%0d", aw_ord[pj]);
            $write("\n");
        end
    endtask

    // ---------------- main sequence -----------------------------------------
    initial begin
        tc_pass = 0; tc_fail = 0; tc_note = 0;
        $timeformat(-9, 0, " ns", 12);
        done_ack = 3'b000;   // done_sticky is cleared by the rst_n branch
        m_start = 3'b000; m_isw = 3'b000; m_addr = 96'h0;
        m_id0 = {ID_W0{1'b0}}; m_id1 = {ID_W1{1'b0}}; m_id2 = {ID_W2{1'b0}};
        m_wdata_cmd = 384'h0;

        wait (rst_n);
        repeat (5) @(posedge clk);
        $display("[TB] reset released at t=%0t (tick check)", $time);

        $display("==============================================================");
        $display(" AXI interconnect testbench -- DUT = behavioural MODEL");
        $display(" ARB_ORDER=%0d", ARB_ORDER);
        if (ARB_ORDER == 0) $display("   -> s0 has highest priority (s0,s1,s2)");
        else                $display("   -> s2 has highest priority (s2,s1,s0)");
        $display(" ROUTE_POLICY=%0d", ROUTE_POLICY);
        if (ROUTE_POLICY == 0) $display("   -> BY_PORT: response follows the queued grant");
        else                   $display("   -> BY_ID: response follows the ID->port table");
        $display("==============================================================");

        // ================= TC1: single-master read/write ====================
        $display("---- TC1 single-master R/W ----");
        issue_p(0, 1'b1, A0, ID0, D0); wait_p(0);
        chk("TC1a_s0_write_ok", (m_errcode[0*8 +: 8] == 8'h00));
        issue_p(0, 1'b0, A0, ID0, 128'h0); wait_p(0);
        chk("TC1b_s0_read_back", (m_errcode[0*8 +: 8] == 8'h00) &&
                                (m_rdata_cmd[0*128 +: 128] == D0));

        issue_p(1, 1'b1, A1, ID1, D1); wait_p(1);
        chk("TC1c_s1_write_ok", (m_errcode[1*8 +: 8] == 8'h00));
        issue_p(1, 1'b0, A1, ID1, 128'h0); wait_p(1);
        chk("TC1d_s1_read_back", (m_errcode[1*8 +: 8] == 8'h00) &&
                                 (m_rdata_cmd[1*128 +: 128] == D1));

        issue_p(2, 1'b1, A2, ID2, D2); wait_p(2);
        chk("TC1e_s2_write_ok", (m_errcode[2*8 +: 8] == 8'h00));
        issue_p(2, 1'b0, A2, ID2, 128'h0); wait_p(2);
        chk("TC1f_s2_read_back", (m_errcode[2*8 +: 8] == 8'h00) &&
                                 (m_rdata_cmd[2*128 +: 128] == D2));

        // ================= TC2: three masters at once -> arbitration =======
        $display("---- TC2 three masters concurrent (arbitration order) ----");
        arm_all;
        clear_ord;
        @(negedge clk);
        m_isw = 3'b000;
        m_addr[0*32 +: 32] = A0; m_addr[1*32 +: 32] = A1; m_addr[2*32 +: 32] = A2;
        m_id0 = ID0; m_id1 = ID1; m_id2 = ID2;
        m_start = 3'b111;
        @(negedge clk);
        m_start = 3'b000;
        wait_p(0); wait_p(1); wait_p(2);
        show_ord("TC2-read");
        chk("TC2a_concurrent_reads_complete",
            (m_errcode[0*8 +: 8] == 8'h00) && (m_errcode[1*8 +: 8] == 8'h00) &&
            (m_errcode[2*8 +: 8] == 8'h00) &&
            (m_rdata_cmd[0*128 +: 128] == D0) &&
            (m_rdata_cmd[1*128 +: 128] == D1) &&
            (m_rdata_cmd[2*128 +: 128] == D2));

        arm_all;
        clear_ord;
        @(negedge clk);
        m_isw = 3'b111;
        m_addr[0*32 +: 32] = A0; m_addr[1*32 +: 32] = A1; m_addr[2*32 +: 32] = A2;
        m_wdata_cmd[0*128 +: 128] = D0;
        m_wdata_cmd[1*128 +: 128] = D1;
        m_wdata_cmd[2*128 +: 128] = D2;
        m_id0 = ID0; m_id1 = ID1; m_id2 = ID2;
        m_start = 3'b111;
        @(negedge clk);
        m_start = 3'b000;
        wait_p(0); wait_p(1); wait_p(2);
        show_ord("TC2-write");
        chk("TC2b_concurrent_writes_complete",
            (m_errcode[0*8 +: 8] == 8'h00) && (m_errcode[1*8 +: 8] == 8'h00) &&
            (m_errcode[2*8 +: 8] == 8'h00));

        // ================= TC3: ID collision (the critical test) ============
        $display("---- TC3 ID collision: s0 and s2 both use ID 0 ----");
        // setup with non-colliding IDs so the memory is clean
        issue_p(0, 1'b1, AC0, ID0, DC0); wait_p(0);
        issue_p(2, 1'b1, AC2, ID2, DC2); wait_p(2);
        chk("TC3a_collision_setup",
            (m_errcode[0*8 +: 8] == 8'h00) && (m_errcode[2*8 +: 8] == 8'h00));

        // ---- 3b: concurrent READS, both with native ID 0 ----
        arm_all;
        clear_ord;
        @(negedge clk);
        m_isw = 3'b000;
        m_addr[0*32 +: 32] = AC0; m_addr[2*32 +: 32] = AC2;
        m_id0 = 6'h00; m_id2 = 8'h00;        // <-- COLLISION
        m_start = 3'b101;                    // s0 and s2 only
        @(negedge clk);
        m_start = 3'b000;
        wait_p(0); wait_p(2);
        show_ord("TC3b");
        chk("TC3b_colliding_reads_returned_to_right_port",
            (m_errcode[0*8 +: 8] == 8'h00) && (m_errcode[2*8 +: 8] == 8'h00) &&
            (m_rdata_cmd[0*128 +: 128] == DC0) &&
            (m_rdata_cmd[2*128 +: 128] == DC2));

        // ---- 3c: concurrent WRITES, both with native ID 0 ----
        arm_all;
        clear_ord;
        @(negedge clk);
        m_isw = 3'b111;
        m_addr[0*32 +: 32] = AC0; m_addr[2*32 +: 32] = AC2;
        m_wdata_cmd[0*128 +: 128] = DW0;
        m_wdata_cmd[2*128 +: 128] = DW2;
        m_id0 = 6'h00; m_id2 = 8'h00;        // <-- COLLISION
        m_start = 3'b101;
        @(negedge clk);
        m_start = 3'b000;
        wait_p(0); wait_p(2);
        show_ord("TC3c");
        chk("TC3c_colliding_writes_both_acked",
            (m_errcode[0*8 +: 8] == 8'h00) && (m_errcode[2*8 +: 8] == 8'h00));

        // ================= TC4: mixed traffic, distinct IDs ==================
        $display("---- TC4 mixed traffic with distinct IDs ----");
        arm_all;
        @(negedge clk);
        m_isw              = 3'b001;          // s0 write
        m_isw[1]           = 1'b0;            // s1 read
        m_isw[2]           = 1'b0;            // s2 read
        m_addr[0*32 +: 32] = A0; m_addr[1*32 +: 32] = A1; m_addr[2*32 +: 32] = A2;
        m_wdata_cmd[0*128 +: 128] = D0;
        m_id0 = ID0; m_id1 = ID1; m_id2 = ID2;
        m_start = 3'b111;
        @(negedge clk);
        m_start = 3'b000;
        wait_p(0); wait_p(1); wait_p(2);
        chk("TC4a_mixed_traffic_all_ok",
            (m_errcode[0*8 +: 8] == 8'h00) && (m_errcode[1*8 +: 8] == 8'h00) &&
            (m_errcode[2*8 +: 8] == 8'h00) &&
            (m_rdata_cmd[1*128 +: 128] == D1) &&
            (m_rdata_cmd[2*128 +: 128] == D2));

        // ================= TC5: address window decode ========================
        $display("---- TC5 address window (m0 window = 0x0 / 2^28) ----");
        issue_p(1, 1'b0, AX, ID1, 128'h0); wait_p(1);
        chk("TC5a_out_of_window_access_completes",
            (m_errcode[1*8 +: 8] == 8'h00));
        if (decode_err_ar)
            note("TC5b_model_flags_decode_err_ar=1 for 0x10000000 (outside 0x0/2^28)");
        else
            note("TC5b_model_flags_decode_err_ar=0 -- access still reached m0");

        // ================= TC6: ID truncation fidelity =======================
        $display("---- TC6 ID truncation 8->4->8 ----");
        issue_p(1, 1'b0, A1, 8'h05, 128'h0); wait_p(1);
        chk("TC6a_id_le_0xf_round_trips", (m_errcode[1*8 +: 8] == 8'h00));
        issue_p(1, 1'b0, A1, 8'hA5, 128'h0); wait_p(1);
        chk("TC6b_id_gt_0xf_is_lossy_as_wired",
            ((m_errcode[1*8 +: 8] & 8'h20) != 8'h00));
        note("TC6c_sent id=0xA5, response id seen in bit[3:0] -- top level zero-extends, so a master emitting id>0xF cannot match its own response");

        // ================= TC7: fairness / starvation ========================
        $display("---- TC7 PRIORITY fairness (s0 hog) ----");
        arm_all;
        clear_ord;
        @(negedge clk);
        m_isw = 3'b000;
        m_addr[0*32 +: 32] = A0; m_addr[1*32 +: 32] = A1; m_addr[2*32 +: 32] = A2;
        m_id0 = ID0; m_id1 = ID1; m_id2 = ID2;
        m_start = 3'b111;
        @(negedge clk);
        m_start = 3'b000;
        // re-issue s0 five more times as soon as it finishes
        for (pj = 0; pj < 5; pj = pj + 1) begin
            wait_p(0);
            issue_p(0, 1'b0, A0, ID0, 128'h0);
        end
        wait_p(0); wait_p(1); wait_p(2);
        show_ord("TC7-s0hog");
        chk("TC7a_lower_priority_ports_eventually_served",
            (m_errcode[1*8 +: 8] == 8'h00) && (m_errcode[2*8 +: 8] == 8'h00) &&
            (m_rdata_cmd[1*128 +: 128] == D1) &&
            (m_rdata_cmd[2*128 +: 128] == D2));
        $display("[ARB] total AR grants=%0d  AW grants=%0d", ar_grant_count, aw_grant_count);

        // ================= summary ==========================================
        $display("==============================================================");
        $display("[SUMMARY] PASS=%0d FAIL=%0d NOTE=%0d", tc_pass, tc_fail, tc_note);
        if (tc_fail == 0) begin
            $display("=== AXI_IC RESULT: ALL CHECKS PASSED ===");
            $display("==============================================================");
            $finish;
        end else begin
            $display("=== AXI_IC RESULT: %0d CHECK(S) FAILED ===", tc_fail);
            $display("==============================================================");
            $fatal(1, "axi_ic: %0d check(s) failed", tc_fail);
        end
    end

    // ---------------- global watchdog ---------------------------------------
    initial begin
        #2000000;
        $display("[TB] *** GLOBAL TIMEOUT -- simulation did not finish ***");
        $display("[SUMMARY] PASS=%0d FAIL=%0d NOTE=%0d", tc_pass, tc_fail, tc_note);
        $fatal(1, "axi_ic: global timeout");
    end

endmodule
