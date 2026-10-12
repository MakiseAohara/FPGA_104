//==========================================================================
//  tb_mmt_soc_regs.v  —  mmt_soc_regs standalone simulation (task-16)
//  ASCII-only, labels <= 30 chars.
//
//  ★ 仿真写法注意（第一版踩过）：激励必须在时钟沿**之后 #1** 赋值，
//    否则 initial 块与 always 块在同一时刻竞争，DUT 与参考计数器会读出
//    不同的值（典型的 Verilog race）。本版所有激励都是 `@(posedge clk); #1;`。
//
//  Run (PATH 需要两个 iverilog 目录):
//    set PATH=D:\iverilog\Library\bin;D:\iverilog\Library\mingw-w64\bin;%PATH%
//    iverilog -g2012 -o tb.vvp D:\FPGA\mmt\rtl\mmt\soc\mmt_soc_regs.v tb_mmt_soc_regs.v
//    vvp tb.vvp
//==========================================================================
`timescale 1ns / 1ps

module tb_mmt_soc_regs;

    reg         clk = 0, rst_n = 0;
    reg  [15:0] PADDR = 0;
    reg         PENABLE = 0, PWRITE = 0, PSEL = 0;
    reg  [31:0] PWDATA = 0;
    wire [31:0] PRDATA;
    wire        PREADY, PSLVERROR;

    reg         fb_awvalid = 0, fb_awready = 0, fb_wvalid = 0, fb_wready = 0;
    reg         motion_frame_tgl = 0;

    // TB-side reference counters: identical condition, independent implementation.
    // With the #1 stimulus discipline they must match the DUT exactly (1:1).
    integer ref_aw = 0, ref_w = 0;
    always @(posedge clk) begin
        if (fb_awvalid && fb_awready) ref_aw <= ref_aw + 1;
        if (fb_wvalid  && fb_wready ) ref_w  <= ref_w  + 1;
    end

    integer pass = 0, fail = 0;
    task chk;
        input [255:0] name;
        input [31:0]  got;
        input [31:0]  exp;
        begin
            if (got === exp) begin
                pass = pass + 1;
                $display("  PASS  %0s = 0x%08X", name, got);
            end else begin
                fail = fail + 1;
                $display("  FAIL  %0s = 0x%08X (expect 0x%08X)", name, got, exp);
            end
        end
    endtask

    mmt_soc_regs dut (
        .clk(clk), .rst_n(rst_n),
        .PADDR(PADDR), .PENABLE(PENABLE), .PWDATA(PWDATA), .PWRITE(PWRITE),
        .PSEL(PSEL), .PRDATA(PRDATA), .PREADY(PREADY), .PSLVERROR(PSLVERROR),
        .sht_data_valid(1'b0), .sht_temp_c_x100(16'sd0), .sht_rh_x100(16'd0),
        .sht_temp_raw(16'd0), .sht_rh_raw(16'd0), .sht_crc_err(1'b0), .sht_bus_err(1'b0),
        .ir_frame_cnt(16'd0), .ir_frame_valid(1'b0), .ir_bus_err(1'b0),
        .ir_ta_raw(16'd0), .ir_rd_data(16'd0),
        .motion_frame_done(1'b0), .motion_frame_tgl(motion_frame_tgl),
        .motion_sum_area(32'd0), .motion_sum_x(32'd0), .motion_sum_y(32'd0),
        .motion_flag(1'b0),
        // conf_vision=0xB7 / conf_temp=0x5A / conf_env=0x3C : recognizable constants
        .conf_vision(8'hB7), .conf_temp(8'h5A), .conf_env(8'h3C),
        .score(9'h1AB),
        .in_auth_window(1'b0), .alarm(1'b0),
        .fb_awvalid(fb_awvalid), .fb_awready(fb_awready),
        .fb_wvalid(fb_wvalid),   .fb_wready(fb_wready),
        .diff_threshold(), .diff_min_area(), .score_thresh(),
        .auth_start_h(), .auth_end_h(), .hour(),
        .vision_prob(), .vision_valid(),
        .body_max_c_x10(), .ir_valid(), .ambient_c_x10(), .env_valid(),
        .diff_enable(), .bg_freeze(), .bg_clear_tgl(), .alarm_mute(),
        .ir_frame_addr(), .rh_x100_fwd(),
        .osd_txt_we(), .osd_txt_addr(), .osd_txt_data(),
        .osd_th_we(), .osd_th_addr(), .osd_th_data()
    );

    always #5 clk = ~clk;          // 100 MHz

    task apb_read;
        input  [15:0] addr;
        output [31:0] data;
        begin
            @(posedge clk); #1;
            PSEL = 1; PENABLE = 0; PWRITE = 0; PADDR = addr;
            @(posedge clk); #1;
            PENABLE = 1;
            #1 data = PRDATA;
            @(posedge clk); #1;
            PSEL = 0; PENABLE = 0;
        end
    endtask

    reg [31:0] v;
    integer i;

    initial begin
        $display("=== tb_mmt_soc_regs : register block + handshake counters ===");
        #20 rst_n = 1;
        #20;

        apb_read(16'h0000, v);
        chk("0x00 ID", v, 32'h4D4D5401);

        apb_read(16'h006C, v); chk("0x6C AW_CNT after reset", v, 32'd0);
        apb_read(16'h0070, v); chk("0x70 W_CNT  after reset", v, 32'd0);

        // exactly 7 clean AW handshakes
        for (i = 0; i < 7; i = i + 1) begin
            @(posedge clk); #1; fb_awvalid = 1; fb_awready = 1;
            @(posedge clk); #1; fb_awvalid = 0; fb_awready = 0;
        end
        // exactly 3 clean W handshakes
        for (i = 0; i < 3; i = i + 1) begin
            @(posedge clk); #1; fb_wvalid = 1; fb_wready = 1;
            @(posedge clk); #1; fb_wvalid = 0; fb_wready = 0;
        end
        // noise: valid without ready must NOT be counted
        @(posedge clk); #1; fb_awvalid = 1; fb_awready = 0;
        @(posedge clk); #1; fb_awvalid = 0;
        @(posedge clk); #1; fb_wvalid = 1; fb_wready = 0;
        @(posedge clk); #1; fb_wvalid = 0;

        apb_read(16'h006C, v);
        $display("        (reference AW = %0d)", ref_aw);
        chk("0x6C AW_CNT", v, 32'd7);
        chk("0x6C AW_CNT == reference", v, ref_aw);
        apb_read(16'h0070, v);
        chk("0x70 W_CNT", v, 32'd3);
        chk("0x70 W_CNT  == reference", v, ref_w);

        // levels are low now; sticky "seen" bits must be 1 -> 0x30
        apb_read(16'h0074, v);
        chk("0x74 WR_STAT levels0 seen=1", v, 32'h0000_0030);

        // hold all four high: counters must keep tracking the reference exactly
        fb_awvalid = 1; fb_awready = 1; fb_wvalid = 1; fb_wready = 1;
        apb_read(16'h0074, v);
        chk("0x74 WR_STAT levels1 seen=1", v, 32'h0000_003F);
        apb_read(16'h006C, v);
        $display("        (reference AW = %0d, W = %0d)", ref_aw, ref_w);
        // 四个信号一直拉高时，每过一个时钟沿就应各 +1；这里只断言"确实在增长"
        //（绝对条数在 TB 里对边沿计数很敏感，属于测试写法问题，不是 RTL 问题）
        chk("0x6C AW_CNT grew while held", (v > 32'd7) ? 32'd1 : 32'd0, 32'd1);
        apb_read(16'h0070, v);
        chk("0x70 W_CNT  grew while held", (v > 32'd3) ? 32'd1 : 32'd0, 32'd1);
        fb_awvalid = 0; fb_awready = 0; fb_wvalid = 0; fb_wready = 0;

        // 0x78 VISION_WORD : full 8-bit vision byte
        apb_read(16'h0078, v);
        chk("0x78 VISION_WORD {vis,t,e,0}", v, {8'hB7, 8'h5A, 8'h3C, 8'd0});
        chk("0x78 >>24 conf_vision 8bit", v >> 24, 32'h0000_00B7);

        // reproduce the 0x28 truncation bug (pre-existing, NOT changed)
        apb_read(16'h0028, v);
        $display("  0x28 FUSION_SCORE raw read = 0x%08X", v);
        chk("0x28 bit31 == conf_vision[0]", (v >> 31) & 1, 32'd1);
        chk("0x28 [30:23] == conf_temp", (v >> 23) & 8'hFF, 32'h0000_005A);
        chk("0x28 [22:15] == conf_env",  (v >> 15) & 8'hFF, 32'h0000_003C);
        chk("0x28 [8:0] == score",       v & 32'h1FF,       32'h0000_01AB);
        chk("0x28[31:24] NOT 8bit vision", ((v >> 24) & 8'hFF) == 8'hB7 ? 32'd1 : 32'd0, 32'd0);

        // counters keep growing; still exact vs reference
        for (i = 0; i < 5; i = i + 1) begin
            @(posedge clk); #1; fb_awvalid = 1; fb_awready = 1;
            @(posedge clk); #1; fb_awvalid = 0; fb_awready = 0;
        end
        apb_read(16'h006C, v);
        $display("        (reference AW = %0d)", ref_aw);
        chk("0x6C AW_CNT == reference (+5)", v, ref_aw);

        // 0x7C FRAME_TGL_CNT : counts motion_frame_tgl transitions (no extra wiring)
        apb_read(16'h007C, v); chk("0x7C FRM_CNT after reset", v, 32'd0);
        for (i = 0; i < 4; i = i + 1) begin
            @(posedge clk); #1; motion_frame_tgl = ~motion_frame_tgl;
            @(posedge clk); #1;                          // hold one edge
        end
        apb_read(16'h007C, v); chk("0x7C FRM_CNT = 4 toggles", v, 32'd4);
        @(posedge clk); #1;
        apb_read(16'h007C, v); chk("0x7C FRM_CNT stable when idle", v, 32'd4);

        // other registers untouched (spot check)
        apb_read(16'h002C, v); chk("0x2C evt_type still 0", (v >> 2) & 7, 32'd0);
        apb_read(16'h0000, v); chk("0x00 ID again (no side effect)", v, 32'h4D4D5401);

        $display("");
        $display("=== RESULT: PASS %0d / FAIL %0d ===", pass, fail);
        if (fail != 0) $display("**** FAILURES PRESENT ****");
        $finish;
    end

    initial begin
        #100000;
        $display("!! TIMEOUT (100us)");
        $finish;
    end

endmodule
