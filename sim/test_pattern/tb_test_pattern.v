// ============================================================================
//  tb_test_pattern.v -- M0: 没有摄像头时自证 “测试图案 → checker0 → 写 DDR →
//                       读 DDR” 这条链路是通的
// ----------------------------------------------------------------------------
//  连接（与 rtl\mmt\mmt_top.v:706-728 的 checker0 例化同参数）：
//      mmt_test_pattern ──(o_vs/o_hs/o_de/o_vin + 自己的时钟)──▶ checker0
//      checker0 的 AXI 写口 ──▶ AXI 写从机模型（记录地址）
//      checker0 的 AXI 读口 ◀── AXI 读从机模型（回数据）
//
//  验证内容：
//    T1 图案时序：每行 de 拍数、每帧行数符合参数
//    T2 LINES_PER_FRAME / PIXELS_PER_LINE 计数（与将加入 soc_regs 的实现同源）
//    T3 checker0 真的产生 AXI 写，且**所有写地址都在 [0x02000000, 0x02BDDE00) 内**
//    T4 读出侧真的读到数据（R beats > 0）
//    T5 图案内容：RGGB 相位正确（纯红场 → 只有偶行偶列/奇行奇列 ... 见断言）
//
//  Vendor frame_buffer 从 %TEMP% 的 shim 副本编译（见 make_shim_src.ps1）。
// ============================================================================
`timescale 1ns/1ps

module tb_test_pattern;

    // ---- 图案几何（仿真用小尺寸；默认参数=真实 1920x1080）----
    localparam integer H_ACTIVE = 192;
    localparam integer V_ACTIVE = 32;
    localparam integer PPC      = 4;
    localparam integer H_ACT_CLK= H_ACTIVE/PPC;     // 48 de 拍/行
    localparam integer N_FRAMES = 6;
    localparam integer AXI_AW   = 32;
    localparam integer AXI_DW   = 128;
    localparam integer IDW      = 6;

    localparam [31:0] REGION_LO = 32'h02000000;
    localparam [31:0] REGION_HI = 32'h02BDDE00;     // 960x1080 版 3 bank 上界（工程约定）

    reg i_clk = 0, axi_clk = 0, o_clk = 0, rstn;
    always #5.0  i_clk   = ~i_clk;      // 图案/像素域 100 MHz
    always #5.0  axi_clk = ~axi_clk;    // AXI 100 MHz
    always #7.0  o_clk   = ~o_clk;      // 输出域 ~71 MHz

    // ---- 图案 ----
    reg  tp_en   = 1'b1;
    reg  [1:0] tp_mode = 2'd0;
    wire tp_vs, tp_hs, tp_de;
    wire [31:0] tp_vin;
    wire [15:0] tp_frame_cnt, tp_line_cnt, tp_pix_cnt;
    wire [15:0] tp_lpf, tp_ppl, tp_vfc;   // 模块自带的测量输出

    mmt_test_pattern #(
        .H_ACTIVE(H_ACTIVE), .V_ACTIVE(V_ACTIVE),
        .H_FRONT(8), .H_SYNC(1), .H_BACK(4),
        .V_FRONT(1), .V_SYNC(1), .V_BACK(2),
        .PPC(PPC), .SQ_W(32), .SQ_STEP(8)
    ) u_tp (
        .i_clk(i_clk), .i_rstn(rstn), .i_en(tp_en), .i_mode(tp_mode),
        .o_vs(tp_vs), .o_hs(tp_hs), .o_de(tp_de), .o_vin(tp_vin),
        .o_frame_cnt(tp_frame_cnt), .o_line_cnt(tp_line_cnt), .o_pix_cnt(tp_pix_cnt),
        // 测量输入接“多路选择后”的视频（这里 tp_en=1，选中的就是图案本身）
        .i_vid_de(tp_de & tp_hs), .i_vid_hs(tp_hs), .i_vid_vs(tp_vs),
        .o_lines_per_frame(tp_lpf), .o_pixels_per_line(tp_ppl), .o_vid_frame_cnt(tp_vfc)
    );

    // ---- 顶层“de & hs”的与法，原样保留 ----
    wire chk_de = tp_de & tp_hs;

    // ---- checker0 = frame_buffer（参数同 mmt_top.v:692-706）----
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
    assign bid = bid_r;   assign bvalid = bvalid_r;
    assign rid = rid_r;   assign rvalid = rvalid_r;
    assign rlast = rlast_r; assign rresp = rresp_r; assign rdata = rdata_r;

    wire o_hs_unused, o_vs_unused, o_de_unused;
    wire [15:0] vout_unused;

    frame_buffer #(
        .I_VID_WIDTH(32), .O_VID_WIDTH(16),
        .AXI_DATA_WIDTH(AXI_DW), .AXI_ADDR_WIDTH(AXI_AW),
        .WR_FIFO_DEPTH(1024), .RD_FIFO_DEPTH(512),
        .START_ADDR(32'h02000000), .BURST_LEN(127), .FB_NUM(3),
        .MAX_VID_WIDTH(960), .MAX_VID_HIGHT(1080)
    ) checker0 (
        .axi_clk(axi_clk), .rst_n(rstn),
        .i_clk(i_clk), .i_vs(tp_vs), .i_de(chk_de), .vin(tp_vin),
        .o_clk(o_clk), .o_hs(o_hs_unused), .o_vs(o_vs_unused),
        .o_de(o_de_unused), .vout(vout_unused),
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

    // ================= 图案侧计数（与将加入 soc_regs 的实现同源）=========
    reg  de_d, hs_d, vs_d;
    reg [15:0] pix_acc, lines_cur;
    reg [15:0] pixels_per_line, lines_per_frame;
    integer    de_total, line_cnt_tp, frame_cnt_tp;

    wire hs_rise = tp_hs & ~hs_d;
    wire vs_fall = ~tp_vs & vs_d;

    always @(posedge i_clk or negedge rstn) begin
        if (!rstn) begin
            de_d <= 0; hs_d <= 0; vs_d <= 0;
            pix_acc <= 16'd0; lines_cur <= 16'd0;
            pixels_per_line <= 16'd0; lines_per_frame <= 16'd0;
            de_total = 0; line_cnt_tp = 0; frame_cnt_tp = 0;
        end else begin
            de_d <= chk_de; hs_d <= tp_hs; vs_d <= tp_vs;
            if (chk_de) de_total = de_total + 1;
            if (hs_rise) begin
                line_cnt_tp = line_cnt_tp + 1;
                pixels_per_line <= pix_acc;          // 上一整行的 de 拍数
                pix_acc <= chk_de ? 16'd1 : 16'd0;
                if (tp_vs) lines_cur <= lines_cur + 16'd1;
            end else if (chk_de) begin
                pix_acc <= pix_acc + 16'd1;
            end
            if (vs_fall) begin
                frame_cnt_tp = frame_cnt_tp + 1;
                lines_per_frame <= lines_cur;
                lines_cur <= 16'd0;
            end
        end
    end

    // ================= AXI 写从机：记录地址、检查范围 =================
    integer aw_cnt, w_cnt, wlast_cnt, b_cnt, bad_addr_cnt;
    integer aw_max_cnt;              // 只打印前若干条
    reg [31:0] min_addr, max_addr;
    integer beat_in_burst, exp_beats, beat_mismatch;

    always @(posedge axi_clk or negedge rstn) begin
        if (!rstn) begin
            awready <= 1'b0;
            aw_cnt = 0; min_addr = 32'hFFFFFFFF; max_addr = 32'h0;
            bad_addr_cnt = 0; aw_max_cnt = 0;
        end else begin
            awready <= 1'b1;
            if (awvalid && awready) begin
                aw_cnt = aw_cnt + 1;
                if (awaddr < min_addr) min_addr = awaddr;
                if (awaddr > max_addr) max_addr = awaddr;
                exp_beats = awlen + 1;
                beat_in_burst = 0;
                if (awaddr < REGION_LO || awaddr >= REGION_HI) bad_addr_cnt = bad_addr_cnt + 1;
                if (aw_max_cnt < 8) begin
                    aw_max_cnt = aw_max_cnt + 1;
                    $display("[T3] AW #%0d t=%0t addr=0x%08h len=%0d  in_region=%0d",
                             aw_cnt, $time, awaddr, awlen,
                             (awaddr >= REGION_LO && awaddr < REGION_HI));
                end
            end
        end
    end

    always @(posedge axi_clk or negedge rstn) begin
        if (!rstn) begin
            wready <= 1'b0; w_cnt = 0; wlast_cnt = 0; b_cnt = 0; beat_mismatch = 0;
        end else begin
            wready <= 1'b1;
            if (wvalid && wready) begin
                w_cnt = w_cnt + 1;
                beat_in_burst = beat_in_burst + 1;
                if (wlast) begin
                    wlast_cnt = wlast_cnt + 1;
                    if (beat_in_burst != exp_beats) beat_mismatch = beat_mismatch + 1;
                    bvalid_r <= 1'b1; bid_r <= awid; b_cnt = b_cnt + 1;
                end
            end
            if (bvalid_r && bready) bvalid_r <= 1'b0;
        end
    end

    // ================= AXI 读从机：回数据 =================
    integer ar_cnt, r_cnt;
    reg [7:0] rd_left;
    reg [IDW-1:0] rd_id_r;
    always @(posedge axi_clk or negedge rstn) begin
        if (!rstn) begin
            arready <= 1'b0; rvalid_r <= 1'b0; rlast_r <= 1'b0;
            rd_left <= 8'd0; ar_cnt = 0; r_cnt = 0;
        end else begin
            arready <= 1'b1;
            if (arvalid && arready) begin
                ar_cnt = ar_cnt + 1;
                rd_id_r <= arid;
                rd_left <= arlen + 1;
            end
            if (rd_left != 8'd0 && !rvalid_r) begin
                rvalid_r <= 1'b1;
                rlast_r  <= (rd_left == 8'd1);
                rid_r    <= rd_id_r;
                rresp_r  <= 2'b00;
                rdata_r  <= {AXI_DW{1'b1}};
            end else if (rvalid_r && rready) begin
                rvalid_r <= 1'b0; rlast_r <= 1'b0;
                rd_left <= rd_left - 8'd1;
                r_cnt = r_cnt + 1;
            end
        end
    end

    // ================= 图案内容抽查（T5）=================
    // 纯红场模式的第 0 行：偶列应=红电平，奇列=0（G 位置）
    integer content_err;
    reg [7:0] sample_r_even, sample_r_odd;
    reg       got_sample;
    always @(posedge i_clk) begin
        if (rstn && tp_mode == 2'd1 && tp_de && tp_line_cnt == 16'd0 && !got_sample) begin
            sample_r_even = tp_vin[31:24];   // x=0（偶列）
            sample_r_odd  = tp_vin[23:16];   // x=1（奇列）
            got_sample = 1'b1;
            $display("[T5] mode=RED line0: vin[31:24](x=0,偶列)=%0d  vin[23:16](x=1,奇列)=%0d",
                     sample_r_even, sample_r_odd);
        end
    end

    // ---- 直接观测图案 vs 的边沿（判断 vs 是否每帧只有一个脉冲）----
    integer vs_rise, vs_fall_cnt;
    reg tvs_d;
    always @(posedge i_clk or negedge rstn) begin
        if (!rstn) begin
            tvs_d <= 0; vs_rise = 0; vs_fall_cnt = 0;
        end else begin
            tvs_d <= tp_vs;
            if (tp_vs && !tvs_d) begin
                vs_rise = vs_rise + 1;
                if (vs_rise <= 10)
                    $display("[VS] tp_vs RISE #%0d t=%0t  (u_tp.v_cnt=%0d)", vs_rise, $time, u_tp.v_cnt);
            end
            if (!tp_vs && tvs_d) begin
                vs_fall_cnt = vs_fall_cnt + 1;
                if (vs_fall_cnt <= 10)
                    $display("[VS] tp_vs FALL #%0d t=%0t  (u_tp.v_cnt=%0d)", vs_fall_cnt, $time, u_tp.v_cnt);
            end
        end
    end
    // ================= 写通路探针（诊断 T3a）=================
    integer fifo_wr_pulses, fs_rise_cnt, fstart_pulses, wfs_cnt, wfe_cnt, wrreq_cnt;
    reg fs_d, fstart_d, wfs_d, wfe_d;
    integer pcount;
    always @(posedge i_clk or negedge rstn) begin
        if (!rstn) begin
            fs_d <= 0; fstart_d <= 0; wfs_d <= 0; wfe_d <= 0;
            fifo_wr_pulses = 0; fs_rise_cnt = 0; fstart_pulses = 0;
            wfs_cnt = 0; wfe_cnt = 0; pcount = 0;
        end else begin
            fs_d <= checker0.frame_stable;
            fstart_d <= checker0.frame_start;
            wfs_d <= checker0.u_vid_rx_align.w_frame_start;
            wfe_d <= checker0.u_vid_rx_align.w_frame_end;
            if (checker0.frame_stable && !fs_d) begin
                fs_rise_cnt = fs_rise_cnt + 1;
                $display("[PROBE] t=%0t frame_stable RISES", $time);
            end
            if (checker0.frame_start && !fstart_d) fstart_pulses = fstart_pulses + 1;
            if (checker0.u_vid_rx_align.w_frame_start && !wfs_d) begin
                wfs_cnt = wfs_cnt + 1;
                $display("[PROBE] t=%0t w_frame_start PULSE #%0d  negtive_sync=%b frame_stable=%b",
                         $time, wfs_cnt, checker0.u_vid_rx_align.negtive_sync, checker0.frame_stable);
            end
            if (checker0.u_vid_rx_align.w_frame_end && !wfe_d) begin
                wfe_cnt = wfe_cnt + 1;
                $display("[PROBE] t=%0t w_frame_end   PULSE #%0d  frame_cnt=%0d",
                         $time, wfe_cnt, checker0.u_vid_rx_align.frame_cnt);
            end
            if (checker0.u_vid_rx_align.fifo_wr_en) fifo_wr_pulses = fifo_wr_pulses + 1;
            pcount = pcount + 1;
            if (pcount % 2000 == 0)
                $display("[PROBE] t=%0t periodic: negtive_sync=%b wfs_cnt=%0d wfe_cnt=%0d fstart=%0d fstable=%b fifo_wr=%0d",
                         $time, checker0.u_vid_rx_align.negtive_sync, wfs_cnt, wfe_cnt,
                         fstart_pulses, checker0.frame_stable, fifo_wr_pulses);
        end
    end

    always @(posedge axi_clk or negedge rstn) begin
        if (!rstn) wrreq_cnt = 0;
        else if (checker0.u_ddr_buffer.ddr_wr_buffer_inst.wr_req) begin
            if (wrreq_cnt < 4) begin
                wrreq_cnt = wrreq_cnt + 1;
                $display("[PROBE] t=%0t wr_req=1  rdusedw=%0d awlen=%0d state=%0d",
                         $time,
                         checker0.u_ddr_buffer.ddr_wr_buffer_inst.wr_fifo_rdusedw,
                         checker0.u_ddr_buffer.ddr_wr_buffer_inst.ddr_awlen,
                         checker0.u_ddr_buffer.ddr_wr_buffer_inst.state);
            end
        end
    end

    // ================= 主流程 =================
    integer fails, i;
    task chk(input [8*64-1:0] nm, input ok);
        begin
            if (ok) $display("[PASS] %0s", nm);
            else begin $display("[FAIL] %0s", nm); fails = fails + 1; end
        end
    endtask

    initial begin
        $timeformat(-9, 0, " ns", 0);
        rstn = 1'b0; fails = 0; got_sample = 1'b0; content_err = 0;
        awready <= 1'b0; wready <= 1'b0; bvalid_r <= 1'b0; bid_r <= 0;
        arready <= 1'b0; rvalid_r <= 1'b0; rlast_r <= 1'b0; rid_r <= 0;
        rresp_r <= 0; rdata_r <= 0;
        repeat (10) @(posedge i_clk);
        rstn = 1'b1;
        repeat (5) @(posedge i_clk);

        $display("================================================================");
        $display(" M0 test-pattern chain: pattern -> checker0 -> DDR write/read");
        $display(" geometry %0dx%0d, PPC=%0d -> %0d de/line, %0d lines/frame",
                 H_ACTIVE, V_ACTIVE, PPC, H_ACT_CLK, V_ACTIVE);
        $display(" checker0 START_ADDR=0x02000000  region=[0x%08h,0x%08h)", REGION_LO, REGION_HI);
        $display("================================================================");

        // ---- 先跑彩条模式（默认）----
        // ================= T5：先做纯红场 RGGB 相位抽查 =================
        // 先做、并用 i_en 脉冲把图案内部相位复位，这样"第一个 de"是确定的
        tp_mode = 2'd1;
        tp_en = 1'b0;
        repeat (5) @(posedge i_clk);
        tp_en = 1'b1;
        wait (tp_de);
        @(posedge i_clk);
        sample_r_even = tp_vin[31:24];   // 本拍第 0 个像素 → x = 4c+0（偶列）
        sample_r_odd  = tp_vin[23:16];   // 第 1 个像素     → x = 4c+1（奇列）
        $display("");
        $display("---- T5 纯红场 RGGB 相位抽查 ----");
        $display("[T5] mode=RED 首个 de：v_cnt=%0d  vin[31:24](x=0,偶列)=%0d  vin[23:16](x=1,奇列)=%0d  vin=%08h",
                 u_tp.v_cnt, sample_r_even, sample_r_odd, tp_vin);
        chk("T5a red field: even column (x=0) carries R level, odd column (x=1) is 0",
            (sample_r_even > 8'd200) && (sample_r_odd == 8'd0));

        // ================= 主测：彩条模式跑多帧 =================
        tp_mode = 2'd0;
        tp_en = 1'b0;
        repeat (5) @(posedge i_clk);
        tp_en = 1'b1;
        // 条件等待（而不是死等固定周期）：等到有足够多的 AW 突发，或超时
        begin : wait_writes
            integer guard;
            guard = 0;
            while ((aw_cnt < 8) && (guard < 400000)) begin
                @(posedge axi_clk);
                guard = guard + 1;
            end
            $display("[T3] wait loop: %0d axi cycles, aw_cnt=%0d", guard, aw_cnt);
        end
        repeat (2000) @(posedge axi_clk);

        $display("");
        $display("---- T1/T2 图案时序与计数 ----");
        $display("[T2] PIXELS_PER_LINE = %0d  (expect %0d)", pixels_per_line, H_ACT_CLK);
        $display("[T2] LINES_PER_FRAME = %0d  (expect %0d)", lines_per_frame, V_ACTIVE);
        $display("[T1] 图案输出观测: de_total=%0d line_events=%0d frame_events=%0d",
                 de_total, line_cnt_tp, frame_cnt_tp);

        $display("");
        $display("---- T3/T4 DDR 写读 ----");
        $display("[T3] AW handshakes = %0d   addr range 0x%08h .. 0x%08h", aw_cnt, min_addr, max_addr);
        $display("[T3] AW outside region = %0d", bad_addr_cnt);
        $display("[T3] W beats = %0d  wlast = %0d  B = %0d  burst beat mismatch = %0d",
                 w_cnt, wlast_cnt, b_cnt, beat_mismatch);
        $display("[T4] AR = %0d   R beats = %0d", ar_cnt, r_cnt);
        $display("================================================================");

        chk("T1 pattern drives de beats (de_total > 0)", de_total > 0);
        chk("T2a pixels_per_line == H_ACTIVE/PPC", pixels_per_line == H_ACT_CLK);
        chk("T2b lines_per_frame == V_ACTIVE", lines_per_frame == V_ACTIVE);
        chk("T3a checker0 produced AXI writes", aw_cnt > 0);
        chk("T3b every AW address inside [0x02000000,0x02BDDE00)", bad_addr_cnt == 0);
        chk("T3c burst beats match awlen+1", beat_mismatch == 0);
        chk("T4 read side returned data (R beats > 0)", r_cnt > 0);
        $display("[T6] 模块自带测量: lines_per_frame=%0d  pixels_per_line=%0d  vid_frame_cnt=%0d",
                 tp_lpf, tp_ppl, tp_vfc);
        chk("T6 module-measured LINES_PER_FRAME == V_ACTIVE", tp_lpf == V_ACTIVE);
        chk("T6 module-measured PIXELS_PER_LINE == H_ACTIVE/PPC", tp_ppl == H_ACT_CLK);

        $display("");
        if (fails == 0) $display("=== TEST_PATTERN RESULT: ALL CHECKS PASSED ===");
        else            $display("=== TEST_PATTERN RESULT: %0d CHECK(S) FAILED ===", fails);
        $finish;
    end

    initial begin
        #40000000;
        $display("[TB] *** GLOBAL TIMEOUT *** AW=%0d R=%0d", aw_cnt, r_cnt);
        $finish;
    end

endmodule
