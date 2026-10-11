// ============================================================================
//  axi4_slave_model.v -- behavioural AXI4 slave (the DDR3 controller stand-in)
// ----------------------------------------------------------------------------
//  Requirements from task-2:
//    * configurable latency,
//    * several outstanding AW/AR accepted (pointer FIFOs),
//    * echoes the received ID back on B/R (m_axi_bid / m_axi_rid),
//    * a real memory behind it (CAM keyed by the full 32-bit address) so a
//      response delivered to the WRONG master is detectable by data compare,
//    * prints every accepted AW/AR with a timestamp -> this is how the
//      testbench measures the arbitration order on the downstream port.
//
//  Single-beat bursts only (awlen=arlen=0), which is all the BFMs issue.
//  Ready signals are combinational, as AXI permits.
//
//  This file is a TEST MODEL, not part of the synthesised design.
// ============================================================================
`timescale 1ns/1ps

module axi4_slave_model #(
    parameter DATA_W  = 128,
    parameter ADDR_W  = 32,
    parameter ID_W    = 4,
    parameter CAM_N   = 256,     // memory depth (distinct addresses)
    parameter BQ_D    = 4,
    parameter AQ_D    = 4,
    parameter B_LAT   = 2,       // cycles from W last beat to bvalid
    parameter R_LAT   = 3,       // cycles from AR accept to rvalid
    parameter VERBOSE = 1
)(
    input  wire                   clk,
    input  wire                   rst_n,

    input  wire  [ID_W-1:0]       s_awid,
    input  wire  [ADDR_W-1:0]     s_awaddr,
    input  wire  [7:0]            s_awlen,
    input  wire  [2:0]            s_awsize,
    input  wire  [1:0]            s_awburst,
    input  wire                   s_awvalid,
    output wire                   s_awready,

    input  wire  [DATA_W-1:0]     s_wdata,
    input  wire  [(DATA_W/8)-1:0] s_wstrb,
    input  wire                   s_wlast,
    input  wire                   s_wvalid,
    output wire                   s_wready,

    output reg                    s_bvalid,
    output reg   [ID_W-1:0]       s_bid,
    output reg   [1:0]            s_bresp,
    input  wire                   s_bready,

    input  wire  [ID_W-1:0]       s_arid,
    input  wire  [ADDR_W-1:0]     s_araddr,
    input  wire  [7:0]            s_arlen,
    input  wire  [2:0]            s_arsize,
    input  wire  [1:0]            s_arburst,
    input  wire                   s_arvalid,
    output wire                   s_arready,

    output reg                    s_rvalid,
    output reg   [ID_W-1:0]       s_rid,
    output reg   [DATA_W-1:0]     s_rdata,
    output reg   [1:0]            s_rresp,
    output reg                    s_rlast,
    input  wire                   s_rready,

    output reg   [31:0]           aw_accepted,
    output reg   [31:0]           ar_accepted,
    output reg   [31:0]           b_returned,
    output reg   [31:0]           r_returned
);

    // ---------------- write address FIFO ------------------------------------
    reg [ID_W-1:0]   awid_q   [0:AQ_D-1];
    reg [ADDR_W-1:0] awaddr_q [0:AQ_D-1];
    reg [1:0]        aw_wp, aw_rp;
    reg [2:0]        aw_cnt;

    // ---------------- read address FIFO -------------------------------------
    reg [ID_W-1:0]   arid_q   [0:AQ_D-1];
    reg [ADDR_W-1:0] araddr_q [0:AQ_D-1];
    reg [1:0]        ar_wp, ar_rp;
    reg [2:0]        ar_cnt;

    // ---------------- B service state ---------------------------------------
    reg              b_pending;
    reg [ID_W-1:0]   b_id_r;
    reg [15:0]       b_timer;

    // ---------------- R service state ---------------------------------------
    reg              r_pending;
    reg [15:0]       r_timer;
    reg [ID_W-1:0]   r_id_r;
    reg [ADDR_W-1:0] r_addr_r;

    // ---------------- memory (CAM keyed by full address) --------------------
    reg [ADDR_W-1:0] cam_tag  [0:CAM_N-1];
    reg [DATA_W-1:0] cam_data [0:CAM_N-1];
    reg              cam_v    [0:CAM_N-1];

    integer          i;
    integer          found;
    reg [DATA_W-1:0] rd_data;
    reg              rd_hit;

    // ---------------- combinational ready / handshake -----------------------
    assign s_awready = (aw_cnt < AQ_D);
    assign s_wready  = (aw_cnt > 0) && !b_pending;
    assign s_arready = (ar_cnt < AQ_D);

    wire aw_push = s_awready && s_awvalid;
    wire aw_pop  = s_wready  && s_wvalid && s_wlast;
    wire ar_push = s_arready && s_arvalid;
    wire ar_pop  = !r_pending && (ar_cnt > 0);

    // combinational read lookup for the in-flight read
    always @(*) begin
        rd_hit  = 1'b0;
        rd_data = {(DATA_W/32){r_addr_r ^ 32'hDEAD_BEEF}};
        for (i = 0; i < CAM_N; i = i + 1) begin
            if (cam_v[i] && (cam_tag[i] == r_addr_r)) begin
                rd_data = cam_data[i];
                rd_hit  = 1'b1;
            end
        end
        // rd_hit==0 -> deterministic per-address pattern, so an uninitialised
        // or WRONG address is immediately recognisable in the testbench
    end

    // ---------------- write path --------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aw_wp <= 2'd0; aw_rp <= 2'd0; aw_cnt <= 3'd0;
            s_bvalid <= 1'b0; s_bid <= {ID_W{1'b0}}; s_bresp <= 2'b00;
            b_pending <= 1'b0; b_id_r <= {ID_W{1'b0}}; b_timer <= 16'd0;
            aw_accepted <= 32'd0; b_returned <= 32'd0;
            // the CAM must be cleared explicitly: an X in cam_v would make
            // "!cam_v[i]" unknown and no entry would ever be allocated
            for (i = 0; i < CAM_N; i = i + 1) begin
                cam_v[i]    <= 1'b0;
                cam_tag[i]  <= {ADDR_W{1'b0}};
                cam_data[i] <= {DATA_W{1'b0}};
            end
        end else begin
            // ---- push a new AW ----
            if (aw_push) begin
                awid_q[aw_wp]   <= s_awid;
                awaddr_q[aw_wp] <= s_awaddr;
                aw_wp           <= aw_wp + 2'd1;
                aw_accepted     <= aw_accepted + 32'd1;
                if (VERBOSE)
                    $display("[SLAVE] %0t  AW ACCEPT  awid=0x%0h awaddr=0x%08h",
                             $time, s_awid, s_awaddr);
            end
            aw_cnt <= aw_cnt + {2'b0, aw_push} - {2'b0, aw_pop};

            // ---- W beat: commit into the CAM ----
            if (s_wready && s_wvalid) begin
                found = -1;
                for (i = 0; i < CAM_N; i = i + 1)
                    if ((found < 0) && cam_v[i] && (cam_tag[i] == awaddr_q[aw_rp]))
                        found = i;
                if (found < 0)
                    for (i = 0; i < CAM_N; i = i + 1)
                        if ((found < 0) && !cam_v[i]) found = i;
                if (found >= 0) begin
                    cam_tag[found]  = awaddr_q[aw_rp];
                    cam_data[found] = s_wdata;
                    cam_v[found]    = 1'b1;
                end
                if (VERBOSE)
                    $display("[SLAVE] %0t  W  COMMIT  addr=0x%08h data=0x%032h",
                             $time, awaddr_q[aw_rp], s_wdata);
                if (s_wlast) begin
                    b_id_r    <= awid_q[aw_rp];
                    b_pending <= 1'b1;
                    b_timer   <= B_LAT;
                    aw_rp     <= aw_rp + 2'd1;
                end
            end

            // ---- B response ----
            if (b_pending && !s_bvalid) begin
                if (b_timer == 0) begin
                    s_bvalid <= 1'b1;
                    s_bid    <= b_id_r;
                    s_bresp  <= 2'b00;
                    b_returned <= b_returned + 32'd1;
                    if (VERBOSE) $display("[SLAVE] %0t  B  DRIVE  bid=0x%0h", $time, b_id_r);
                end else begin
                    b_timer <= b_timer - 16'd1;
                end
            end
            if (s_bvalid && s_bready) begin
                s_bvalid  <= 1'b0;
                b_pending <= 1'b0;
            end
        end
    end

    // ---------------- read path ---------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ar_wp <= 2'd0; ar_rp <= 2'd0; ar_cnt <= 3'd0;
            s_rvalid <= 1'b0; s_rid <= {ID_W{1'b0}}; s_rdata <= {DATA_W{1'b0}};
            s_rresp <= 2'b00; s_rlast <= 1'b0;
            r_pending <= 1'b0; r_timer <= 16'd0;
            r_id_r <= {ID_W{1'b0}}; r_addr_r <= {ADDR_W{1'b0}};
            ar_accepted <= 32'd0; r_returned <= 32'd0;
        end else begin
            if (ar_push) begin
                arid_q[ar_wp]   <= s_arid;
                araddr_q[ar_wp] <= s_araddr;
                ar_wp           <= ar_wp + 2'd1;
                ar_accepted     <= ar_accepted + 32'd1;
                if (VERBOSE)
                    $display("[SLAVE] %0t  AR ACCEPT  arid=0x%0h araddr=0x%08h",
                             $time, s_arid, s_araddr);
            end

            if (ar_pop) begin
                r_id_r    <= arid_q[ar_rp];
                r_addr_r  <= araddr_q[ar_rp];
                ar_rp     <= ar_rp + 2'd1;
                r_pending <= 1'b1;
                r_timer   <= R_LAT;
            end
            ar_cnt <= ar_cnt + {2'b0, ar_push} - {2'b0, ar_pop};

            if (r_pending && !s_rvalid) begin
                if (r_timer == 0) begin
                    s_rvalid <= 1'b1;
                    s_rid    <= r_id_r;
                    s_rdata  <= rd_data;
                    s_rlast  <= 1'b1;
                    s_rresp  <= 2'b00;
                    r_returned <= r_returned + 32'd1;
                    if (VERBOSE)
                        $display("[SLAVE] %0t  R  DRIVE  rid=0x%0h rdata=0x%032h",
                                 $time, r_id_r, rd_data);
                end else begin
                    r_timer <= r_timer - 16'd1;
                end
            end
            if (s_rvalid && s_rready) begin
                s_rvalid  <= 1'b0;
                s_rlast   <= 1'b0;
                r_pending <= 1'b0;
            end
        end
    end

endmodule
