// ============================================================================
//  tb_frame_wr.v -- does the frame_buffer write path really produce DDR writes?
// ----------------------------------------------------------------------------
//  Instantiates the VENDOR frame_buffer exactly as rtl\mm\mmt_top.v:692-706
//  does (I_VID_WIDTH=32, O_VID_WIDTH=16, START_ADDR=0x02000000,
//  AXI_DATA_WIDTH=128, AXI_ADDR_WIDTH=32, BURST_LEN=127, FB_NUM=3,
//  WR_FIFO_DEPTH=1024, RD_FIFO_DEPTH=512, MAX_VID 960x1080), drives synthetic
//  video, and answers:
//     Q1  do frame_start / frame_stable ever assert?
//     Q2  does awvalid rise, with which address / burst length?
//     Q3  do wvalid / wlast appear, and does the write FIFO actually fill?
//     Q4  what happens when the frames are NOT the same length?
//
//  Compile-time switches (-D...):
//     VS_MODE = 1 : i_vs is high across the whole active frame  (default)
//     VS_MODE = 0 : i_vs is a short pulse inside the vertical blanking
//     UNEQUAL = 1 : alternate the frame length (negative control for Q4)
//
//  Clocks: i_clk = 100 MHz, axi_clk = 100 MHz, o_clk = ~71 MHz.
//  Build artefacts go to %TEMP%.
// ============================================================================
`timescale 1ns/1ps

`ifndef VS_MODE
 `define VS_MODE 1
`endif
`ifndef UNEQUAL
 `define UNEQUAL 0
`endif

module tb_frame_wr;

    // ---- sizing --------------------------------------------------------
    localparam integer H_ACTIVE = 128;      // pixels (32-bit words) per line
    localparam integer V_ACTIVE = 16;       // lines per frame
    localparam integer H_BLANK  = 8;        // i_clk cycles of de low between lines
    localparam integer V_BLANK  = 32;       // i_clk cycles between frames
    localparam integer N_FRAMES = 6;
    localparam integer AXI_AW   = 32;       // rtl\ddr3_controller\ddr3_parameter.vh:22
    localparam integer AXI_DW   = 128;      // rtl\ddr3_controller\ddr3_parameter.vh:23
    localparam integer IDW      = 6;

    // ---- clocks --------------------------------------------------------
    reg i_clk = 1'b0, axi_clk = 1'b0, o_clk = 1'b0;
    always #5.0 i_clk   = ~i_clk;       // 100 MHz
    always #5.0 axi_clk = ~axi_clk;     // 100 MHz
    always #7.0 o_clk   = ~o_clk;       // ~71 MHz

    reg rst_n;

    // ---- video stimulus ------------------------------------------------
    reg        i_vs = 1'b0, i_de = 1'b0;
    reg [31:0] vin  = 32'h0;

    // ---- DUT outputs ---------------------------------------------------
    wire [IDW-1:0]    awid;
    wire [AXI_AW-1:0] awaddr;
    wire [7:0]        awlen;
    wire [2:0]        awsize, awprot;
    wire [1:0]        awburst;
    wire [3:0]        awcache;
    wire              awlock, awvalid, awcobuf, awapcmd, awallstrb, awqos;
    wire [IDW-1:0]    arid;
    wire [AXI_AW-1:0] araddr;
    wire [7:0]        arlen;
    wire [2:0]        arsize, arprot;
    wire [1:0]        arburst;
    wire [3:0]        arcache;
    wire              arlock, arvalid, arapcmd, arqos;
    wire [AXI_DW-1:0] wdata;
    wire [AXI_DW/8-1:0] wstrb;
    wire              wlast, wvalid, rready, bready;
    wire [IDW-1:0]    rid;
    wire [AXI_DW-1:0] rdata;
    wire              rlast, rvalid;
    wire [1:0]        rresp;
    wire [IDW-1:0]    bid;
    wire              bvalid;
    wire [31:0]       test_rd_fifo_rddata, test_wdata, test_rdata;

    // ---- DUT inputs driven by the TB -----------------------------------
    reg               awready, arready, wready;
    reg [IDW-1:0]     bid_r, rid_r;
    reg               bvalid_r, rvalid_r, rlast_r;
    reg [1:0]         rresp_r;
    reg [AXI_DW-1:0]  rdata_r;

    assign bid     = bid_r;
    assign bvalid  = bvalid_r;
    assign rid     = rid_r;
    assign rvalid  = rvalid_r;
    assign rlast   = rlast_r;
    assign rresp   = rresp_r;
    assign rdata   = rdata_r;

    // ====================================================================
    //  DUT -- parameters copied from rtl\mm\mmt_top.v:692-706
    // ====================================================================
    frame_buffer #(
        .I_VID_WIDTH     (32),
        .O_VID_WIDTH     (16),
        .AXI_DATA_WIDTH  (AXI_DW),
        .AXI_ADDR_WIDTH  (AXI_AW),
        .WR_FIFO_DEPTH   (1024),
        .RD_FIFO_DEPTH   (512),
        .START_ADDR      (32'h02000000),
        .BURST_LEN       (127),
        .FB_NUM          (3),
        .MAX_VID_WIDTH   (960),
        .MAX_VID_HIGHT   (1080)
    ) dut (
        .axi_clk   (axi_clk),
        .rst_n     (rst_n),
        .i_clk     (i_clk),
        .i_vs      (i_vs),
        .i_de      (i_de),
        .vin       (vin),
        .o_clk     (o_clk),
        .o_hs      (),
        .o_vs      (),
        .o_de      (),
        .vout      (),
        // porches = mmt_top.v:721-728 with HSP=2 HBP=88 HFP=120 VSP=2 VBP=20 VFP=20
        .H_FRONT_PORCH (13'd60),   // HFP/2
        .H_SYNC        (13'd2),    // HSP
        .H_VALID       (13'd960),  // MAX_HRES/2
        .H_BACK_PORCH  (13'd44),   // HBP/2
        .V_FRONT_PORCH (13'd20),   // VFP
        .V_SYNC        (13'd2),    // VSP
        .V_VALID       (13'd1080), // MAX_VRES
        .V_BACK_PORCH  (13'd20),   // VBP
        // AXI write
        .awid(awid), .awaddr(awaddr), .awlen(awlen), .awsize(awsize),
        .awburst(awburst), .awcache(awcache), .awprot(awprot), .awlock(awlock),
        .awvalid(awvalid), .awcobuf(awcobuf), .awapcmd(awapcmd),
        .awallstrb(awallstrb), .awqos(awqos), .awready(awready),
        // AXI read
        .arid(arid), .araddr(araddr), .arlen(arlen), .arsize(arsize),
        .arburst(arburst), .arlock(arlock), .arvalid(arvalid),
        .arapcmd(arapcmd), .arqos(arqos), .arready(arready),
        .arcache(arcache), .arprot(arprot),
        .wdata(wdata), .wstrb(wstrb), .wlast(wlast), .wvalid(wvalid),
        .wready(wready),
        .rid(rid), .rdata(rdata), .rlast(rlast), .rvalid(rvalid),
        .rready(rready), .rresp(rresp),
        .bid(bid), .bvalid(bvalid), .bready(bready),
        .test_rd_fifo_rddata(test_rd_fifo_rddata),
        .test_wdata(test_wdata), .test_rdata(test_rdata)
    );

    // ====================================================================
    //  AXI write slave: accepts AW/W immediately, answers B
    // ====================================================================
    integer aw_cnt, w_cnt, wlast_cnt, b_cnt, err_beat_mismatch;
    integer aw_exp_beats, cur_beats;
    integer first_aw_time;
    reg [AXI_AW-1:0] first_aw_addr;
    reg [7:0]        first_aw_len;
    integer          max_fifo_used, min_fifo_used, fifo_full_cnt;
    reg              fifo_full_seen;

    task do_reset_axi; begin
        awready <= 1'b0; wready <= 1'b0;
        bvalid_r <= 1'b0; bid_r <= 6'h0;
        arready <= 1'b0;
        rvalid_r <= 1'b0; rlast_r <= 1'b0; rid_r <= 6'h0;
        rresp_r <= 2'b00; rdata_r <= {AXI_DW{1'b0}};
    end endtask

    // AW accept
    always @(posedge axi_clk or negedge rst_n) begin
        if (!rst_n) begin
            awready <= 1'b0;
        end else begin
            awready <= 1'b1;
            if (awvalid && awready) begin
                aw_cnt = aw_cnt + 1;
                aw_exp_beats = awlen + 1;
                cur_beats = 0;
                if (aw_cnt == 1) begin
                    first_aw_time = $time;
                    first_aw_addr = awaddr;
                    first_aw_len  = awlen;
                end
                if (aw_cnt <= 10)
                    $display("[AW]  t=%0t  #%0d  awaddr=0x%08h awlen=%0d awsize=%0d awburst=%0d awid=0x%0h",
                             $time, aw_cnt, awaddr, awlen, awsize, awburst, awid);
            end
        end
    end

    // W accept
    always @(posedge axi_clk or negedge rst_n) begin
        if (!rst_n) begin
            wready <= 1'b0;
            w_cnt = 0; wlast_cnt = 0;
        end else begin
            wready <= 1'b1;
            if (wvalid && wready) begin
                w_cnt  = w_cnt + 1;
                cur_beats = cur_beats + 1;
                if (wlast) begin
                    wlast_cnt = wlast_cnt + 1;
                    if (wlast_cnt <= 10)
                        $display("[W ]  t=%0t  burst #%0d finished: %0d beats (awlen gave %0d)",
                                 $time, wlast_cnt, cur_beats, aw_exp_beats);
                    if (cur_beats != aw_exp_beats) begin
                        err_beat_mismatch = err_beat_mismatch + 1;
                        $display("[ERR] t=%0t  burst #%0d had %0d beats but awlen+1 = %0d",
                                 $time, wlast_cnt, cur_beats, aw_exp_beats);
                    end
                    bvalid_r <= 1'b1;
                    bid_r    <= awid;
                    b_cnt    = b_cnt + 1;
                end
            end
            if (bvalid_r && bready) bvalid_r <= 1'b0;
        end
    end

    // FIFO observation (hierarchical into ddr_wr_buffer's DC_FIFO)
    always @(posedge axi_clk) begin
        if (rst_n) begin
            if (dut.u_ddr_buffer.ddr_wr_buffer_inst.wr_fifo_rdusedw > max_fifo_used)
                max_fifo_used = dut.u_ddr_buffer.ddr_wr_buffer_inst.wr_fifo_rdusedw;
            if (dut.u_ddr_buffer.ddr_wr_buffer_inst.wr_fifo_rdusedw < min_fifo_used)
                min_fifo_used = dut.u_ddr_buffer.ddr_wr_buffer_inst.wr_fifo_rdusedw;
            if (dut.u_ddr_buffer.ddr_wr_buffer_inst.wr_fifo_wrfull) begin
                fifo_full_cnt = fifo_full_cnt + 1;
                fifo_full_seen = 1'b1;
            end
        end
    end

    // ====================================================================
    //  AXI read slave: answers AR with data (keeps the read path from hanging)
    // ====================================================================
    integer ar_cnt, r_cnt;
    reg [7:0] rd_beats_left;
    reg [IDW-1:0] rd_id_r;

    always @(posedge axi_clk or negedge rst_n) begin
        if (!rst_n) begin
            arready <= 1'b0;
            rvalid_r <= 1'b0; rlast_r <= 1'b0;
            rd_beats_left <= 8'd0;
            ar_cnt = 0; r_cnt = 0;
        end else begin
            arready <= 1'b1;
            if (arvalid && arready) begin
                ar_cnt = ar_cnt + 1;
                rd_id_r <= arid;
                rd_beats_left <= arlen + 1;
                if (ar_cnt <= 5)
                    $display("[AR]  t=%0t  #%0d  araddr=0x%08h arlen=%0d", $time, ar_cnt, araddr, arlen);
            end
            if (rd_beats_left != 8'd0 && !rvalid_r) begin
                rvalid_r <= 1'b1;
                rlast_r  <= (rd_beats_left == 8'd1);
                rid_r    <= rd_id_r;
                rresp_r  <= 2'b00;
                rdata_r  <= {AXI_DW{1'b1}};
            end else if (rvalid_r && rready) begin
                rvalid_r <= 1'b0;
                rlast_r  <= 1'b0;
                rd_beats_left <= rd_beats_left - 8'd1;
                r_cnt = r_cnt + 1;
            end
        end
    end

    // ====================================================================
    //  Q1 monitors -- frame_start / frame_stable / frame_cnt
    // ====================================================================
    integer fstart_pulses, fstable_cnt, fend_cnt;
    reg fs_d, fst_d;
    integer fstable_time;

    always @(posedge i_clk) begin
        if (rst_n) begin
            fs_d  <= dut.frame_start;
            fst_d <= dut.frame_stable;
            if (dut.frame_start && !fs_d) begin
                fstart_pulses = fstart_pulses + 1;
                if (fstart_pulses <= 12)
                    $display("[Q1] t=%0t  frame_start PULSE #%0d (frame_cnt=%0d ddr_frame_len=%0d)",
                             $time, fstart_pulses, dut.frame_cnt, dut.ddr_frame_len);
            end
            if (dut.frame_stable && !fst_d) begin
                fstable_cnt = fstable_cnt + 1;
                if (fstable_cnt == 1) begin
                    fstable_time = $time;
                    $display("[Q1] t=%0t  frame_stable RISES (1st time)  frame_cnt=%0d ddr_frame_len=%0d",
                             $time, dut.frame_cnt, dut.ddr_frame_len);
                end
            end
            if (!dut.frame_stable && fst_d)
                $display("[Q1] t=%0t  frame_stable FALLS", $time);
        end
    end

    // ====================================================================
    //  debug probes into vid_rx_align / ser2par packer
    // ====================================================================
    integer wren_pulses, fstart_rise, fstart_fall, ps_changes;
    reg     fs_dbg_d;
    reg [4:0] ps_dbg;
    integer maxwrdnum;

    always @(posedge i_clk) begin
        if (rst_n) begin
            if (dut.wr_fifo_wren) wren_pulses = wren_pulses + 1;
            if (dut.frame_start && !fs_dbg_d) fstart_rise = fstart_rise + 1;
            if (!dut.frame_start && fs_dbg_d) fstart_fall = fstart_fall + 1;
            fs_dbg_d = dut.frame_start;

            if (dut.u_ddr_buffer.ddr_wr_buffer_inst.wr_fifo_wrusedw > maxwrdnum)
                maxwrdnum = dut.u_ddr_buffer.ddr_wr_buffer_inst.wr_fifo_wrusedw;

            if (dut.u_vid_rx_align.fifo_wr_en !== ps_dbg[0]) begin
                ps_changes = ps_changes + 1;
                if (ps_changes <= 16)
                    $display("[DBG] t=%0t vid_rx.fifo_wr_en %b->%b  frame_stable=%b frame_start=%b de=%b neg_sync=%b",
                             $time, ps_dbg[0], dut.u_vid_rx_align.fifo_wr_en,
                             dut.frame_stable, dut.frame_start, i_de,
                             dut.u_vid_rx_align.negtive_sync);
                ps_dbg[0] = dut.u_vid_rx_align.fifo_wr_en;
            end
            if (dut.u_ddr_buffer.ddr_wr_buffer_inst.state !== ps_dbg[4:2]) begin
                ps_changes = ps_changes + 1;
                if (ps_changes <= 16)
                    $display("[DBG] t=%0t wr_fsm state %0d->%0d  wr_req=%b rdusedw=%0d ddr_awlen=%0d awvalid=%b",
                             $time, ps_dbg[4:2], dut.u_ddr_buffer.ddr_wr_buffer_inst.state,
                             dut.u_ddr_buffer.ddr_wr_buffer_inst.wr_req,
                             dut.u_ddr_buffer.ddr_wr_buffer_inst.wr_fifo_rdusedw,
                             dut.u_ddr_buffer.ddr_wr_buffer_inst.ddr_awlen, awvalid);
                ps_dbg[4:2] = dut.u_ddr_buffer.ddr_wr_buffer_inst.state;
            end
        end
    end

    // ====================================================================
    // ---- focused FIFO probe: dump write-side signals in a window -------
    always @(posedge i_clk) begin
        if (rst_n && $time >= 67300 && $time <= 67900)
            $display("[FIFO] t=%0t WrEn=%b FWrEn=%b WrClkRst=%b RdClkRst=%b FifoWrAddr=%b WrRdAddr=%b WrWrAHex=%b WrRdAHex=%b WrDNum=%0d",
                     $time,
                     dut.u_ddr_buffer.ddr_wr_buffer_inst.u_wr_fifo.WrEn,
                     dut.u_ddr_buffer.ddr_wr_buffer_inst.u_wr_fifo.FifoWrEn,
                     dut.u_ddr_buffer.ddr_wr_buffer_inst.u_wr_fifo.WrClkRst,
                     dut.u_ddr_buffer.ddr_wr_buffer_inst.u_wr_fifo.RdClkRst,
                     dut.u_ddr_buffer.ddr_wr_buffer_inst.u_wr_fifo.FifoWrAddr,
                     dut.u_ddr_buffer.ddr_wr_buffer_inst.u_wr_fifo.WrRdAddr,
                     dut.u_ddr_buffer.ddr_wr_buffer_inst.u_wr_fifo.WrWrAHex,
                     dut.u_ddr_buffer.ddr_wr_buffer_inst.u_wr_fifo.WrRdAHex,
                     dut.u_ddr_buffer.ddr_wr_buffer_inst.u_wr_fifo.WrDNum);
    end

    //  video stimulus
    // ====================================================================
    integer fr, x, y, nlines;

    task drive_frame(input integer lines);
        integer yy, xx;
        begin
            if (`VS_MODE == 1) begin
                // vs high across the whole active frame
                @(negedge i_clk);
                i_vs = 1'b1;
                repeat (2) @(posedge i_clk);
                for (yy = 0; yy < lines; yy = yy + 1) begin
                    @(negedge i_clk);
                    i_de = 1'b1;
                    for (xx = 0; xx < H_ACTIVE; xx = xx + 1) begin
                        vin = {16'h0, yy[7:0], xx[7:0]};
                        @(negedge i_clk);
                    end
                    i_de = 1'b0;
                    repeat (H_BLANK) @(negedge i_clk);
                end
                repeat (2) @(negedge i_clk);
                i_vs = 1'b0;
                repeat (V_BLANK) @(negedge i_clk);
            end else begin
                // vs = short pulse in the vertical blanking, de low meanwhile
                @(negedge i_clk);
                i_vs = 1'b1;
                repeat (4) @(negedge i_clk);
                i_vs = 1'b0;
                repeat (6) @(negedge i_clk);
                for (yy = 0; yy < lines; yy = yy + 1) begin
                    @(negedge i_clk);
                    i_de = 1'b1;
                    for (xx = 0; xx < H_ACTIVE; xx = xx + 1) begin
                        vin = {16'h0, yy[7:0], xx[7:0]};
                        @(negedge i_clk);
                    end
                    i_de = 1'b0;
                    repeat (H_BLANK) @(negedge i_clk);
                end
                repeat (V_BLANK) @(negedge i_clk);
            end
        end
    endtask

    // ====================================================================
    //  main
    // ====================================================================
    integer fails;
    task chk(input [8*64-1:0] nm, input ok);
        begin
            if (ok) $display("[PASS] %0s", nm);
            else begin $display("[FAIL] %0s", nm); fails = fails + 1; end
        end
    endtask

    initial begin
        $timeformat(-9, 0, " ns", 0);
        rst_n = 1'b0;
        i_vs = 1'b0; i_de = 1'b0; vin = 32'h0;
        aw_cnt = 0; w_cnt = 0; wlast_cnt = 0; b_cnt = 0;
        ar_cnt = 0; r_cnt = 0;
        fstart_pulses = 0; fstable_cnt = 0; fend_cnt = 0; fstable_time = -1;
        first_aw_time = -1; first_aw_addr = 32'h0; first_aw_len = 8'h0;
        max_fifo_used = 0; min_fifo_used = 1000000; fifo_full_cnt = 0; fifo_full_seen = 1'b0;
        err_beat_mismatch = 0; fails = 0;
        wren_pulses = 0; fstart_rise = 0; fstart_fall = 0; ps_changes = 0;
        ps_dbg = 5'd0; fs_dbg_d = 1'b0; maxwrdnum = 0;
        do_reset_axi;

        repeat (20) @(posedge i_clk);
        rst_n = 1'b1;
        repeat (20) @(posedge i_clk);

        $display("================================================================");
        $display(" frame_buffer write-path test");
        $display(" VS_MODE=%0d  UNEQUAL=%0d  frames=%0d  lines/frame=%0d  pixels/line=%0d",
                 `VS_MODE, `UNEQUAL, N_FRAMES, V_ACTIVE, H_ACTIVE);
        $display(" => %0d de-cycles/frame = %0d bytes = %0d AXI 128-bit words",
                 V_ACTIVE*H_ACTIVE, V_ACTIVE*H_ACTIVE*4, (V_ACTIVE*H_ACTIVE*4)/16);
        $display("================================================================");

        for (fr = 1; fr <= N_FRAMES; fr = fr + 1) begin
            if (`UNEQUAL == 1)
                nlines = (fr % 2 == 1) ? V_ACTIVE : (V_ACTIVE - 4);
            else
                nlines = V_ACTIVE;
            $display("[VID] t=%0t  driving frame %0d with %0d lines", $time, fr, nlines);
            drive_frame(nlines);
        end

        // let the read/write engines drain
        repeat (4000) @(posedge axi_clk);

        $display("");
        $display("=================== RESULTS ===================");
        $display("Q1  frame_start pulses      = %0d", fstart_pulses);
        $display("Q1  frame_stable rising edges = %0d  (first at t=%0d)", fstable_cnt, fstable_time);
        $display("Q1  ddr_frame_len (last)    = %0d AXI words", dut.ddr_frame_len);
        $display("Q2  AW handshakes           = %0d", aw_cnt);
        if (aw_cnt > 0)
            $display("Q2  first AW: t=%0t addr=0x%08h len=%0d  (expected base 0x02000000)",
                     first_aw_time, first_aw_addr, first_aw_len);
        $display("Q3  W beats                 = %0d   wlast count = %0d", w_cnt, wlast_cnt);
        $display("Q3  B responses             = %0d", b_cnt);
        $display("Q3  write-FIFO wrusedw max=%0d  rdusedw max=%0d  wrfull=%0d (%0d clk)", maxwrdnum,
                 max_fifo_used, fifo_full_seen, fifo_full_cnt);
        $display("DBG wren_pulses=%0d  frame_start rise=%0d fall=%0d  pre_state changes=%0d", wren_pulses, fstart_rise, fstart_fall, ps_changes);
        $display("Q3  write-FIFO used: min=%0d max=%0d ; wrfull seen=%0d (%0d clocks)",
                 min_fifo_used, max_fifo_used, fifo_full_seen, fifo_full_cnt);
        $display("Q3  burst beat mismatch     = %0d", err_beat_mismatch);
        $display("    AR = %0d   R beats = %0d", ar_cnt, r_cnt);
        $display("===============================================");

        chk("Q1a frame_start pulses > 0", fstart_pulses > 0);
        chk("Q1b frame_stable asserts",    fstable_cnt > 0);
        chk("Q2a awvalid produces AW handshakes", aw_cnt > 0);
        chk("Q2b first AW address == 0x02000000", first_aw_addr == 32'h02000000);
        chk("Q3a wvalid produces W beats", w_cnt > 0);
        chk("Q3b bursts complete with wlast (trailing in-flight allowed)", (wlast_cnt > 0) && ((aw_cnt - wlast_cnt) <= 4));
        if (aw_cnt != wlast_cnt)
            $display("[NOTE] %0d AW burst(s) were still in flight when the video stopped (expected)",
                     aw_cnt - wlast_cnt);
        chk("Q3c no burst beat-count mismatch", err_beat_mismatch == 0);

        if (`UNEQUAL == 1)
            $display("[NOTE] UNEQUAL run: frame_stable asserted %0d time(s) -- see docs",
                     fstable_cnt);

        $display("");
        if (fails == 0) $display("=== FRAME_WR RESULT: ALL CHECKS PASSED ===");
        else           $display("=== FRAME_WR RESULT: %0d CHECK(S) FAILED ===", fails);
        $finish;
    end

    initial begin
        #40000000;
        $display("[TB] *** GLOBAL TIMEOUT ***");
        $display("[SUMMARY] AW=%0d W=%0d wlast=%0d frame_stable_cnt=%0d",
                 aw_cnt, w_cnt, wlast_cnt, fstable_cnt);
        $finish;
    end

endmodule
