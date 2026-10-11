//==========================================================================
//  tb_sht30_ctrl.v  —  SHT30 温湿度控制器自检测试平台
//--------------------------------------------------------------------------
//  验证点：
//   T1 正常测量：写命令 0x2400 → 等 20ms → 读 6 字节 → 校验 CRC → 换算
//      期望值由独立计算得到（不是拿 RTL 输出当期望）：
//        S_T  = 0x6000 → temp_c_x100 = 2062   (20.62°C)
//        S_RH = 0x8000 → rh_x100     = 5000   (50.00%)
//        CRC(0x60,0x00) = 0xD4    CRC(0x80,0x00) = 0xA2
//      定点与浮点原型的偏差只有 0.006°C / 0.0008%，在 1 个 LSB 内
//   T2 CRC 失败：把温度 CRC 改错 → crc_err 置位、不发 data_valid、
//     且**保留上一次的有效值**（不能覆盖）
//   T3 从机 NACK：地址不回应 → bus_err 置位、不卡死
//
//  仿真速度说明：本 tb 把时钟设成 1MHz（CLK_HZ=1_000_000），
//  这样控制器内部那 20ms 的测量等待只需 20000 个周期，仿真快得多。
//  SCL 用 50kHz（DIV=5），保证 scl_hold_low 的时序仍成立。
//==========================================================================
`timescale 1ns / 1ps

module tb_sht30_ctrl;

    localparam CLK_HZ   = 1_000_000;
    localparam SCL_HZ   = 100_000;
    localparam PERIOD_MS= 3;               // 测量周期压到 3ms，加快仿真

    // 期望值（独立算出来的，见文件头）
    localparam [15:0] EXP_TEMP_X100 = 16'd2062;
    localparam [15:0] EXP_RH_X100   = 16'd5000;
    localparam [7:0]  CRC_T         = 8'hD4;
    localparam [7:0]  CRC_RH        = 8'hA2;

    reg clk = 1'b0, rst_n = 1'b0;
    always #500 clk = ~clk;                // 1MHz=1us 周期（配 CLK_HZ=1_000_000）
    // ★ 复位至少要跨越几个时钟周期：异步复位的 always 块靠 `negedge rst_n` 触发，
//   而 rst_n 是从 0 变到 1（上升沿），所以本块只会在 posedge clk 时看到 rst_n=0。
//   第一版只放了 2us，而时钟周期是 100us —— 复位脉冲比一个周期还短，
//   结果复位分支从未执行，div_cnt/ph 一直是 x，整个设计卡死。
    initial begin #3000 rst_n = 1'b1; end   // 约 3 个 1us 时钟周期

    // ---------------------------------------------------------- 总线
    wire scl, sda;
    pullup(scl);
    pullup(sda);

    // ---------------------------------------------------------- 主机 + Hub
    wire [6:0]  m_dev;  wire [31:0] m_tx;  wire [2:0] m_txl; wire [7:0] m_rdl;
    wire        m_req, m_busy, m_done, m_err, m_rdv; wire [7:0] m_rdd;
    wire        m_scl_o, m_scl_oe, m_sda_o, m_sda_oe;

    mmt_i2c_master #(.CLK_HZ(CLK_HZ), .SCL_HZ(SCL_HZ)) u_master (
        .clk(clk), .rst_n(rst_n),
        .req(m_req), .dev_addr(m_dev), .tx_data(m_tx), .tx_len(m_txl), .rd_len(m_rdl),
        .busy(m_busy), .done(m_done), .err(m_err), .rd_data(m_rdd), .rd_valid(m_rdv),
        .scl_i(scl), .scl_o(m_scl_o), .scl_oe(m_scl_oe),
        .sda_i(sda), .sda_o(m_sda_o), .sda_oe(m_sda_oe)
    );
    assign scl = m_scl_oe ? m_scl_o : 1'bz;
    assign sda = m_sda_oe ? m_sda_o : 1'bz;

    // Hub：本 tb 只挂一个客户端（0 号）；N=3，其余 req 恒 0
    // ★ 扁平向量必须是 3*（N=3），写成 2* 会被 iverilog 报
    //   "Port c_dev_addr expects 21 bits, got 14" 并补零，导致事务全错
    wire [2:0]      h_req, h_grant, h_done, h_err, h_rdv;
    wire [3*7-1:0]  h_dev;
    wire [3*32-1:0] h_tx;
    wire [3*3-1:0]  h_txl;
    wire [3*8-1:0]  h_rdl, h_rdd;

    wire        s_req;
    wire [6:0]  s_dev;
    wire [31:0] s_tx;
    wire [2:0]  s_txl;
    wire [7:0]  s_rdl;

    assign h_req[0] = s_req;
    assign h_dev[0*7  +: 7]  = s_dev;
    assign h_tx [0*32 +: 32] = s_tx;
    assign h_txl[0*3  +: 3]  = s_txl;
    assign h_rdl[0*8  +: 8]  = s_rdl;
    assign h_req[1] = 1'b0;
    assign h_req[2] = 1'b0;

    mmt_i2c_hub #(.N(3)) u_hub (
        .clk(clk), .rst_n(rst_n),
        .c_req(h_req), .c_dev_addr(h_dev), .c_tx_data(h_tx), .c_tx_len(h_txl), .c_rd_len(h_rdl),
        .c_grant(h_grant), .c_done(h_done), .c_err(h_err),
        .c_rd_data(h_rdd), .c_rd_valid(h_rdv),
        .m_req(m_req), .m_dev_addr(m_dev), .m_tx_data(m_tx), .m_tx_len(m_txl), .m_rd_len(m_rdl),
        .m_busy(m_busy), .m_done(m_done), .m_err(m_err),
        .m_rd_data(m_rdd), .m_rd_valid(m_rdv)
    );

    // ---------------------------------------------------------- DUT
    wire        d_valid, d_crc_err, d_bus_err;
    wire signed [15:0] d_temp;
    wire [15:0] d_rh, d_temp_raw, d_rh_raw;

    mmt_sht30_ctrl #(
        .CLK_HZ(CLK_HZ), .I2C_ADDR(7'h44), .PERIOD_MS(PERIOD_MS)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .data_valid(d_valid), .temp_c_x100(d_temp), .rh_x100(d_rh),
        .temp_raw(d_temp_raw), .rh_raw(d_rh_raw),
        .crc_err(d_crc_err), .bus_err(d_bus_err),
        .req(s_req), .dev_addr(s_dev), .tx_data(s_tx), .tx_len(s_txl), .rd_len(s_rdl),
        .busy(m_busy), .done(h_done[0]), .err(h_err[0]),
        .rd_data(h_rdd[0*8 +: 8]), .rd_valid(h_rdv[0]),
        .hub_grant(h_grant[0])
    );

    // ---------------------------------------------------------- 从机
    reg  [15:0] sl_addr; reg [7:0] sl_wdata; reg sl_we; wire [7:0] sl_rdata;
    reg         sl_nack;
    wire        sl_start, sl_stop, sl_amatch, sl_lbv;
    wire [7:0]  sl_lastbyte, sl_wrptr;
    wire [15:0] sl_cnt;
    wire        sl_busy;

    i2c_slave_model #(.ADDR(7'h44), .MEM_N(512)) u_slave (
        .scl(scl), .sda(sda),
        .mem_addr(sl_addr), .mem_wdata(sl_wdata), .mem_we(sl_we), .mem_rdata(sl_rdata),
        .nack_addr(sl_nack),
        .got_start(sl_start), .got_stop(sl_stop), .addr_matched(sl_amatch),
        .last_byte(sl_lastbyte), .last_byte_valid(sl_lbv), .byte_count(sl_cnt),
        .wr_ptr_out(sl_wrptr), .busy(sl_busy)
    );

    // ---- 总线级跟踪：默认关闭，加 +trace 打开（vvp a.out +trace）----
    //      纯 always，**绝对不要**用 fork/join_none 往主 initial 块里挂调试进程：
    //      iverilog 11.0 下主块会直接停住，表现为 "0 checks" + 看门狗超时。
    reg        trace_on = 1'b0;
    initial    trace_on = $test$plusargs("trace");
    reg [15:0] sl_cnt_d = 16'hFFFF; reg sl_stop_d = 1'b0; reg m_done_d = 1'b0;
    reg        sl_start_d = 1'b0;
    reg [3:0]  mst_d = 4'hF;
    always @(posedge clk) begin
        sl_cnt_d   <= sl_cnt;
        sl_stop_d  <= sl_stop;
        m_done_d   <= m_done;
        sl_start_d <= sl_start;
        if (trace_on) begin
            if (u_master.state != mst_d) begin
                $display("TR t=%0t MST %0d->%0d bit=%0d txi=%0d raddr=%b scloe=%b sdaoe=%b scl=%b sda=%b act=%b",
                         $time, mst_d, u_master.state, u_master.bit_cnt, u_master.tx_idx,
                         u_master.raddr_phase, u_master.scl_oe, u_master.sda_oe,
                         scl, sda, u_slave.active);
                mst_d = u_master.state;
            end
            if (sl_start && !sl_start_d) $display("TR t=%0t slave START", $time);
            if (sl_cnt != sl_cnt_d)  $display("BUS: byte#%0d = %02x  amatch=%b t=%0t",
                                              sl_cnt, sl_lastbyte, sl_amatch, $time);
            if (sl_stop && !sl_stop_d) $display("BUS: STOP t=%0t", $time);
            if (m_done && !m_done_d)  $display("BUS: master done t=%0t err=%b", $time, m_err);
        end
    end

    task automatic sl_poke(input [15:0] a, input [7:0] d);
        begin sl_addr = a; sl_wdata = d; sl_we = 1'b1; @(posedge clk); sl_we = 1'b0; @(posedge clk); end
    endtask

    // ---------------------------------------------------------- 计分板
    integer errors = 0, checks = 0;
    task automatic check(input cond, input [8*80-1:0] msg);
        begin
            checks = checks + 1;
            if (!cond) begin errors = errors + 1; $display("  [FAIL] %0s", msg); end
        end
    endtask

    // 等待 data_valid，带超时
    reg got_valid; reg [31:0] err_flags_seen;
    task automatic wait_valid(input integer max_ms);
        integer n;
        begin
            got_valid = 1'b0;
            n = 0;
            while (!d_valid && n < max_ms * 1000) begin @(posedge clk); n = n + 1; end
            got_valid = d_valid;
        end
    endtask

    // ★ 等"失败周期"必须用这两个，不能用 wait_valid：
    //   CRC 错 / NACK 的周期**不会**产生 data_valid，用 wait_valid 只能等到超时；
    //   而超时窗口（40ms）比一个完整周期（约 23ms）还长，期间 DUT 早就跑完
    //   下一轮正常测量把 crc_err 清掉了 —— 于是"crc_err 必须置位"这种检查
    //   永远失败，看着像 RTL 错，其实是测试平台等错了信号。
    task automatic wait_crc_err(input integer max_ms);
        integer n;
        begin
            got_valid = 1'b0;
            n = 0;
            while (!d_crc_err && n < max_ms * 1000) begin @(posedge clk); n = n + 1; end
        end
    endtask

    task automatic wait_bus_err(input integer max_ms);
        integer n;
        begin
            got_valid = 1'b0;
            n = 0;
            while (!d_bus_err && n < max_ms * 1000) begin @(posedge clk); n = n + 1; end
        end
    endtask

    integer i;
    time t_clk0, t_clk1;

    // ---- 数据到达监视：只在 data_valid 拉高那拍打印一次（纯 always，
    //      绝对不要用 fork/join_none 往主 initial 块里挂调试进程）----
    always @(posedge clk) begin
        if (d_valid)
            $display("MON: d_valid t=%0t temp=%0d rh=%0d crc_err=%b bus_err=%b",
                     $time, d_temp, d_rh, d_crc_err, d_bus_err);
    end

    // ---- 临时调试监视：只在状态变化时打印 ----
    reg dbg_en = 1'b1;
    reg [3:0] mst_prev = 4'hF;
    reg [2:0] dst_prev = 3'h7;
    always @(posedge clk) begin
        if (1'b0) begin
            $display("XDBG t=%0t MST %0d->%0d bit=%0d txi=%0d ph=%0d div=%0d scloe=%b sdaoe=%b ack=%b err=%b | DUT %0d->%0d req=%b valid=%b",
                     $time, mst_prev, u_master.state, u_master.bit_cnt, u_master.tx_idx,
                     u_master.ph, u_master.div_cnt, u_master.scl_oe, u_master.sda_oe,
                     u_master.ack_bit, u_master.err, dst_prev, dut.state, s_req, d_valid);
            mst_prev <= u_master.state;
            dst_prev <= dut.state;
        end
    end

    initial begin
        sl_addr = 16'd0; sl_wdata = 8'd0; sl_we = 1'b0; sl_nack = 1'b0;
        err_flags_seen = 32'd0;

        // 预装读回数据：T_MSB T_LSB T_CRC RH_MSB RH_LSB RH_CRC
        sl_poke(16'd0, 8'h60);   // S_T  MSB
        sl_poke(16'd1, 8'h00);   // S_T  LSB
        sl_poke(16'd2, CRC_T);   // CRC
        sl_poke(16'd3, 8'h80);   // S_RH MSB
        sl_poke(16'd4, 8'h00);   // S_RH LSB
        sl_poke(16'd5, CRC_RH);  // CRC

        $display("CONST: dut.CLK_HZ=%0d dut.WAIT_TICKS=%0d dut.PERIOD_TICKS=%0d", dut.CLK_HZ, dut.WAIT_TICKS, dut.PERIOD_TICKS);
        $display("CONST: u_master.DIV=%0d u_master.CLK_HZ=%0d u_master.SCL_HZ=%0d", u_master.DIV, u_master.CLK_HZ, u_master.SCL_HZ);
        t_clk0 = $time; @(posedge clk); @(posedge clk); t_clk1 = $time;
        $display("CONST: measured clk period = %0d ns", t_clk1 - t_clk0);
        // ★ 复位时序坑（连着踩了两次，写清楚）：
        //   上面 6 次 sl_poke 已经花掉 650us，t_clk 测完是 850us，而 rst_n 在
        //   300us 就已经拉高释放了。所以这里
        //     - @(posedge rst_n) → 等一个永远不会再来的沿，直接挂到看门狗（本版本）
        //     - wait(rst_n)      → 值本来就是 1，本应立刻返回；但它和以前那个
        //                          `fork forever begin : probe end join_none` 探针
        //                          放在同一个 initial 块里时，iverilog 11.0 会让
        //                          父进程停住（探针已经删掉，别再往主块里挂
        //                          join_none 的调试进程）
        //   正确做法：**什么都不等**，复位早就释放了。
        #5000;

        // ---------------- T1 正常测量 ----------------
        $display("--- T1: normal measurement (CRC ok) ---");
        wait_valid(40);                     // 命令 + 20ms 等待 + 读，40ms 足够
        check(got_valid, "T1 data_valid must pulse");
        check(d_crc_err == 1'b0, "T1 crc_err must be 0");
        check(d_bus_err == 1'b0, "T1 bus_err must be 0");
        check(d_temp == EXP_TEMP_X100, "T1 temp_c_x100 must be 2062 (20.62C)");
        check(d_rh   == EXP_RH_X100,   "T1 rh_x100 must be 5000 (50.00%)");
        check(d_temp_raw == 16'h6000,  "T1 temp_raw must be 0x6000");
        check(d_rh_raw   == 16'h8000,  "T1 rh_raw must be 0x8000");
        $display("     temp_c_x100=%0d  rh_x100=%0d", d_temp, d_rh);

        // ---------------- T2 CRC 失败 ----------------
        $display("--- T2: CRC failure -> must keep previous value ---");
        sl_poke(16'd2, 8'h00);              // 故意把温度 CRC 写错
        wait_crc_err(40);
        // 本周期应校验失败：crc_err 置位、data_valid 不产生
        check(d_crc_err == 1'b1, "T2 crc_err must be set");
        check(d_temp == EXP_TEMP_X100, "T2 must keep previous temp value (2062)");
        check(d_rh   == EXP_RH_X100,   "T2 must keep previous rh value (5000)");
        check(got_valid == 1'b0, "T2 data_valid must NOT pulse on CRC error");

        // 恢复正确 CRC
        sl_poke(16'd2, CRC_T);

        // ---------------- T3 从机 NACK ----------------
        $display("--- T3: slave NACK (address) -> bus_err, must not hang ---");
        sl_nack = 1'b1;
        wait_bus_err(40);
        check(d_bus_err == 1'b1, "T3 bus_err must be set on NACK");
        check(d_temp == EXP_TEMP_X100, "T3 must keep previous values");
        sl_nack = 1'b0;

        // 恢复正常后应能再次拿到数据
        $display("--- T4: recovery after NACK ---");
        wait_valid(40);
        check(got_valid, "T4 must recover and produce data again after NACK");
        check(d_bus_err == 1'b0, "T4 bus_err must clear after successful txn");

        $display("");
        if (errors == 0) $display("=== ALL TESTS PASSED === (%0d checks)", checks);
        else             $display("=== %0d FAILURES === (%0d checks)", errors, checks);
        $finish;
    end

    // 看门狗
    // ★ 注意时间单位：本 tb 时钟周期 1µs，而 $time 按 1ns 计。
    //   一轮"命令+20ms 等待+读"就要 20,000,000 ns 仿真时间，四个测试留 120ms 余量。
    initial begin
        #2000000000;
        $display("=== TIMEOUT ===");
        $display("=== %0d FAILURES === (%0d checks)", errors + 1, checks);
        $finish;
    end

endmodule
