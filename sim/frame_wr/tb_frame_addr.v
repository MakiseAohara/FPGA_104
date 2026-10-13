// ============================================================================
//  tb_frame_addr.v -- DDR write-address range investigation (task-21)
// ----------------------------------------------------------------------------
//  Question: for a realistic frame length, does the frame_buffer write address
//  stay inside the 3-bank video region [0x02000000, 0x02000000 + 3*FRAME_LEN)?
//
//  Same DUT/parameters as tb_frame_wr.v (copied from rtl\mmt\mmt_top.v:692-706),
//  but the synthetic frame geometry is compile-time configurable so a
//  realistic de-cycle count can be driven, and the write-address progression is
//  traced together with the internal bank-switch signals.
//
//  Defines:
//     H_ACTIVE_VAL / V_ACTIVE_VAL   pixels per line / lines per frame
//     N_FRAMES_VAL                  frames to drive
//     VS_MODE                       as in tb_frame_wr.v (1 = vs spans the frame)
// ============================================================================
`timescale 1ns/1ps

`ifndef VS_MODE
 `define VS_MODE 1
`endif
`ifndef H_ACTIVE_VAL
 `define H_ACTIVE_VAL 128
`endif
`ifndef V_ACTIVE_VAL
 `define V_ACTIVE_VAL 16
`endif
`ifndef N_FRAMES_VAL
 `define N_FRAMES_VAL 8
`endif

module tb_frame_addr;

    localparam integer H_ACTIVE = `H_ACTIVE_VAL;
    localparam integer V_ACTIVE = `V_ACTIVE_VAL;
    localparam integer N_FRAMES = `N_FRAMES_VAL;
    localparam integer H_BLANK  = 8;
    localparam integer V_BLANK  = 32;
    localparam integer AXI_AW   = 32;
    localparam integer AXI_DW   = 128;
    localparam integer IDW      = 6;

    // bank_switch.v:32  FRAME_LEN = MAX_VID_WIDTH*MAX_VID_HIGHT*VID_DATA_WIDTH/8 + 0x200
    // frame_buffer.v:181-189 例化 ddr_buffer 时是否转发 MAX_VID_WIDTH/MAX_VID_HIGHT,
    // 决定了 MAX_VID_* 取 960（转发）还是 1920（ddr_buffer.v:9-11 默认）。
    //
    // 注意：这里的 bank 基址只是"两种理论值"，**不是对当前 RTL 的断言**。
    // 实际用的是哪一组，由仿真中的 [RELOAD] 观测值判定（见结果段的
    // "observed bank bases"）。这样写死常量不会与实测自相矛盾。
    localparam integer FRAME_LEN_960  = 960*1080*32/8 + 512;     // 0x3F4A00  960x1080
    localparam integer FRAME_LEN_1920 = 1920*1080*32/8 + 512;    // 0x7E9200  1920x1080

    localparam [31:0]  REGION_LO     = 32'h02000000;
    localparam [31:0]  REGION_HI     = 32'h02000000 + 3*FRAME_LEN_960;   // 0x02BDDE00 (工程文档约定的 R5 尾)
    localparam [31:0]  REGION_HI_1920= 32'h02000000 + 3*FRAME_LEN_1920;  // 0x037BB600 (未转发时才会有的上界)

    // 理论 bank 基址（两组，供与观测值对照）
    localparam [31:0]  T960_B1  = 32'h02000000;
    localparam [31:0]  T960_B2  = 32'h02000000 + FRAME_LEN_960;          // 0x023F4A00
    localparam [31:0]  T960_B3  = 32'h02000000 + 2*FRAME_LEN_960;        // 0x027E9400
    localparam [31:0]  T1920_B1 = 32'h02000000;
    localparam [31:0]  T1920_B2 = 32'h02000000 + FRAME_LEN_1920;         // 0x027E9200
    localparam [31:0]  T1920_B3 = 32'h02000000 + 2*FRAME_LEN_1920;       // 0x02FD2400

    reg i_clk = 0, axi_clk = 0, o_clk = 0, rst_n;
    always #5.0 i_clk   = ~i_clk;
    always #5.0 axi_clk = ~axi_clk;
    always #7.0 o_clk   = ~o_clk;

    reg        i_vs = 0, i_de = 0;
    reg [31:0] vin  = 0;

    wire [IDW-1:0]      awid;
    wire [AXI_AW-1:0]   awaddr;
    wire [7:0]          awlen;
    wire [2:0]          awsize, awprot;
    wire [1:0]          awburst;
    wire [3:0]          awcache;
    wire                awlock, awvalid, awcobuf, awapcmd, awallstrb, awqos;
    wire [IDW-1:0]      arid;
    wire [AXI_AW-1:0]   araddr;
    wire [7:0]          arlen;
    wire [2:0]          arsize, arprot;
    wire [1:0]          arburst;
    wire [3:0]          arcache;
    wire                arlock, arvalid, arapcmd, arqos;
    wire [AXI_DW-1:0]   wdata;
    wire [AXI_DW/8-1:0] wstrb;
    wire                wlast, wvalid, rready, bready;
    wire [IDW-1:0]      rid;
    wire [AXI_DW-1:0]   rdata;
    wire                rlast, rvalid;
    wire [1:0]          rresp;
    wire [IDW-1:0]      bid;
    wire                bvalid;
    wire [31:0]         test_rd_fifo_rddata, test_wdata, test_rdata;

    reg                 awready, arready, wready;
    reg [IDW-1:0]       bid_r, rid_r;
    reg                 bvalid_r, rvalid_r, rlast_r;
    reg [1:0]           rresp_r;
    reg [AXI_DW-1:0]    rdata_r;

    assign bid = bid_r;  assign bvalid = bvalid_r;
    assign rid = rid_r;  assign rvalid = rvalid_r;
    assign rlast = rlast_r; assign rresp = rresp_r; assign rdata = rdata_r;

    frame_buffer #(
        .I_VID_WIDTH(32), .O_VID_WIDTH(16),
        .AXI_DATA_WIDTH(AXI_DW), .AXI_ADDR_WIDTH(AXI_AW),
        .WR_FIFO_DEPTH(1024), .RD_FIFO_DEPTH(512),
        .START_ADDR(32'h02000000), .BURST_LEN(127), .FB_NUM(3),
        .MAX_VID_WIDTH(960), .MAX_VID_HIGHT(1080)
    ) dut (
        .axi_clk(axi_clk), .rst_n(rst_n),
        .i_clk(i_clk), .i_vs(i_vs), .i_de(i_de), .vin(vin),
        .o_clk(o_clk), .o_hs(), .o_vs(), .o_de(), .vout(),
        .H_FRONT_PORCH(13'd60), .H_SYNC(13'd2), .H_VALID(13'd960),
        .H_BACK_PORCH(13'd44), .V_FRONT_PORCH(13'd20), .V_SYNC(13'd2),
        .V_VALID(13'd1080), .V_BACK_PORCH(13'd20),
        .awid(awid), .awaddr(awaddr), .awlen(awlen), .awsize(awsize),
        .awburst(awburst), .awcache(awcache), .awprot(awprot), .awlock(awlock),
        .awvalid(awvalid), .awcobuf(awcobuf), .awapcmd(awapcmd),
        .awallstrb(awallstrb), .awqos(awqos), .awready(awready),
        .arid(arid), .araddr(araddr), .arlen(arlen), .arsize(arsize),
        .arburst(arburst), .arlock(arlock), .arvalid(arvalid),
        .arapcmd(arapcmd), .arqos(arqos), .arready(arready),
        .arcache(arcache), .arprot(arprot),
        .wdata(wdata), .wstrb(wstrb), .wlast(wlast), .wvalid(wvalid), .wready(wready),
        .rid(rid), .rdata(rdata), .rlast(rlast), .rvalid(rvalid),
        .rready(rready), .rresp(rresp),
        .bid(bid), .bvalid(bvalid), .bready(bready),
        .test_rd_fifo_rddata(test_rd_fifo_rddata),
        .test_wdata(test_wdata), .test_rdata(test_rdata)
    );

    // convenience handles into the DUT
    wire [1:0]  wb_wr_bank   = dut.u_ddr_buffer.u_bank_sw.wr_bank;
    wire [1:0]  wb_rd_bank   = dut.u_ddr_buffer.u_bank_sw.rd_bank;
    wire [31:0] wb_wr_addr   = dut.u_ddr_buffer.u_bank_sw.wr_start_addr;
    wire [31:0] wb_rd_addr   = dut.u_ddr_buffer.u_bank_sw.rd_start_addr;
    wire        wb_pos_wr_sw = dut.u_ddr_buffer.u_bank_sw.three_fb.pos_wr_sw_en;
    wire        wb_pos_rd_sw = dut.u_ddr_buffer.u_bank_sw.three_fb.pos_rd_sw_en;
    wire        wb_wr_sw     = dut.u_ddr_buffer.ddr_wr_buffer_inst.bank_sw;
    wire        wb_rd_sw     = dut.u_ddr_buffer.ddr_rd_buffer_inst.bank_sw;
    wire        dbg_sync_r2  = dut.u_ddr_buffer.ddr_wr_buffer_inst.sync_r2;
    wire [31:0] dbg_start_addr_r = dut.u_ddr_buffer.ddr_wr_buffer_inst.start_addr_r;
    wire [31:0] dbg_ddr_wr_addr  = dut.u_ddr_buffer.ddr_wr_buffer_inst.ddr_wr_addr;
    wire [24:0] dbg_burst_num    = dut.u_ddr_buffer.ddr_wr_buffer_inst.burst_num;
    wire [24:0] dbg_total_burst  = dut.u_ddr_buffer.ddr_wr_buffer_inst.total_burst_num;
    wire        dbg_burst_last   = dut.u_ddr_buffer.ddr_wr_buffer_inst.burst_last;
    wire [7:0]  dbg_ddr_awlen    = dut.u_ddr_buffer.ddr_wr_buffer_inst.ddr_awlen;

    // ================= AXI write slave ==================================
    integer aw_cnt, w_cnt, wlast_cnt, b_cnt;
    integer aw_in_frame, burst_in_frame;
    reg [31:0] frame_min_addr, frame_max_addr;
    reg [31:0] global_min_addr, global_max_addr;
    reg [31:0] frame_first_addr, frame_last_addr;
    integer    frame_idx, reload_cnt, out_of_range_cnt, breach_cnt;
    reg [31:0] breach_addr;
    integer    trace_shown;
    reg        sync_r2_d;

    // observed bank bases (collected from [RELOAD] start_addr_r values)
    reg [31:0] obs_base [0:7];
    integer    obs_n, ci, k;
    reg        cdup;
    integer    wr_sw_cnt, rd_sw_cnt;
    reg        ok960, ok1920;

    // bank_switch internal state (for explaining the rotation order)
    wire        wb_dirt_en    = dut.u_ddr_buffer.u_bank_sw.three_fb.dirt_en;
    wire [1:0]  wb_dirt_bank  = dut.u_ddr_buffer.u_bank_sw.three_fb.dirt_bank;
    wire        wb_clean_en   = dut.u_ddr_buffer.u_bank_sw.three_fb.clean_en;
    wire [1:0]  wb_clean_bank = dut.u_ddr_buffer.u_bank_sw.three_fb.clean_bank;

    task do_reset_axi; begin
        awready <= 1'b0; wready <= 1'b0; bvalid_r <= 1'b0; bid_r <= 6'h0;
        arready <= 1'b0; rvalid_r <= 1'b0; rlast_r <= 1'b0; rid_r <= 6'h0;
        rresp_r <= 2'b00; rdata_r <= {AXI_DW{1'b0}};
    end endtask

    always @(posedge axi_clk or negedge rst_n) begin
        if (!rst_n) begin
            awready <= 1'b0;
        end else begin
            awready <= 1'b1;
            if (awvalid && awready) begin
                aw_cnt = aw_cnt + 1;
                aw_in_frame = aw_in_frame + 1;
                if (awaddr < frame_min_addr) frame_min_addr = awaddr;
                if (awaddr > frame_max_addr) frame_max_addr = awaddr;
                if (awaddr < global_min_addr) global_min_addr = awaddr;
                if (awaddr > global_max_addr) global_max_addr = awaddr;
                if (aw_in_frame == 1) frame_first_addr = awaddr;
                frame_last_addr = awaddr;

                // out-of-region detection
                if (awaddr >= REGION_HI) begin
                    out_of_range_cnt = out_of_range_cnt + 1;
                    if (breach_cnt == 0) breach_addr = awaddr;
                    breach_cnt = breach_cnt + 1;
                    if (breach_cnt <= 8)
                        $display("[BREACH] t=%0t AW #%0d addr=0x%08h >= REGION_HI 0x%08h",
                                 $time, aw_cnt, awaddr, REGION_HI);
                end

                if (trace_shown < 26) begin
                    trace_shown = trace_shown + 1;
                    $display("[AW] t=%0t #%0d addr=0x%08h len=%0d | start_addr_r=0x%08h wr_start=0x%08h wr_bank=%b bnum=%0d tot=%0d blast=%b wr_sw=%b rd_bank=%b",
                             $time, aw_cnt, awaddr, awlen,
                             dbg_start_addr_r, wb_wr_addr, wb_wr_bank,
                             dbg_burst_num, dbg_total_burst, dbg_burst_last,
                             wb_wr_sw, wb_rd_bank);
                end
            end
        end
    end

    always @(posedge axi_clk or negedge rst_n) begin
        if (!rst_n) begin
            wready <= 1'b0;
            w_cnt = 0; wlast_cnt = 0;
        end else begin
            wready <= 1'b1;
            if (wvalid && wready) begin
                w_cnt = w_cnt + 1;
                if (wlast) begin
                    wlast_cnt = wlast_cnt + 1;
                    bvalid_r <= 1'b1;
                    bid_r    <= awid;
                    b_cnt    = b_cnt + 1;
                end
            end
            if (bvalid_r && bready) bvalid_r <= 1'b0;
        end
    end

    // ================= AXI read slave ===================================
    integer ar_cnt, r_cnt;
    reg [7:0] rd_beats_left;
    reg [IDW-1:0] rd_id_r;

    always @(posedge axi_clk or negedge rst_n) begin
        if (!rst_n) begin
            arready <= 1'b0; rvalid_r <= 1'b0; rlast_r <= 1'b0;
            rd_beats_left <= 8'd0; ar_cnt = 0; r_cnt = 0;
        end else begin
            arready <= 1'b1;
            if (arvalid && arready) begin
                ar_cnt = ar_cnt + 1;
                rd_id_r <= arid;
                rd_beats_left <= arlen + 1;
            end
            if (rd_beats_left != 8'd0 && !rvalid_r) begin
                rvalid_r <= 1'b1; rlast_r <= (rd_beats_left == 8'd1);
                rid_r <= rd_id_r; rresp_r <= 2'b00; rdata_r <= {AXI_DW{1'b1}};
            end else if (rvalid_r && rready) begin
                rvalid_r <= 1'b0; rlast_r <= 1'b0;
                rd_beats_left <= rd_beats_left - 8'd1;
                r_cnt = r_cnt + 1;
            end
        end
    end

    // ================= frame boundary / reload trace ====================
    always @(posedge axi_clk or negedge rst_n) begin
        if (!rst_n) begin
            sync_r2_d <= 1'b0;
            frame_idx = 0; aw_in_frame = 0;
            frame_min_addr = 32'hFFFFFFFF; frame_max_addr = 32'h0;
        end else begin
            sync_r2_d <= dbg_sync_r2;
            if (dbg_sync_r2 && !sync_r2_d) begin
                // report the frame that just ended
                if (aw_in_frame > 0)
                    $display("[FRAME %0d] AW=%0d  addr range 0x%08h .. 0x%08h  (first 0x%08h last 0x%08h)",
                             frame_idx, aw_in_frame, frame_min_addr, frame_max_addr,
                             frame_first_addr, frame_last_addr);
                frame_idx = frame_idx + 1;
                aw_in_frame = 0; burst_in_frame = 0;
                frame_min_addr = 32'hFFFFFFFF; frame_max_addr = 32'h0;
                reload_cnt = reload_cnt + 1;
                $display("[RELOAD %0d] t=%0t sync_r2 -> ddr_wr_addr <= start_addr_r = 0x%08h  (wr_start=0x%08h wr_bank=%b)",
                         reload_cnt, $time, dbg_start_addr_r, wb_wr_addr, wb_wr_bank);
                // collect this bank base (distinct)
                cdup = 1'b0;
                for (ci = 0; ci < obs_n; ci = ci + 1)
                    if (obs_base[ci] == dbg_start_addr_r) cdup = 1'b1;
                if (!cdup && obs_n < 8) begin
                    obs_base[obs_n] = dbg_start_addr_r;
                    obs_n = obs_n + 1;
                end
            end
        end
    end

    // bank-switch event trace, with the bank_switch dirt/clean state that drove it
    always @(posedge axi_clk) begin
        if (rst_n) begin
            if (wb_pos_wr_sw) begin
                wr_sw_cnt = wr_sw_cnt + 1;
                $display("[SW-WR] t=%0t #%0d wr_bank=%b wr_start_addr=0x%08h | dirt_en=%b dirt_bank=%b clean_en=%b clean_bank=%b | rd_bank=%b wr_sw=%b rd_sw=%b",
                         $time, wr_sw_cnt, wb_wr_bank, wb_wr_addr,
                         wb_dirt_en, wb_dirt_bank, wb_clean_en, wb_clean_bank,
                         wb_rd_bank, wb_wr_sw, wb_rd_sw);
            end
            if (wb_pos_rd_sw) begin
                rd_sw_cnt = rd_sw_cnt + 1;
                $display("[SW-RD] t=%0t #%0d rd_bank=%b rd_start_addr=0x%08h | dirt_en=%b dirt_bank=%b clean_en=%b clean_bank=%b | wr_bank=%b",
                         $time, rd_sw_cnt, wb_rd_bank, wb_rd_addr,
                         wb_dirt_en, wb_dirt_bank, wb_clean_en, wb_clean_bank, wb_wr_bank);
            end
        end
    end

    // ================= stimulus =========================================
    integer fr, x, y, nlines;

    task drive_frame(input integer lines);
        integer yy, xx;
        begin
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
        end
    endtask

    integer fails;
    task chk(input [8*64-1:0] nm, input ok);
        begin
            if (ok) $display("[PASS] %0s", nm);
            else begin $display("[FAIL] %0s", nm); fails = fails + 1; end
        end
    endtask

    initial begin
        $timeformat(-9, 0, " ns", 0);
        rst_n = 1'b0; i_vs = 0; i_de = 0; vin = 0;
        aw_cnt = 0; w_cnt = 0; wlast_cnt = 0; b_cnt = 0;
        ar_cnt = 0; r_cnt = 0; fails = 0;
        aw_in_frame = 0; burst_in_frame = 0;
        frame_min_addr = 32'hFFFFFFFF; frame_max_addr = 32'h0;
        global_min_addr = 32'hFFFFFFFF; global_max_addr = 32'h0;
        frame_first_addr = 0; frame_last_addr = 0;
        frame_idx = 0; reload_cnt = 0;
        out_of_range_cnt = 0; breach_cnt = 0; breach_addr = 0;
        trace_shown = 0;
        obs_n = 0; wr_sw_cnt = 0; rd_sw_cnt = 0;
        for (ci = 0; ci < 8; ci = ci + 1) obs_base[ci] = 32'h0;
        do_reset_axi;

        repeat (20) @(posedge i_clk);
        rst_n = 1'b1;
        repeat (20) @(posedge i_clk);

        $display("================================================================");
        $display(" frame_buffer WRITE ADDRESS RANGE check");
        $display(" frame geometry: %0d lines x %0d pixels(de cycles) = %0d de/frame",
                 V_ACTIVE, H_ACTIVE, V_ACTIVE*H_ACTIVE);
        $display(" frames = %0d   VS_MODE=%0d", N_FRAMES, `VS_MODE);
        $display(" ----------------------------------------------------------------");
        $display(" documented 3-bank region (960x1080, project docs): [0x%08h , 0x%08h)",
                 REGION_LO, REGION_HI);
        $display(" span IF MAX_VID_* were NOT forwarded (1920x1080) : [0x%08h , 0x%08h)",
                 REGION_LO, REGION_HI_1920);
        $display(" theory bank bases 960x1080 : 0x%08h  0x%08h  0x%08h", T960_B1, T960_B2, T960_B3);
        $display(" theory bank bases 1920x1080: 0x%08h  0x%08h  0x%08h", T1920_B1, T1920_B2, T1920_B3);
        $display(" NOTE: bank bases above are THEORY only.  Which set the DUT actually");
        $display("       uses is reported below from the observed [RELOAD] values.");
        $display("================================================================");

        for (fr = 1; fr <= N_FRAMES; fr = fr + 1) begin
            nlines = V_ACTIVE;
            $display("[VID] t=%0t driving frame %0d (%0d lines)", $time, fr, nlines);
            drive_frame(nlines);
        end
        repeat (6000) @(posedge axi_clk);

        $display("");
        $display("=================== ADDRESS RESULT ===================");
        $display("de cycles/frame      = %0d", V_ACTIVE*H_ACTIVE);
        $display("expected ddr_frame_len = %0d words", (V_ACTIVE*H_ACTIVE*4+15)/16);
        $display("AW handshakes        = %0d   W beats = %0d   wlast = %0d   B = %0d",
                 aw_cnt, w_cnt, wlast_cnt, b_cnt);
        $display("address range        = 0x%08h .. 0x%08h", global_min_addr, global_max_addr);
        $display("documented region    = [0x%08h , 0x%08h)", REGION_LO, REGION_HI);
        $display("---- observed bank bases (distinct values of start_addr_r at [RELOAD]) ----");
        for (k = 0; k < obs_n; k = k + 1)
            $display("     obs_base[%0d] = 0x%08h", k, obs_base[k]);
        if (obs_n == 0) $display("     (none -- no frame ever started writing)");
        if (obs_n > 0) begin
            if (obs_base[obs_n-1] == T960_B1 || obs_base[obs_n-1] == T960_B2 || obs_base[obs_n-1] == T960_B3)
                $display("     => last observed base matches the 960x1080 theory set");
            else if (obs_base[obs_n-1] == T1920_B1 || obs_base[obs_n-1] == T1920_B2 || obs_base[obs_n-1] == T1920_B3)
                $display("     => last observed base matches the 1920x1080 theory set (MAX_VID_* NOT forwarded)");
            else
                $display("     => last observed base matches NEITHER theory set (unexpected)");
        end
        $display("bank switch events   : wr=%0d  rd=%0d", wr_sw_cnt, rd_sw_cnt);
        $display("rotation pacing      : the write bank only ADVANCES on a write switch that");
        $display("                       finds dirt_en=1, and dirt_en is re-armed only by a");
        $display("                       paired READ switch (bank_switch.v:131-156). So if the");
        $display("                       display side switches less often than the camera side,");
        $display("                       the write bank FREEZES between read switches.");
        if (wr_sw_cnt > rd_sw_cnt + 2) begin
            $display("[NOTE] in THIS stimulus wr_sw(%0d) >> rd_sw(%0d): the display side runs",
                     wr_sw_cnt, rd_sw_cnt);
            $display("       960x1080@o_clk timing while the camera side runs tiny synthetic");
            $display("       frames, so its bank switching is much rarer.  A frozen write bank");
            $display("       re-writes the SAME bank base every frame (no address runaway) --");
            $display("       this is a pacing property of the stimulus, not an address hazard.");
        end
        if (global_max_addr >= REGION_HI)
            $display("bytes of the 3rd bank BEYOND the documented region: 0x%0d (%0d MB)",
                     global_max_addr - REGION_HI, (global_max_addr - REGION_HI)/1048576);
        $display("AW beyond REGION_HI  = %0d", out_of_range_cnt);
        if (breach_cnt > 0)
            $display("first breach         = 0x%08h  (REGION_HI + 0x%0d)", breach_addr,
                     breach_addr - REGION_HI);
        $display("AR count             = %0d   R beats = %0d", ar_cnt, r_cnt);
        $display("======================================================");

        chk("A1 write path produced AW bursts", aw_cnt > 0);
        chk("A2 all AW addresses inside the 3-bank video region", out_of_range_cnt == 0);
        // every observed bank base must be consistent with one of the two theory sets
        ok960 = 1'b1; ok1920 = 1'b1;
        for (k = 0; k < obs_n; k = k + 1) begin
            if (!(obs_base[k] == T960_B1  || obs_base[k] == T960_B2  || obs_base[k] == T960_B3 ))
                ok960 = 1'b0;
            if (!(obs_base[k] == T1920_B1 || obs_base[k] == T1920_B2 || obs_base[k] == T1920_B3))
                ok1920 = 1'b0;
        end
        chk("A3 observed bank bases match the 960x1080 theory set",
            (obs_n > 0) && ok960);
        if ((obs_n > 0) && ok1920)
            $display("[NOTE] observed bases ALSO match the 1920x1080 set -- check frame_buffer.v parameter forwarding");

        if (out_of_range_cnt == 0)
            $display("=== ADDRESS RANGE: NO OVERFLOW ===");
        else
            $display("=== ADDRESS RANGE: OVERFLOW DETECTED (%0d AW beyond region) ===", out_of_range_cnt);
        $finish;
    end

    initial begin
        #600000000;
        $display("[TB] *** GLOBAL TIMEOUT ***  AW=%0d max=0x%08h", aw_cnt, global_max_addr);
        $finish;
    end

endmodule
