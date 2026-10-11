// ============================================================================
//  axi_master_bfm.v -- behavioural AXI4 master used by tb_axi_ic.v
// ----------------------------------------------------------------------------
//  One instance per interconnect slave port (s0/s1/s2).
//
//  It deliberately reproduces the ID handling of rtl/mm/mmt_top.v:
//    * the master NATIVELY owns an ID of ID_W bits (6 for frame_buffer,
//      8 for the SoC / TinyML),
//    * mmt_top.v slices it down to the interconnect's 4-bit ID
//      (mmt_top.v:768/795) and zero-extends the response ID back
//      (mmt_top.v:747/748/749/750),
//    * so this BFM drives axi_awid/axi_arid = cmd_id[3:0] and compares the
//      returned bid/rid against {0, cmd_id[3:0]} -- i.e. the value the master
//      would actually observe after the top-level zero extension.
//
//  Single outstanding transaction per instance: the FSM issues one AXI
//  transaction per cmd_start pulse and pulses cmd_done when the response
//  (B or last R beat) has been received.
//
//  This file is a TEST MODEL, not part of the synthesised design.
// ============================================================================
`timescale 1ns/1ps

module axi_master_bfm #(
    parameter ID_W    = 8,          // master-native ID width (6 or 8)
    parameter DATA_W  = 128,
    parameter ADDR_W  = 32,
    parameter MID     = 0,          // for messages
    parameter TIMEOUT = 4000        // clock cycles before giving up
)(
    input  wire                  clk,
    input  wire                  rst_n,

    // ---------------- command interface (driven by the testbench) ----------
    input  wire                  cmd_start,      // 1-cycle pulse
    input  wire                  cmd_is_write,   // 1 = write, 0 = read
    input  wire [ADDR_W-1:0]     cmd_addr,
    input  wire [ID_W-1:0]       cmd_id,         // the ID the master *intends*
    input  wire [DATA_W-1:0]     cmd_wdata,
    output reg                   cmd_done,       // 1-cycle pulse
    output reg                   cmd_err,        // sticky until next cmd_start
    output reg  [7:0]            cmd_err_code,
    output reg  [3:0]            cmd_resp_id,    // raw bid/rid seen from the IC
    output reg  [DATA_W-1:0]     cmd_rdata,

    // ---------------- AXI4 master port (IC side, 4-bit ID) ------------------
    output reg  [3:0]            axi_awid,
    output reg  [ADDR_W-1:0]     axi_awaddr,
    output reg  [7:0]            axi_awlen,
    output reg  [2:0]            axi_awsize,
    output reg  [1:0]            axi_awburst,
    output reg                   axi_awvalid,
    input  wire                  axi_awready,

    output reg  [DATA_W-1:0]     axi_wdata,
    output reg  [(DATA_W/8)-1:0] axi_wstrb,
    output reg                   axi_wlast,
    output reg                   axi_wvalid,
    input  wire                  axi_wready,

    output reg                   axi_bready,
    input  wire  [3:0]           axi_bid,
    input  wire  [1:0]           axi_bresp,
    input  wire                  axi_bvalid,

    output reg  [3:0]            axi_arid,
    output reg  [ADDR_W-1:0]     axi_araddr,
    output reg  [7:0]            axi_arlen,
    output reg  [2:0]            axi_arsize,
    output reg  [1:0]            axi_arburst,
    output reg                   axi_arvalid,
    input  wire                  axi_arready,

    output reg                   axi_rready,
    input  wire  [3:0]           axi_rid,
    input  wire  [DATA_W-1:0]    axi_rdata,
    input  wire  [1:0]           axi_rresp,
    input  wire                  axi_rvalid,
    input  wire                  axi_rlast
);

    // error code bits
    localparam E_BID  = 8'h01;
    localparam E_RID  = 8'h02;
    localparam E_BRSP = 8'h04;
    localparam E_RRSP = 8'h08;
    localparam E_TMO  = 8'h10;
    localparam E_TID  = 8'h20;   // ID lost by the 4-bit truncation at the top level

    localparam S_IDLE = 3'd0,
               S_AW   = 3'd1,
               S_W    = 3'd2,
               S_B    = 3'd3,
               S_AR   = 3'd4,
               S_R    = 3'd5,
               S_DONE = 3'd6;

    reg [2:0]  state;
    reg        is_write;
    reg [ADDR_W-1:0] lat_addr;
    reg [ID_W-1:0]   lat_id;
    reg [DATA_W-1:0] lat_wdata;
    integer    tcnt;

    // BFM is single-outstanding: at most one transaction in flight.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= S_IDLE;
            axi_awvalid   <= 1'b0;
            axi_wvalid    <= 1'b0;
            axi_arvalid   <= 1'b0;
            axi_bready    <= 1'b0;
            axi_rready    <= 1'b0;
            axi_awid      <= 4'h0;
            axi_arid      <= 4'h0;
            axi_awaddr    <= {ADDR_W{1'b0}};
            axi_araddr    <= {ADDR_W{1'b0}};
            axi_awlen     <= 8'd0;
            axi_arlen     <= 8'd0;
            axi_awsize    <= 3'b100;      // 16 bytes = 128-bit beat
            axi_arsize    <= 3'b100;
            axi_awburst   <= 2'b01;       // INCR
            axi_arburst   <= 2'b01;
            axi_wdata     <= {DATA_W{1'b0}};
            axi_wstrb     <= {(DATA_W/8){1'b1}};
            axi_wlast     <= 1'b0;
            cmd_done      <= 1'b0;
            cmd_err       <= 1'b0;
            cmd_err_code  <= 8'h00;
            cmd_resp_id   <= 4'h0;
            cmd_rdata     <= {DATA_W{1'b0}};
            tcnt          <= 0;
        end else begin
            cmd_done <= 1'b0;

            case (state)
            // -------------------------------------------------------------
            S_IDLE: begin
                axi_awvalid <= 1'b0;
                axi_wvalid  <= 1'b0;
                axi_arvalid <= 1'b0;
                axi_bready  <= 1'b0;
                axi_rready  <= 1'b0;
                if (cmd_start) begin
                    is_write     <= cmd_is_write;
                    lat_addr     <= cmd_addr;
                    lat_id       <= cmd_id;
                    lat_wdata    <= cmd_wdata;
                    cmd_err      <= 1'b0;
                    cmd_err_code <= 8'h00;
                    cmd_resp_id  <= 4'h0;
                    cmd_rdata    <= {DATA_W{1'b0}};
                    tcnt         <= 0;
                    axi_awid     <= cmd_id[3:0];    // <-- top-level truncation
                    axi_arid     <= cmd_id[3:0];    // <-- top-level truncation
                    axi_awaddr   <= cmd_addr;
                    axi_araddr   <= cmd_addr;
                    axi_wdata    <= cmd_wdata;
                    axi_wstrb    <= {(DATA_W/8){1'b1}};
                    axi_wlast    <= 1'b1;
                    state        <= cmd_is_write ? S_AW : S_AR;
                end
            end
            // -------------------------------------------------------------
            S_AW: begin
                axi_awvalid <= 1'b1;
                if (axi_awready) begin
                    axi_awvalid <= 1'b0;
                    state       <= S_W;
                end
            end
            // -------------------------------------------------------------
            S_W: begin
                axi_wvalid <= 1'b1;
                if (axi_wready) begin
                    axi_wvalid <= 1'b0;
                    state      <= S_B;
                end
            end
            // -------------------------------------------------------------
            S_B: begin
                axi_bready <= 1'b1;
                if (axi_bvalid) begin
                    axi_bready  <= 1'b0;
                    cmd_resp_id <= axi_bid;
                    // DUT fault: the response ID is not the one we drove
                    if (axi_bid !== lat_id[3:0]) begin
                        cmd_err      <= 1'b1;
                        cmd_err_code <= cmd_err_code | E_BID;
                        $display("[BFM%0d] %0t  BID MISMATCH: drove awid 0x%0h, got bid 0x%0h",
                                 MID, $time, lat_id[3:0], axi_bid);
                    end
                    // top-level wiring: bid is zero-extended back to the native
                    // width, so a native ID above 0xF can never round-trip
                    if ({{(ID_W-4){1'b0}}, axi_bid} !== lat_id) begin
                        cmd_err      <= 1'b1;
                        cmd_err_code <= cmd_err_code | E_TID;
                        $display("[BFM%0d] %0t  ID TRUNCATION LOSS on B: native id 0x%0h -> 4-bit 0x%0h -> zero-ext 0x%0h",
                                 MID, $time, lat_id, lat_id[3:0],
                                 {{(ID_W-4){1'b0}}, axi_bid});
                    end
                    if (axi_bresp !== 2'b00) begin
                        cmd_err      <= 1'b1;
                        cmd_err_code <= cmd_err_code | E_BRSP;
                    end
                    state <= S_DONE;
                end
            end
            // -------------------------------------------------------------
            S_AR: begin
                axi_arvalid <= 1'b1;
                if (axi_arready) begin
                    axi_arvalid <= 1'b0;
                    state       <= S_R;
                end
            end
            // -------------------------------------------------------------
            S_R: begin
                axi_rready <= 1'b1;
                if (axi_rvalid) begin
                    // DUT fault: response ID is not the one we drove
                    if (axi_rid !== lat_id[3:0]) begin
                        cmd_err      <= 1'b1;
                        cmd_err_code <= cmd_err_code | E_RID;
                        $display("[BFM%0d] %0t  RID MISMATCH: drove arid 0x%0h, got rid 0x%0h",
                                 MID, $time, lat_id[3:0], axi_rid);
                    end
                    // top-level wiring: truncation loss
                    if ({{(ID_W-4){1'b0}}, axi_rid} !== lat_id) begin
                        cmd_err      <= 1'b1;
                        cmd_err_code <= cmd_err_code | E_TID;
                        $display("[BFM%0d] %0t  ID TRUNCATION LOSS on R: native id 0x%0h -> 4-bit 0x%0h -> zero-ext 0x%0h",
                                 MID, $time, lat_id, lat_id[3:0],
                                 {{(ID_W-4){1'b0}}, axi_rid});
                    end
                    if (axi_rresp !== 2'b00) begin
                        cmd_err      <= 1'b1;
                        cmd_err_code <= cmd_err_code | E_RRSP;
                    end
                    cmd_resp_id <= axi_rid;
                    cmd_rdata   <= axi_rdata;
                    if (axi_rlast) begin
                        axi_rready <= 1'b0;
                        state      <= S_DONE;
                    end
                end
            end
            // -------------------------------------------------------------
            S_DONE: begin
                $display("[BFM%0d] %0t  DONE  errcode=0x%0h resp_id=0x%0h", MID, $time, cmd_err_code, cmd_resp_id);
                cmd_done <= 1'b1;
                state    <= S_IDLE;
            end
            default: state <= S_IDLE;
            endcase

            // ---- watchdog -------------------------------------------------
            if (state != S_IDLE && state != S_DONE) begin
                tcnt <= tcnt + 1;
                if (tcnt > TIMEOUT) begin
                    $display("[BFM%0d] %0t  *** TIMEOUT in state %0d (addr=0x%08h) -- no response ***",
                             MID, $time, state, lat_addr);
                    cmd_err      <= 1'b1;
                    cmd_err_code <= cmd_err_code | E_TMO;
                    axi_awvalid  <= 1'b0;
                    axi_wvalid   <= 1'b0;
                    axi_arvalid  <= 1'b0;
                    cmd_done     <= 1'b1;
                    state        <= S_IDLE;
                end
            end
        end
    end

endmodule
