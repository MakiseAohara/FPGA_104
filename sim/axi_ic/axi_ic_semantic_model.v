// ============================================================================
//  axi_ic_semantic_model.v -- behavioural 3-to-1 AXI4 interconnect
// ----------------------------------------------------------------------------
//  *** THIS IS A MODEL, NOT THE VENDOR IP -- see docs/AXI互联仿真结论.md ***
//
//  The real RTL (ip/axi_interconnect/axi_interconnect.v) is `pragma protect`
//  encrypted and cannot be compiled by iverilog (measured: syntax error at
//  line 251, exit 2).  No pragma-protect-capable simulator is installed.
//
//  This model reproduces the architecture the Efinity user guide documents for
//  efx_axi_interconnect (Arbiter + Address decoder + Skid-buffer datapath) with
//  the parameters this project actually uses:
//      S_PORTS=3, M_PORTS=1, DATA_WIDTH=128, ID_WIDTH=4, ADDR_WIDTH=32,
//      ARB_MODE="PRIORITY", downstream window 0x0000_0000 / 2^28 (256 MB)
//  (ip/axi_interconnect/settings.json, axi_interconnect_define.vh,
//   axi_interconnect.vh)
//
//  Two things are parameterised because they are precisely the unknowns:
//    ARB_ORDER    : 0 = port 0 wins (s0 highest priority)
//                   1 = port 2 wins (s2 highest priority)
//    ROUTE_POLICY : 0 = BY_PORT -- response follows the queued grant (safe)
//                   1 = BY_ID   -- response follows an ID->port table that is
//                                  overwritten by every grant (the hazard)
//
//  Depth-4 outstanding queues per direction (plus a depth-4 pending-response
//  queue) so that two same-ID transactions really can be in flight at once --
//  that is the precondition for the ID-table hazard to manifest.
// ============================================================================
`timescale 1ns/1ps

module axi_ic_semantic_model #(
    parameter ARB_ORDER    = 0,
    parameter ROUTE_POLICY = 0,
    parameter VERBOSE      = 1
)(
    input  wire             clk,
    input  wire             rst_n,

    // ---------------- slave ports (3, flattened, 4-bit IDs) ----------------
    input  wire [2:0]       s_axi_awvalid,
    input  wire [95:0]      s_axi_awaddr,
    input  wire [11:0]      s_axi_awid,
    output wire [2:0]       s_axi_awready,

    input  wire [2:0]       s_axi_wvalid,
    input  wire [2:0]       s_axi_wlast,
    input  wire [383:0]     s_axi_wdata,
    input  wire [47:0]      s_axi_wstrb,
    output wire [2:0]       s_axi_wready,

    output wire [2:0]       s_axi_bvalid,
    output wire [5:0]       s_axi_bresp,
    output wire [11:0]      s_axi_bid,
    input  wire [2:0]       s_axi_bready,

    input  wire [2:0]       s_axi_arvalid,
    input  wire [95:0]      s_axi_araddr,
    input  wire [11:0]      s_axi_arid,
    output wire [2:0]       s_axi_arready,

    output wire [2:0]       s_axi_rvalid,
    output wire [383:0]     s_axi_rdata,
    output wire [5:0]       s_axi_rresp,
    output wire [11:0]      s_axi_rid,
    output wire [2:0]       s_axi_rlast,
    input  wire [2:0]       s_axi_rready,

    // ---------------- master port (1) --------------------------------------
    output wire             m_axi_awvalid,
    output wire [31:0]      m_axi_awaddr,
    output wire [3:0]       m_axi_awid,
    output wire [7:0]       m_axi_awlen,
    output wire [2:0]       m_axi_awsize,
    output wire [1:0]       m_axi_awburst,
    input  wire             m_axi_awready,

    output wire             m_axi_wvalid,
    output wire [127:0]     m_axi_wdata,
    output wire [15:0]      m_axi_wstrb,
    output wire             m_axi_wlast,
    input  wire             m_axi_wready,

    input  wire             m_axi_bvalid,
    input  wire [3:0]       m_axi_bid,
    input  wire [1:0]       m_axi_bresp,
    output wire             m_axi_bready,

    output wire             m_axi_arvalid,
    output wire [31:0]      m_axi_araddr,
    output wire [3:0]       m_axi_arid,
    output wire [7:0]       m_axi_arlen,
    output wire [2:0]       m_axi_arsize,
    output wire [1:0]       m_axi_arburst,
    input  wire             m_axi_arready,

    input  wire             m_axi_rvalid,
    input  wire [127:0]     m_axi_rdata,
    input  wire [3:0]       m_axi_rid,
    input  wire [1:0]       m_axi_rresp,
    input  wire             m_axi_rlast,
    output wire             m_axi_rready,

    // ---------------- status ------------------------------------------------
    output reg              decode_err_aw,
    output reg              decode_err_ar,
    output reg  [31:0]      aw_grant_count,
    output reg  [31:0]      ar_grant_count
);

    localparam QD = 4;

    // ------------------------------------------------------------------
    //  Address decoder -- the single active window of this build:
    //  ip/axi_interconnect/axi_interconnect.vh  base 0x0000_0000, 28 bits
    // ------------------------------------------------------------------
    function in_window;
        input [31:0] a;
        begin
            in_window = (a[31:28] == 4'h0);
        end
    endfunction

    // ------------------------------------------------------------------
    //  All declared wires first (no forward references)
    // ------------------------------------------------------------------
    reg  [1:0]  aw_gnt;
    reg         aw_gnt_v;
    reg  [1:0]  ar_gnt;
    reg         ar_gnt_v;

    wire        aw_full, ar_full, bq_full;
    wire        aw_push, aw_pop;
    wire        ar_push, ar_pop;
    wire        bq_push, bq_pop;
    wire        w_pop;
    wire [1:0]  b_dest, r_dest;

    // ------------------------------------------------------------------
    //  Write-side state
    // ------------------------------------------------------------------
    reg [1:0]  aw_q_port [0:QD-1];
    reg [3:0]  aw_q_id   [0:QD-1];
    reg [31:0] aw_q_addr [0:QD-1];
    reg [1:0]  aw_wp, aw_rp;
    reg [2:0]  aw_cnt;

    reg [1:0]  bq_port [0:QD-1];
    reg [3:0]  bq_id   [0:QD-1];
    reg [1:0]  bq_wp, bq_rp;
    reg [2:0]  bq_cnt;

    reg [1:0]  w_owner;
    reg        w_active;

    reg [1:0]  bout_port;
    reg [3:0]  bout_id;
    reg        bout_active;

    reg [1:0]  id_owner_w [0:15];
    reg [1:0]  id_owner_r [0:15];

    // ------------------------------------------------------------------
    //  Read-side state
    // ------------------------------------------------------------------
    reg [1:0]  ar_q_port [0:QD-1];
    reg [3:0]  ar_q_id   [0:QD-1];
    reg [31:0] ar_q_addr [0:QD-1];
    reg [1:0]  ar_wp, ar_rp;
    reg [2:0]  ar_cnt;

    reg        r_req_valid;
    reg [1:0]  r_req_port;
    reg [3:0]  r_req_id;

    reg [1:0]  rout_port;
    reg [3:0]  rout_id;
    reg        rout_active;

    integer    k;

    // ------------------------------------------------------------------
    //  Arbitration (combinational, PRIORITY mode)
    // ------------------------------------------------------------------
    always @(*) begin
        aw_gnt_v = 1'b0;
        aw_gnt   = 2'd0;
        if (ARB_ORDER == 0) begin
            if      (s_axi_awvalid[0]) begin aw_gnt_v = 1'b1; aw_gnt = 2'd0; end
            else if (s_axi_awvalid[1]) begin aw_gnt_v = 1'b1; aw_gnt = 2'd1; end
            else if (s_axi_awvalid[2]) begin aw_gnt_v = 1'b1; aw_gnt = 2'd2; end
        end else begin
            if      (s_axi_awvalid[2]) begin aw_gnt_v = 1'b1; aw_gnt = 2'd2; end
            else if (s_axi_awvalid[1]) begin aw_gnt_v = 1'b1; aw_gnt = 2'd1; end
            else if (s_axi_awvalid[0]) begin aw_gnt_v = 1'b1; aw_gnt = 2'd0; end
        end

        ar_gnt_v = 1'b0;
        ar_gnt   = 2'd0;
        if (ARB_ORDER == 0) begin
            if      (s_axi_arvalid[0]) begin ar_gnt_v = 1'b1; ar_gnt = 2'd0; end
            else if (s_axi_arvalid[1]) begin ar_gnt_v = 1'b1; ar_gnt = 2'd1; end
            else if (s_axi_arvalid[2]) begin ar_gnt_v = 1'b1; ar_gnt = 2'd2; end
        end else begin
            if      (s_axi_arvalid[2]) begin ar_gnt_v = 1'b1; ar_gnt = 2'd2; end
            else if (s_axi_arvalid[1]) begin ar_gnt_v = 1'b1; ar_gnt = 2'd1; end
            else if (s_axi_arvalid[0]) begin ar_gnt_v = 1'b1; ar_gnt = 2'd0; end
        end
    end

    assign aw_full = (aw_cnt == QD);
    assign ar_full = (ar_cnt == QD);
    assign bq_full = (bq_cnt == QD);

    assign aw_push = aw_gnt_v && !aw_full;
    assign aw_pop  = w_pop;

    assign ar_push = ar_gnt_v && !ar_full;
    assign ar_pop  = !r_req_valid && (ar_cnt > 0);

    assign bq_push = w_pop;
    assign bq_pop  = bout_active && s_axi_bready[bout_port];

    // bq can never overflow because m_axi_wvalid is gated on bq_full
    assign w_pop = w_active && m_axi_wvalid && m_axi_wready && m_axi_wlast;

    // ------------------------------------------------------------------
    //  Master-port outputs -- write channel
    // ------------------------------------------------------------------
    assign m_axi_awvalid = aw_push;
    assign m_axi_awaddr  = s_axi_awaddr[aw_gnt*32 +: 32];
    assign m_axi_awid    = s_axi_awid[aw_gnt*4 +: 4];
    assign m_axi_awlen   = 8'd0;
    assign m_axi_awsize  = 3'b100;         // 128-bit beat
    assign m_axi_awburst = 2'b01;          // INCR

    assign m_axi_wvalid  = w_active && !bq_full;
    assign m_axi_wdata   = s_axi_wdata[w_owner*128 +: 128];
    assign m_axi_wstrb   = s_axi_wstrb[w_owner*16 +: 16];
    assign m_axi_wlast   = w_active && s_axi_wlast[w_owner];

    assign m_axi_bready  = !bout_active && (bq_cnt > 0);

    assign s_axi_awready = aw_push ? (3'b001 << aw_gnt) : 3'b000;
    assign s_axi_wready  = (w_active && m_axi_wready && !bq_full)
                           ? (3'b001 << w_owner) : 3'b000;

    // ------------------------------------------------------------------
    //  B response routing
    // ------------------------------------------------------------------
    assign b_dest = (ROUTE_POLICY == 0) ? bq_port[bq_rp] : id_owner_w[m_axi_bid];

    assign s_axi_bvalid = bout_active ? (3'b001 << bout_port) : 3'b000;
    assign s_axi_bid    = bout_active ? ({8'h00, bout_id} << (bout_port*4)) : 12'h000;
    assign s_axi_bresp  = 6'h00;           // always OKAY in this model

    // ------------------------------------------------------------------
    //  Master-port outputs -- read channel
    // ------------------------------------------------------------------
    assign m_axi_arvalid = ar_push;
    assign m_axi_araddr  = s_axi_araddr[ar_gnt*32 +: 32];
    assign m_axi_arid    = s_axi_arid[ar_gnt*4 +: 4];
    assign m_axi_arlen   = 8'd0;
    assign m_axi_arsize  = 3'b100;
    assign m_axi_arburst = 2'b01;

    assign s_axi_arready = ar_push ? (3'b001 << ar_gnt) : 3'b000;

    assign m_axi_rready  = r_req_valid && !rout_active;

    assign r_dest = (ROUTE_POLICY == 0) ? r_req_port : id_owner_r[m_axi_rid];

    assign s_axi_rvalid = rout_active ? (3'b001 << rout_port) : 3'b000;
    assign s_axi_rid    = rout_active ? ({8'h00, rout_id} << (rout_port*4)) : 12'h000;
    assign s_axi_rdata  = rout_active ? ({256'h0, m_axi_rdata} << (rout_port*128))
                                     : 384'h0;
    assign s_axi_rresp  = 6'h00;
    assign s_axi_rlast  = rout_active ? (3'b001 << rout_port) : 3'b000;

    // ------------------------------------------------------------------
    //  Sequential -- write path
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aw_wp <= 2'd0; aw_rp <= 2'd0; aw_cnt <= 3'd0;
            bq_wp <= 2'd0; bq_rp <= 2'd0; bq_cnt <= 3'd0;
            w_active <= 1'b0; w_owner <= 2'd0;
            bout_active <= 1'b0; bout_port <= 2'd0; bout_id <= 4'd0;
            decode_err_aw <= 1'b0; aw_grant_count <= 32'd0;
            for (k = 0; k < 16; k = k + 1) id_owner_w[k] <= 2'd0;
        end else begin
            // ---- push a granted AW ----
            if (aw_push) begin
                aw_q_port[aw_wp] <= aw_gnt;
                aw_q_id[aw_wp]   <= s_axi_awid[aw_gnt*4 +: 4];
                aw_q_addr[aw_wp] <= s_axi_awaddr[aw_gnt*32 +: 32];
                aw_wp            <= aw_wp + 2'd1;
                id_owner_w[s_axi_awid[aw_gnt*4 +: 4]] <= aw_gnt;
                aw_grant_count   <= aw_grant_count + 32'd1;
                if (!in_window(s_axi_awaddr[aw_gnt*32 +: 32])) decode_err_aw <= 1'b1;
                if (VERBOSE)
                    $display("[IC] %0t  AW GRANT s%0d awid=0x%0h awaddr=0x%08h",
                             $time, aw_gnt, s_axi_awid[aw_gnt*4 +: 4],
                             s_axi_awaddr[aw_gnt*32 +: 32]);
            end
            aw_cnt <= aw_cnt + {2'b0, aw_push} - {2'b0, aw_pop};
            bq_cnt <= bq_cnt + {2'b0, bq_push} - {2'b0, bq_pop};

            // ---- run the W burst of the queue head ----
            if (!w_active && (aw_cnt > 0)) begin
                w_active <= 1'b1;
                w_owner  <= aw_q_port[aw_rp];
            end
            if (w_pop) begin
                w_active <= 1'b0;
                aw_rp    <= aw_rp + 2'd1;
                bq_port[bq_wp] <= w_owner;
                bq_id[bq_wp]   <= aw_q_id[aw_rp];
                bq_wp          <= bq_wp + 2'd1;
            end

            // ---- accept the downstream B, choose the destination ----
            if (m_axi_bvalid && m_axi_bready) begin
                bout_port   <= b_dest;
                bout_id     <= m_axi_bid;
                bout_active <= 1'b1;
                if (VERBOSE)
                    $display("[IC] %0t  B ROUTE  m_bid=0x%0h policy=%0d -> s%0d (queued port s%0d)",
                             $time, m_axi_bid, ROUTE_POLICY, b_dest, bq_port[bq_rp]);
            end

            // ---- drive B to the selected slave port ----
            if (bq_pop) begin
                bout_active <= 1'b0;
                bq_rp       <= bq_rp + 2'd1;
            end
        end
    end

    // ------------------------------------------------------------------
    //  Sequential -- read path
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ar_wp <= 2'd0; ar_rp <= 2'd0; ar_cnt <= 3'd0;
            r_req_valid <= 1'b0; r_req_port <= 2'd0; r_req_id <= 4'd0;
            rout_active <= 1'b0; rout_port <= 2'd0; rout_id <= 4'd0;
            decode_err_ar <= 1'b0; ar_grant_count <= 32'd0;
            for (k = 0; k < 16; k = k + 1) id_owner_r[k] <= 2'd0;
        end else begin
            // ---- push a granted AR ----
            if (ar_push) begin
                ar_q_port[ar_wp] <= ar_gnt;
                ar_q_id[ar_wp]   <= s_axi_arid[ar_gnt*4 +: 4];
                ar_q_addr[ar_wp] <= s_axi_araddr[ar_gnt*32 +: 32];
                ar_wp            <= ar_wp + 2'd1;
                id_owner_r[s_axi_arid[ar_gnt*4 +: 4]] <= ar_gnt;
                ar_grant_count   <= ar_grant_count + 32'd1;
                if (!in_window(s_axi_araddr[ar_gnt*32 +: 32])) decode_err_ar <= 1'b1;
                if (VERBOSE)
                    $display("[IC] %0t  AR GRANT s%0d arid=0x%0h araddr=0x%08h",
                             $time, ar_gnt, s_axi_arid[ar_gnt*4 +: 4],
                             s_axi_araddr[ar_gnt*32 +: 32]);
            end
            ar_cnt <= ar_cnt + {2'b0, ar_push} - {2'b0, ar_pop};

            // ---- move the AR queue head into the in-flight slot ----
            if (ar_pop) begin
                r_req_valid <= 1'b1;
                r_req_port  <= ar_q_port[ar_rp];
                r_req_id    <= ar_q_id[ar_rp];
                ar_rp       <= ar_rp + 2'd1;
            end

            // ---- accept the downstream R, choose the destination ----
            if (m_axi_rvalid && m_axi_rready) begin
                rout_port   <= r_dest;
                rout_id     <= m_axi_rid;
                rout_active <= 1'b1;
                if (VERBOSE)
                    $display("[IC] %0t  R ROUTE  m_rid=0x%0h policy=%0d -> s%0d (queued port s%0d)",
                             $time, m_axi_rid, ROUTE_POLICY, r_dest, r_req_port);
            end

            // ---- drive R to the selected slave port ----
            if (rout_active && s_axi_rready[rout_port]) begin
                rout_active <= 1'b0;
                r_req_valid <= 1'b0;
            end
        end
    end

endmodule
