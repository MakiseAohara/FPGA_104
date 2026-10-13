//==========================================================================
//  tb_mmt_cam_probe.v  —  task-19 验证（ASCII-only，标签 ≤ 30 字符）
//--------------------------------------------------------------------------
//  验两组东西：
//    A) mmt_cam_probe 单元：4 个时钟域的跳变计数 / 时钟探针 / 粘滞位 / CSI 状态字
//       · 源域信号精确跳变 N 次 ⇒ core_clk 侧读到的计数必须正好是 N
//       · 时钟探针：时钟停掉后计数必须不再增长
//    B) mmt_soc_regs 的探针读口：0x80..0xA4 必须把 raddr 映射到 0..9，
//       并返回 cam_probe_rdata；区间外仍返回 0（既有行为不变）
//
//  Run（PATH 需要两个 iverilog 目录）:
//    set PATH=D:\iverilog\Library\bin;D:\iverilog\Library\mingw-w64\bin;%PATH%
//    iverilog -g2012 -o tb.vvp ^
//        D:\FPGA\mmt\rtl\mmt\common\mmt_sync2.v ^
//        D:\FPGA\mmt\rtl\mmt\mmt_cam_probe.v ^
//        D:\FPGA\mmt\rtl\mmt\soc\mmt_soc_regs.v tb_mmt_cam_probe.v
//    vvp tb.vvp
//==========================================================================
`timescale 1ns / 1ps

module tb_mmt_cam_probe;

    //==========================================================
    //  公共时钟：core_clk 100MHz、clk_5m 5MHz、clk_byte 100MHz、clk_pixel ~74MHz
    //==========================================================
    reg clk       = 0;
    reg clk_5m    = 0;
    reg clk_byte  = 0;
    reg pclk_en   = 1;
    reg clk_pixel = 0;
    // ★ clk_5m 故意"迟到"：复位释放之后才让它开始跑 —— 复现"某个域的时钟晚于复位才来"
    //   这个真实场景（摄像头时钟 lane 没锁定时就是这样）。探针必须在这种情形下
    //   仍能正常计数（否则会把"后来来了"误报成"一直没动"）。
    reg clk_5m_en = 0;

    always #5  clk      = ~clk;             // 100 MHz
    always #100 if (clk_5m_en) clk_5m = ~clk_5m;   //   5 MHz（可延迟启动 / 可停）
    always #5  clk_byte = ~clk_byte;        // 100 MHz
    always #7  if (pclk_en) clk_pixel = ~clk_pixel;   // ~71 MHz（可停）

    reg rst_n = 0;

    // 待观察信号
    reg cam_scl = 0, csi_de = 0, csi_hs = 0, csi_vs = 0;
    reg [15:0] csi_word_count   = 16'h0000;
    reg [5:0]  csi_datatype     = 6'h00;
    reg [1:0]  csi_vc           = 2'd0;
    reg [3:0]  csi_pixel_per_clk= 4'd0;
    reg [3:0]  csi_fifo_rd_empty= 4'h0;
    reg        csi_irq          = 1'b0;
    // ---- task-24 追加的待观察信号 ----
    reg        cam_sda          = 1'b1;              // I2C SDA（高 = 空闲）
    reg [63:0] csi_pixel_data   = 64'd0;            // 像素数据（判数据有效性）
    reg        pix_rstn         = 1'b0;             // 像素域复位（稍后释放）
    reg        hs_ck_ena = 0, hs_d0_ena = 0, hs_d1_ena = 0, hs_d2_ena = 0, hs_d3_ena = 0;

    wire [31:0] probe_rdata;
    reg  [3:0]  probe_raddr = 4'd0;

    mmt_cam_probe dut_probe (
        .clk(clk), .rst_n(rst_n),
        .clk_5m(clk_5m), .clk_byte(clk_byte), .clk_pixel(clk_pixel),
        .cam_scl(cam_scl),
        .cam_sda(cam_sda),
        .csi_de(csi_de), .csi_hs(csi_hs), .csi_vs(csi_vs),
        .csi_pixel_data(csi_pixel_data),
        .pix_rstn(pix_rstn),
        .hs_ck_ena(hs_ck_ena), .hs_d0_ena(hs_d0_ena), .hs_d1_ena(hs_d1_ena),
        .hs_d2_ena(hs_d2_ena), .hs_d3_ena(hs_d3_ena),
        .csi_word_count(csi_word_count),
        .csi_datatype(csi_datatype),
        .csi_vc(csi_vc),
        .csi_pixel_per_clk(csi_pixel_per_clk),
        .csi_fifo_rd_empty(csi_fifo_rd_empty),
        .csi_irq(csi_irq),
        .raddr(probe_raddr),
        .rdata(probe_rdata)
    );

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

    task chk_ge;                          // got >= min
        input [255:0] name;
        input [31:0]  got;
        input [31:0]  min;
        begin
            if (got >= min) begin
                pass = pass + 1;
                $display("  PASS  %0s = 0x%08X (>= 0x%08X)", name, got, min);
            end else begin
                fail = fail + 1;
                $display("  FAIL  %0s = 0x%08X (< 0x%08X)", name, got, min);
            end
        end
    endtask

    // 在指定时钟域里把某个信号翻转 n 次（每次之间留够间隔，保证 core_clk 能采到）
    integer i;
    task toggle_scl; input integer n; integer k;
        begin for (k = 0; k < n; k = k + 1) begin
            @(posedge clk_5m); #1; cam_scl = ~cam_scl;
            repeat (20) @(posedge clk_5m);
        end end
    endtask
    task toggle_pix_sig; input integer n; integer k;
        begin for (k = 0; k < n; k = k + 1) begin
            @(posedge clk_pixel); #1; csi_de = ~csi_de;
            repeat (128) @(posedge clk_pixel);
        end end
    endtask
    task toggle_hs; input integer n; integer k;
        begin for (k = 0; k < n; k = k + 1) begin
            @(posedge clk_pixel); #1; csi_hs = ~csi_hs;
            repeat (128) @(posedge clk_pixel);
        end end
    endtask
    task toggle_vs; input integer n; integer k;
        begin for (k = 0; k < n; k = k + 1) begin
            @(posedge clk_pixel); #1; csi_vs = ~csi_vs;
            repeat (128) @(posedge clk_pixel);
        end end
    endtask
    task word_count_bump; input integer n; integer k;
        begin for (k = 0; k < n; k = k + 1) begin
            @(posedge clk_pixel); #1; csi_word_count = csi_word_count + 16'd1;
            repeat (64) @(posedge clk_pixel);
        end end
    endtask

    // ---- I2C 激励（慢速；SCL 端口用 **OE 语义**：1 = SCL 被拉低）----
    //   一个字节 = 8 个数据脉冲 + 第 9 个脉冲（ACK 槽）
    task i2c_start;
        begin
            cam_scl = 0; cam_sda = 1; #1200;   // 空闲：SCL 高、SDA 高
            cam_sda = 0; #1200;                // START：SCL 高时 SDA 下降 ⇒ 监视器复位位计数
            cam_scl = 1; #1200;                // SCL 拉低
        end
    endtask

    task i2c_byte;
        input ack_bit;
        integer b;
        begin
            for (b = 0; b < 8; b = b + 1) begin
                cam_sda = b[0]; #600;              // SCL 低时摆数据位
                cam_scl = 0; #1200;                // SCL 高 = 第 b+1 个上升沿
                cam_scl = 1; #600;                 // SCL 落回低
            end
            cam_sda = ack_bit ? 1'b0 : 1'b1; #600; // ACK 槽：SCL 低时摆 SDA
            cam_scl = 0; #1200;                    // 第 9 个上升沿 = ACK 槽（高电平期间被采样）
            cam_scl = 1; #600;
        end
    endtask

    task i2c_scl_low;
        begin cam_scl = 1; #1200; end          // 保持 SDA 不动
    endtask

    reg [31:0] v, ck_a, pk_a;

    //==========================================================
    //  A) 探针单元测试
    //==========================================================
    initial begin
        $display("=== A) mmt_cam_probe standalone ===");
        #50 rst_n = 1;
        repeat (5) @(posedge clk);

        // --- 复位后全 0 ---
        probe_raddr = 4'd0; #1; chk("A1 0x80 SCL_CNT after reset", probe_rdata, 32'd0);
        probe_raddr = 4'd3; #1; chk("A2 0x8C DE_CNT  after reset", probe_rdata, 32'd0);
        probe_raddr = 4'd6; #1; chk("A3 0x98 ST after reset (mask SDA level bit13)", probe_rdata & 32'h1FFF, 32'd0);

        // --- ★ 关键回归：clk_5m 此刻还没开始跑（复位已释放） ----
        //     就是要证明"源域时钟迟到"不会把探针卡死在 0。
        repeat (20) @(posedge clk);
        $display("        (clk_5m still disabled; rst_n released at t=50)");
        probe_raddr = 4'd0; #1;
        chk("A3b 0x80 SCL_CNT with clk_5m absent", probe_rdata, 32'd0);
        clk_5m_en = 1;                       // 现在才让 clk_5m 起来
        repeat (20) @(posedge clk_5m);

        // --- 源域信号精确跳变 ---
        toggle_scl(8);            // I2C SCL 8 次跳变（模拟配置写了几拍）
        toggle_pix_sig(4);        // csi_de 4 次
        toggle_hs(2);             // csi_hs 2 次
        toggle_vs(2);             // csi_vs 2 次
        repeat (10) @(posedge clk);

        probe_raddr = 4'd0; #1; chk("A4 0x80 SCL_CNT  == 8",  probe_rdata, 32'd8);
        probe_raddr = 4'd3; #1; chk("A5 0x8C DE_CNT   == 4",  probe_rdata, 32'd4);
        probe_raddr = 4'd4; #1; chk("A6 0x90 HS_CNT   == 2",  probe_rdata, 32'd2);
        probe_raddr = 4'd5; #1; chk("A7 0x94 VS_CNT   == 2",  probe_rdata, 32'd2);

        // --- 状态字：粘滞位 + 电平（此时 scl 已翻 8 次是低电平、de 翻了 4 次是低电平）---
        probe_raddr = 4'd6; #1; v = probe_rdata;
        chk("A8 0x98 seen: scl(bit6)",  (v >> 6) & 1, 32'd1);
        chk("A9 0x98 seen: de (bit7)",  (v >> 7) & 1, 32'd1);
        chk("A10 0x98 seen: hs(bit8)",  (v >> 8) & 1, 32'd1);
        chk("A11 0x98 seen: vs(bit9)",  (v >> 9) & 1, 32'd1);
        chk("A12 0x98 seen: ck(bit10)", (v >>10) & 1, 32'd1);
        chk("A13 0x98 seen: pk(bit11)", (v >>11) & 1, 32'd1);
        chk("A14 0x98 lvl : scl(bit0)", v & 1, 32'd0);

        // --- 时钟探针：两个时钟都在 ⇒ 计数应 > 0（÷1024，1 次 = 1024 个周期）---
        probe_raddr = 4'd1; #1; ck_a = probe_rdata;
        probe_raddr = 4'd2; #1; pk_a = probe_rdata;
        $display("        (ck_byte probe = %0d, pclk probe = %0d counts, 1 count = 1024 cycles)", ck_a, pk_a);
        chk_ge("A15 0x84 CK_CNT   > 0", ck_a, 32'd1);
        chk_ge("A16 0x88 PCLK_CNT > 0", pk_a, 32'd1);

        // --- 把像素时钟停掉：pclk 探针必须停止增长，而字节时钟继续涨 ---
        repeat (200) @(posedge clk);
        pclk_en = 0;                                  // 停像素时钟
        repeat (20)  @(posedge clk);
        probe_raddr = 4'd2; #1; pk_a = probe_rdata;
        probe_raddr = 4'd1; #1; ck_a = probe_rdata;
        repeat (2000) @(posedge clk);                 // 等 20us
        probe_raddr = 4'd2; #1; chk("A17 0x88 PCLK_CNT frozen when clk dead", probe_rdata, pk_a);
        chk_ge("A18 0x84 CK_CNT   still growing",    probe_rdata, 32'd1);
        probe_raddr = 4'd1; #1;
        if (probe_rdata > ck_a) begin pass = pass + 1; $display("  PASS  A19 0x84 CK_CNT grew while pclk dead = 0x%08X", probe_rdata); end
        else begin fail = fail + 1; $display("  FAIL  A19 CK_CNT did not grow: 0x%08X (was 0x%08X)", probe_rdata, ck_a); end
        pclk_en = 1;
        repeat (20) @(posedge clk);

        // --- CSI RX 状态字 ---
        csi_datatype      = 6'h2A;
        csi_vc            = 2'd1;
        csi_pixel_per_clk = 4'd2;
        csi_fifo_rd_empty = 4'b1010;
        csi_irq           = 1'b1;
        repeat (10) @(posedge clk);
        probe_raddr = 4'd7; #1; v = probe_rdata;
        $display("        (CSI_LINK_ST = 0x%08X)", v);
        chk("A20 0x9C [3:0]   ppc  == 2",   v & 4'hF,            32'd2);
        chk("A21 0x9C [7:4]   fre  == 0xA", (v >> 4)  & 4'hF,    32'hA);
        chk("A22 0x9C [8]     irq  == 1",   (v >> 8)  & 1,        32'd1);
        chk("A23 0x9C [10:9]  vc   == 1",   (v >> 9)  & 2'h3,     32'd1);
        chk("A24 0x9C [16:11] dt   == 0x2A",(v >> 11) & 6'h3F,    32'h2A);

        // --- word_count 变化次数 + 当前值 ---
        //   注意：先把 word_count 从复位值 0 改成 0x1234，这**本身算一次变化**；
        //   再 bump 5 次 ⇒ 计数应为 6（DUT 是对的，这行期望值按实际语义写）
        csi_word_count = 16'h1234;
        repeat (10) @(posedge clk);
        probe_raddr = 4'd9; #1; chk("A25 0xA4 WC_NOW == 0x1234", probe_rdata, 32'h1234);
        word_count_bump(5);                       // 再 +5 次变化
        repeat (10) @(posedge clk);
        probe_raddr = 4'd8; #1; chk("A26 0xA0 WC_CNT == 6 (1 set + 5 bumps)", probe_rdata, 32'd6);
        probe_raddr = 4'd6; #1; chk("A27 0x98 seen: wc(bit12)", (probe_rdata >> 12) & 1, 32'd1);

        // --- 区间外地址（raddr > 15）返回 0 ---
        probe_raddr = 4'd15; #1;   // 15 现在是 RST_HS_STAT，不是"区间外"了
        chk("A29 raddr=15 -> RST_HS_STAT 可读（rx 复位位=1）", probe_rdata & 1, 32'd1);

        // ==========================================================
        //  C) task-24 加固项：位流魔数 / I2C ACK / 数据有效 / HS_ENA
        // ==========================================================
        $display("  --- task-24 加固项 ---");

        // C1/C2 位流魔数（读到才证明探针进了位流）
        probe_raddr = 4'd10; #1; chk("C1 0xB0 PROBE_ID == 0x4D4D5450", probe_rdata, 32'h4D4D5450);
        probe_raddr = 4'd7;  #1;
        chk("C2 0x9C [31:17] 魔数 == 15'h2A5C", (probe_rdata >> 17) & 15'h7FFF, 32'h2A5C);

        // C3 word_count 最大值快照（0x1234 之后又 bump 了 5 次 ⇒ 最大是 0x1239）
        probe_raddr = 4'd12; #1; chk("C3 0xB8 WC_MAX == 0x1239", probe_rdata & 32'hFFFF, 32'h1239);

        // C4 I2C ACK 计数：先发 START，再发 3 个"有应答"+2 个"无应答"的字节
        //    期望 ack=3、nack=2（只看 SCL 是分不出这个的）
        i2c_start();
        i2c_byte(1'b1); i2c_byte(1'b1); i2c_byte(1'b1);   // ACK
        repeat (50) @(posedge clk);
        probe_raddr = 4'd6;  #1; chk("C6 0x98 [13] SDA 电平 == 0(刚 ACK)", (probe_rdata >> 13) & 1, 32'd0);
        i2c_byte(1'b0); i2c_byte(1'b0);                   // NACK
        i2c_scl_low();                                    // 收尾（不动 SDA）
        repeat (200) @(posedge clk);
        probe_raddr = 4'd13; #1; chk("C4 0xBC I2C_ACK_CNT == 3", probe_rdata, 32'd3);
        probe_raddr = 4'd14; #1; chk("C5 0xC0 I2C_NACK_CNT == 2", probe_rdata, 32'd2);

        // C7 数据有效性：DE 在跳但数据全 0 ⇒ pd 不该涨；给非 0 数据后 pd 才涨
        csi_de = 1'b1; csi_pixel_data = 64'd0;
        repeat (3000) @(posedge clk_pixel);              // 远超 1024 拍
        repeat (50) @(posedge clk);
        probe_raddr = 4'd11; #1; v = probe_rdata;
        chk("C7 0xB4 pd == 0 when data all-zero", v, 32'd0);
        probe_raddr = 4'd6;  #1; chk("C8 0x98 [14] pd_any == 0", (probe_rdata >> 14) & 1, 32'd0);

        csi_pixel_data = 64'h0000_0000_0000_00FF;
        repeat (3000) @(posedge clk_pixel);              // 1024 拍非 0 ⇒ pd 至少 +1
        repeat (50) @(posedge clk);
        probe_raddr = 4'd11; #1; chk_ge("C9 0xB4 pd > 0 when data nonzero", probe_rdata, 32'd1);
        probe_raddr = 4'd6;  #1; chk("C10 0x98 [14] pd_any == 1 (粘滞)", (probe_rdata >> 14) & 1, 32'd1);
        csi_de = 1'b0;

        // C11/C12 HS_ENA 电平 + 粘滞位（IP 输出："曾经拉起过"= 摄像头真进过 HS）
        probe_raddr = 4'd15; #1; v = probe_rdata;
        chk("C11 0xC4 HS_ENA 全 0（还没拉起）", (v >> 2) & 5'h1F, 32'd0);
        hs_ck_ena = 1'b1; hs_d0_ena = 1'b1;
        repeat (10) @(posedge clk);
        hs_ck_ena = 1'b0;                                // 只拉起一小会儿
        repeat (10) @(posedge clk);
        probe_raddr = 4'd15; #1; v = probe_rdata;
        chk("C12 0xC4 ck 粘滞位=1（曾拉起）", (v >> 7) & 1, 32'd1);
        chk("C13 0xC4 d0 粘滞位=1",          (v >> 8) & 1, 32'd1);
        chk("C14 0xC4 d1 粘滞位=0（没拉过）", (v >> 9) & 1, 32'd0);
        chk("C15 0xC4 ck 当前电平=0（已落下）", (v >> 2) & 1, 32'd0);

        // C16 复位状态：core rstn 应为 1；像素域 rstn 由 TB 控制
        chk("C16 0xC4 [0] core rstn == 1", v & 1, 32'd1);
        chk("C17 0xC4 [1] 像素域 rstn == 0（TB 还没释放）", (v >> 1) & 1, 32'd0);
        pix_rstn = 1'b1;
        repeat (10) @(posedge clk);
        probe_raddr = 4'd15; #1; chk("C18 0xC4 [1] 释放后 == 1", (probe_rdata >> 1) & 1, 32'd1);

        $display("");
        $display("=== RESULT A+C: PASS %0d / FAIL %0d ===", pass, fail);
        $display("");
        run_regs_test();
    end

    //==========================================================
    //  B) 寄存器块读口测试（探针 rdata 用常量桩）
    //==========================================================
    reg         b_clk = 0, b_rst_n = 0;
    reg  [15:0] b_PADDR = 0;
    reg         b_PENABLE = 0, b_PWRITE = 0, b_PSEL = 0;
    wire [31:0] b_PRDATA;
    wire [3:0]  b_raddr;
    reg  [31:0] b_stub = 32'hDEADBEEF;

    mmt_soc_regs dut_regs (
        .clk(b_clk), .rst_n(b_rst_n),
        .PADDR(b_PADDR), .PENABLE(b_PENABLE), .PWDATA(32'd0), .PWRITE(b_PWRITE),
        .PSEL(b_PSEL), .PRDATA(b_PRDATA), .PREADY(), .PSLVERROR(),
        .sht_data_valid(1'b0), .sht_temp_c_x100(16'sd0), .sht_rh_x100(16'd0),
        .sht_temp_raw(16'd0), .sht_rh_raw(16'd0), .sht_crc_err(1'b0), .sht_bus_err(1'b0),
        .ir_frame_cnt(16'd0), .ir_frame_valid(1'b0), .ir_bus_err(1'b0),
        .ir_ta_raw(16'd0), .ir_rd_data(16'd0),
        .motion_frame_done(1'b0), .motion_frame_tgl(1'b0),
        .motion_sum_area(32'd0), .motion_sum_x(32'd0), .motion_sum_y(32'd0),
        .motion_flag(1'b0),
        .conf_vision(8'h00), .conf_temp(8'h00), .conf_env(8'h00), .score(9'd0),
        .in_auth_window(1'b0), .alarm(1'b0),
        .fb_awvalid(1'b0), .fb_awready(1'b0), .fb_wvalid(1'b0), .fb_wready(1'b0),
        .fb_awaddr(32'd0),
        .diff_threshold(), .diff_min_area(), .score_thresh(),
        .auth_start_h(), .auth_end_h(), .hour(),
        .vision_prob(), .vision_valid(),
        .body_max_c_x10(), .ir_valid(), .ambient_c_x10(), .env_valid(),
        .diff_enable(), .bg_freeze(), .bg_clear_tgl(), .alarm_mute(),
        .ir_frame_addr(), .rh_x100_fwd(),
        .osd_txt_we(), .osd_txt_addr(), .osd_txt_data(),
        .osd_th_we(), .osd_th_addr(), .osd_th_data(),
        .cam_probe_raddr(b_raddr), .cam_probe_rdata(b_stub)
    );

    always #5 b_clk = ~b_clk;

    reg [31:0] bv;
    task breg_read; input [15:0] a; output [31:0] d;
        begin
            @(posedge b_clk); #1;
            b_PSEL = 1; b_PENABLE = 0; b_PWRITE = 0; b_PADDR = a;
            @(posedge b_clk); #1;
            b_PENABLE = 1;
            #1 d = b_PRDATA; #1 d = b_PRDATA;
            @(posedge b_clk); #1;
            b_PSEL = 0; b_PENABLE = 0;
        end
    endtask

    task run_regs_test;
        begin
            $display("=== B) mmt_soc_regs probe read port (stub rdata=0xDEADBEEF) ===");
            b_rst_n = 1;
            repeat (4) @(posedge b_clk);

            breg_read(16'h0080, bv); chk("B1 0x80 -> probe rdata", bv, 32'hDEADBEEF);
            chk("B2 raddr for 0x80 == 0", b_raddr, 32'd0);
            breg_read(16'h0084, bv); chk("B3 0x84 -> probe rdata", bv, 32'hDEADBEEF);
            chk("B4 raddr for 0x84 == 1", b_raddr, 32'd1);
            breg_read(16'h00A4, bv); chk("B5 0xA4 -> probe rdata", bv, 32'hDEADBEEF);
            chk("B6 raddr for 0xA4 == 9", b_raddr, 32'd9);

            // 区间外：既有寄存器不受影响、未映射地址仍为 0
            breg_read(16'h0000, bv); chk("B7 0x00 ID 仍是 0x4D4D5401", bv, 32'h4D4D5401);
            breg_read(16'h007C, bv); chk("B8 0x7C FRM (not the stub)", bv, 32'd0);
            breg_read(16'h0100, bv); chk("B9 0x100 (unmapped) -> 0", bv, 32'd0);
            breg_read(16'h00A8, bv); chk("B10 0xA8 (out of probe range) -> 0", bv, 32'd0);

            $display("");
            $display("=== RESULT total: PASS %0d / FAIL %0d ===", pass, fail);
            if (fail != 0) $display("**** FAILURES PRESENT ****");
            $finish;
        end
    endtask

    initial begin
        #500000;
        $display("!! TIMEOUT");
        $finish;
    end

endmodule
