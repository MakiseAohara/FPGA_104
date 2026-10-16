`timescale 1ns/100ps
// ddr_wr_buffer stand-alone testbench (DUT + its internal DC_FIFO only).
//   -DHOLD=<n>   wr_start high for n axi_clk cycles (0 = stay high forever)
//   -DPRE_FILL=1 fill write FIFO (to full) before wr_start (default 1)
//   -DTAG="..."  label printed in the log
`ifndef HOLD
 `define HOLD 1
`endif
`ifndef PRE_FILL
 `define PRE_FILL 1
`endif
`ifndef RUN_CYC
 `define RUN_CYC 600
`endif
module tb_ddr_wr_buf;
    localparam DW = 512, AW = 33;

    reg  axi_clk = 0, wrclk = 0, rst_n = 0;
    reg  wr_start = 0;
    reg  [AW-1:0] start_addr = 33'h000201900;   // same as ddr_buffer START_ADDR
    reg  [24:0]   burst_len  = 25'd200;         // 200 x 64B beats per "frame"
    reg  fifo_rst_p = 0, fifo_wren = 0;
    reg  [DW-1:0] fifo_wdata = 0;
    wire fifo_wrfull;

    // slave: most permissive
    wire awready = 1'b1, wready = 1'b1, bvalid = 1'b1;

    wire [5:0] awid; wire [AW-1:0] awaddr; wire [7:0] awlen; wire [2:0] awsize;
    wire [1:0] awburst; wire awlock, awvalid, awcobuf, awapcmd, awallstrb, awqos;
    wire [3:0] awcache; wire [2:0] awprot;
    wire [DW-1:0] wdata; wire [DW/8-1:0] wstrb; wire wlast, wvalid, bready;
    wire bank_sw; wire [7:0] test_cnt; wire [31:0] dbg_sb;

    ddr_wr_buffer #(.AXI_DATA_WIDTH(DW), .AXI_ADDR_WIDTH(AW), .WR_FIFO_DEPTH(1024), .BURST_LEN(15)) dut (
        .axi_clk(axi_clk), .rst_n(rst_n), .wr_start(wr_start),
        .start_addr(start_addr), .burst_len(burst_len),
        .bank_sw_ack(1'b0), .bank_sw(bank_sw), .test_cnt(test_cnt), .dbg_sb(dbg_sb),
        .wr_fifo_rst_p(fifo_rst_p), .wr_fifo_wrclk(wrclk), .wr_fifo_wren(fifo_wren),
        .wr_fifo_wrfull(fifo_wrfull), .wr_fifo_wrdata(fifo_wdata),
        .awid(awid), .awaddr(awaddr), .awlen(awlen), .awsize(awsize), .awburst(awburst),
        .awlock(awlock), .awvalid(awvalid), .awcobuf(awcobuf), .awapcmd(awapcmd),
        .awallstrb(awallstrb), .awqos(awqos), .awcache(awcache), .awprot(awprot),
        .awready(awready), .wdata(wdata), .wstrb(wstrb), .wlast(wlast), .wvalid(wvalid),
        .wready(wready), .bid(6'd0), .bvalid(bvalid), .bready(bready));

    always #5   axi_clk = ~axi_clk;   // 100 MHz
    always #3.7 wrclk   = ~wrclk;     // asynchronous write clock

    // fill: data = running counter
    integer wcnt = 0;
    always @(posedge wrclk) begin
        if (fifo_wren && !fifo_wrfull) begin
            wcnt <= wcnt + 1;
            fifo_wdata <= {16{32'h0}} | (wcnt + 1);
        end
    end

    integer cyc = 0;
    always @(posedge axi_clk) cyc <= cyc + 1;

    // ---- time-ordered change log (sampled just before each axi_clk rising edge) ----
    reg [255:0] last = 256'hx;
    wire [255:0] cur = { 8'd0, dut.sync_r0, dut.sync_r1, dut.sync_r2, dut.sync_r3,
                         dut.pos_sync, dut.start_sync, dut.state, dut.wr_req,
                         awvalid, awready, wvalid, wready, wlast, dut.ddr_awlen,
                         dut.wr_fifo_rdusedw, dut.wr_fifo_rden, wr_start };
    integer nchg = 0;
    always @(negedge axi_clk) begin
        if (rst_n && cur !== last) begin
            last <= cur;
            nchg = nchg + 1;
            if (nchg < 400)
            $display("[T %0t cyc %0d] sync_r0=%b r1=%b r2=%b r3=%b pos_sync=%b start_sync=%b state=%0d wr_req=%b awvalid=%b awready=%b wvalid=%b wready=%b wlast=%b awlen=%0d rdusedw=%0d rden=%b wr_start=%b",
                $time, cyc, dut.sync_r0, dut.sync_r1, dut.sync_r2, dut.sync_r3,
                dut.pos_sync, dut.start_sync, dut.state, dut.wr_req, awvalid, awready,
                wvalid, wready, wlast, dut.ddr_awlen, dut.wr_fifo_rdusedw, dut.wr_fifo_rden, wr_start);
        end
    end

    // ---- verdict counters ----
    integer n_aw = 0, n_wlast = 0, n_wbeat = 0, n_r2 = 0, n_r2_with_r0 = 0, n_r2_state0 = 0;
    integer max_state = 0, first_aw_cyc = -1, first_wlast_cyc = -1, first_r2_cyc = -1;
    integer n_r0_pulses = 0, n_pos = 0;
    reg r2_q = 0, r0_q = 0;
    always @(posedge axi_clk) if (rst_n) begin
        r2_q <= dut.sync_r2; r0_q <= dut.sync_r0;
        if (dut.sync_r2 && !r2_q) begin
            n_r2 = n_r2 + 1;
            if (first_r2_cyc < 0) first_r2_cyc = cyc;
        end
        if (dut.sync_r0 && !r0_q) n_r0_pulses = n_r0_pulses + 1;
        if (dut.pos_sync) n_pos = n_pos + 1;
        if (dut.sync_r2 && dut.sync_r0) n_r2_with_r0 = n_r2_with_r0 + 1;
        if (dut.sync_r2 && dut.state == 0) n_r2_state0 = n_r2_state0 + 1;
        if (dut.state > max_state) max_state = dut.state;
        if (awvalid && awready) begin
            n_aw = n_aw + 1;
            if (first_aw_cyc < 0) first_aw_cyc = cyc;
            $display("[AW] cyc %0d addr=0x%0h len=%0d", cyc, awaddr, awlen);
        end
        if (wvalid && wready) n_wbeat = n_wbeat + 1;
        if (wvalid && wready && wlast) begin
            n_wlast = n_wlast + 1;
            if (first_wlast_cyc < 0) first_wlast_cyc = cyc;
        end
    end
    reg ever_awvalid = 0, ever_wlast = 0;
    always @(posedge axi_clk) begin
        if (awvalid) ever_awvalid <= 1;
        if (wlast)   ever_wlast   <= 1;
    end

    integer i;
    initial begin
        $display("==== TAG=%s HOLD=%0d PRE_FILL=%0d ====", `TAG, `HOLD, `PRE_FILL);
        rst_n = 0; fifo_rst_p = 1;
        repeat (8) @(posedge axi_clk);
        @(negedge axi_clk) rst_n = 1;
        repeat (6) @(posedge axi_clk);
        @(negedge axi_clk) fifo_rst_p = 0;
        repeat (10) @(posedge axi_clk);
        // fill write FIFO until full
        if (`PRE_FILL) begin
            @(negedge wrclk) fifo_wren = 1;
            wait (fifo_wrfull);
            @(negedge wrclk) fifo_wren = 0;
            $display("[TB] FIFO full after %0d writes, cyc %0d", wcnt, cyc);
            repeat (10) @(posedge axi_clk);
        end
        $display("[TB] wr_start rises at cyc %0d, rdusedw=%0d", cyc, dut.wr_fifo_rdusedw);
        @(negedge axi_clk) wr_start = 1;
        if (`HOLD != 0) begin
            repeat (`HOLD) @(negedge axi_clk);
            wr_start = 0;
        end
        repeat (`RUN_CYC) @(posedge axi_clk);
        $display("---- SUMMARY ----");
        $display("max_state=%0d final_state=%0d", max_state, dut.state);
        $display("ever_awvalid=%b  AW handshakes=%0d  first_aw_cyc=%0d", ever_awvalid, n_aw, first_aw_cyc);
        $display("ever_wlast=%b  wlast handshakes=%0d  W beats=%0d  first_wlast_cyc=%0d", ever_wlast, n_wlast, n_wbeat, first_wlast_cyc);
        $display("pos_sync cycles=%0d  sync_r0 rises=%0d  sync_r2 rises=%0d (first cyc %0d)", n_pos, n_r0_pulses, n_r2, first_r2_cyc);
        $display("cycles with sync_r2&sync_r0 both high=%0d ; sync_r2 while state==0 = %0d", n_r2_with_r0, n_r2_state0);
        $display("final: rdusedw=%0d wr_req=%b sync_r0_cnt=%0d sync_r2_cnt=%0d pos_sync_cnt=%0d sb_preempt=%b",
                 dut.wr_fifo_rdusedw, dut.wr_req, dut.sync_r0_cnt, dut.sync_r2_cnt, dut.pos_sync_cnt, dut.sb_preempt);
        $finish;
    end
    initial begin #2000000; $display("[TB] WATCHDOG timeout"); $finish; end
endmodule
