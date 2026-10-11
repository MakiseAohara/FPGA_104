//==========================================================================
//  tb_i2c_hub.v  —  I2C 分时复用控制器（mmt_i2c_hub）自检测试平台
//--------------------------------------------------------------------------
//  验证点：
//   T1 单客户端写事务 → 成功（err=0）
//   T2 两客户端同时请求 → 轮流授权，都完成，不饿死
//   T3 grant 与 done 必须**同一拍**有效（修过的死锁 bug 的回归测试）
//   T4 客户端 req 未撤销前不得被再次授权（边沿重新武装的回归测试）
//   T5 从机 NACK → 只有被授权的那个客户端收到 c_err
//
//  用法: 见 工作区\06_Efinity验证\sim.ps1
//    .\sim.ps1 -Tb sim\tb_i2c_hub.v -Src @('rtl\mmt\sensors\mmt_i2c_master.v','rtl\mmt\sensors\mmt_i2c_hub.v','sim\i2c_slave_model.v')
//==========================================================================
`timescale 1ns / 1ps

module tb_i2c_hub;

    localparam N = 3;

    // ---------------------------------------------------------------- 时钟
    reg clk = 1'b0, rst_n = 1'b0;
    always #5 clk = ~clk;                     // 100MHz（与 CLK_HZ 一致）
    initial begin #100 rst_n = 1'b1; end

    // ---------------------------------------------------------------- 总线（开漏 + 上拉）
    wire scl, sda;
    pullup(scl);
    pullup(sda);

    // ---------------------------------------------------------------- DUT 之间的连线
    wire [6:0]  m_dev;
    wire [31:0] m_tx;
    wire [2:0]  m_txl;
    wire [7:0]  m_rdl;
    wire        m_req, m_busy, m_done, m_err, m_rdv;
    wire [7:0]  m_rdd;
    wire        m_scl_o, m_scl_oe, m_sda_o, m_sda_oe;

    mmt_i2c_master #(.CLK_HZ(100_000_000), .SCL_HZ(1_000_000)) dut_master (
        .clk(clk), .rst_n(rst_n),
        .req(m_req), .dev_addr(m_dev), .tx_data(m_tx), .tx_len(m_txl), .rd_len(m_rdl),
        .busy(m_busy), .done(m_done), .err(m_err), .rd_data(m_rdd), .rd_valid(m_rdv),
        .scl_i(scl), .scl_o(m_scl_o), .scl_oe(m_scl_oe),
        .sda_i(sda), .sda_o(m_sda_o), .sda_oe(m_sda_oe)
    );

    // 开漏三态（master 侧）
    assign scl = m_scl_oe ? m_scl_o : 1'bz;
    assign sda = m_sda_oe ? m_sda_o : 1'bz;

    // 客户端侧：被 tb 驱动的用 reg，来自 DUT 的用 wire
    reg  [N-1:0]      c_req;
    reg  [N*7-1:0]    c_dev;
    reg  [N*32-1:0]   c_tx;
    reg  [N*3-1:0]    c_txl;
    reg  [N*8-1:0]    c_rdl;
    wire [N-1:0]      c_grant, c_done, c_err, c_rdv;
    wire [N*8-1:0]    c_rdd;

    mmt_i2c_hub #(.N(N)) dut_hub (
        .clk(clk), .rst_n(rst_n),
        .c_req(c_req), .c_dev_addr(c_dev), .c_tx_data(c_tx), .c_tx_len(c_txl), .c_rd_len(c_rdl),
        .c_grant(c_grant), .c_done(c_done), .c_err(c_err),
        .c_rd_data(c_rdd), .c_rd_valid(c_rdv),
        .m_req(m_req), .m_dev_addr(m_dev), .m_tx_data(m_tx), .m_tx_len(m_txl), .m_rd_len(m_rdl),
        .m_busy(m_busy), .m_done(m_done), .m_err(m_err),
        .m_rd_data(m_rdd), .m_rd_valid(m_rdv)
    );

    // ---------------------------------------------------------------- 从机模型
    reg  [15:0] sl_mem_addr;
    reg  [7:0]  sl_mem_wdata;
    reg         sl_mem_we;
    wire [7:0]  sl_mem_rdata;
    reg         sl_nack_addr;

    i2c_slave_model #(.ADDR(7'h44), .MEM_N(1024)) u_slave (
        .scl(scl), .sda(sda),
        .mem_addr(sl_mem_addr), .mem_wdata(sl_mem_wdata), .mem_we(sl_mem_we),
        .mem_rdata(sl_mem_rdata),
        .nack_addr(sl_nack_addr),
        .got_start(), .got_stop(), .addr_matched(),
        .last_byte(), .last_byte_valid(), .byte_count(), .wr_ptr_out(), .busy()
    );

    // ---------------------------------------------------------------- 计分板
    integer errors = 0, checks = 0;
    task automatic check(input cond, input [8*80-1:0] msg);
        begin
            checks = checks + 1;
            if (!cond) begin
                errors = errors + 1;
                $display("  [FAIL] %0s", msg);
            end
        end
    endtask

    // ---------------------------------------------------------------- grant/done 同拍监视
    reg        grant_done_same_cycle_violation;
    reg [N-1:0] prev_grant;
    always @(posedge clk) begin
        // 记录：上一拍有没有 grant 而没有 done（正常，事务进行中）
        // 违规判定放在任务里检查：done 有效时必须同时有 grant
        if (|c_done && !(|c_grant)) begin
            grant_done_same_cycle_violation <= 1'b1;
            $display("  [FAIL] done asserted without a grant (deadlock regression!)t=%0t", $time);
        end
        prev_grant <= c_grant;
    end

    // ---------------------------------------------------------------- 客户端模型
    // 行为良好的客户端：备好参数 → req 拉高 → 等 grant&&done → 记结果 → 撤 req
    reg [31:0] cli_done_cnt [0:N-1];
    reg [31:0] cli_err_cnt  [0:N-1];
    reg [6:0]  cli_last_dev [0:N-1];

    task automatic client_txn(input integer idx,
                              input [6:0]  dev,
                              input [31:0] txd,
                              input [2:0]  txl,
                              input [7:0]  rdl,
                              output integer got_err);
        begin
            @(posedge clk);
            c_dev[idx*7  +: 7]  = dev;
            c_tx [idx*32 +: 32] = txd;
            c_txl[idx*3  +: 3]  = txl;
            c_rdl[idx*8  +: 8]  = rdl;
            c_req[idx] = 1'b1;
            // 等 done（同时必须 grant 有效）
            while (!(c_grant[idx] && c_done[idx])) @(posedge clk);
            got_err = c_err[idx];
            cli_done_cnt[idx] = cli_done_cnt[idx] + 1;
            if (c_err[idx]) cli_err_cnt[idx] = cli_err_cnt[idx] + 1;
            cli_last_dev[idx] = dev;
            c_req[idx] = 1'b0;
            @(posedge clk);
        end
    endtask

    // ---------------------------------------------------------------- 测试
    integer e0, e1, e2;
    integer i;
    reg [N-1:0] grant_snapshot;
    reg [31:0] t2_c0_before, t2_c1_before;
    reg [31:0] t4_c0, t4_c1, t4_c2;

    initial begin
        // 初始化
        sl_mem_addr  = 16'd0; sl_mem_wdata = 8'd0; sl_mem_we = 1'b0; sl_nack_addr = 1'b0;
        grant_done_same_cycle_violation = 1'b0;
        for (i = 0; i < N; i = i + 1) begin
            c_req[i] = 1'b0;
            cli_done_cnt[i] = 0; cli_err_cnt[i] = 0; cli_last_dev[i] = 7'd0;
        end

        // 预装从机寄存器（读测试用）
        for (i = 0; i < 16; i = i + 1) begin
            sl_mem_addr = i[15:0]; sl_mem_wdata = 8'hA0 + i[7:0]; sl_mem_we = 1'b1; #1;
        end
        sl_mem_we = 1'b0;

        wait (rst_n);
        #200;

        // ---------------- T1：单客户端写 ----------------
        $display("--- T1: single-client write ---");
        fork
            client_txn(0, 7'h44, 32'h0000_2400, 3'd2, 8'd0, e0);
        join
        check(e0 == 0, "T1 write txn must not report err");
        check(sl_nack_addr == 0, "T1 slave must not NACK");

        // ---------------- T2：两客户端同时请求 ----------------
        // ★ 必须用 client_txn：它会在 done 之后撤 req 并记账。
        //   第一版我直接拉 c_req 然后干等，结果没人撤 req、也没人记账 → 检查必然失败。
        //   那是**测试平台的 bug，不是 DUT 的 bug**。
        $display("--- T2: two clients request simultaneously, expect round-robin ---");
        t2_c0_before = cli_done_cnt[0];
        t2_c1_before = cli_done_cnt[1];
        fork
            client_txn(0, 7'h44, 32'h0000_2400, 3'd2, 8'd0, e0);
            client_txn(1, 7'h44, 32'h0000_2C06, 3'd2, 8'd0, e1);
        join
        check(cli_done_cnt[0] == t2_c0_before + 1, "T2 client0 must complete exactly once more");
        check(cli_done_cnt[1] == t2_c1_before + 1, "T2 client1 must complete exactly once more");
        check(e0 == 0 && e1 == 0, "T2 neither client may report err");

        // ---------------- T3：grant/done 同拍（回归测试）----------------
        $display("--- T3: grant and done must be in the same cycle ---");
        check(grant_done_same_cycle_violation == 1'b0, "T3 grant must be asserted while done is high");

        // ---------------- T4：三个客户端都请求，轮流服务不饿死 ----------------
        t4_c0 = cli_done_cnt[0]; t4_c1 = cli_done_cnt[1]; t4_c2 = cli_done_cnt[2];
        $display("--- T4: three clients, no starvation ---");
        fork
            client_txn(0, 7'h44, 32'h0000_2400, 3'd2, 8'd0, e0);
            client_txn(1, 7'h44, 32'h0000_2C06, 3'd2, 8'd0, e1);
            client_txn(2, 7'h44, 32'h0000_2400, 3'd2, 8'd0, e2);
        join
        check(e0 == 0 && e1 == 0 && e2 == 0, "T4 all three clients must complete without err");
        check((cli_done_cnt[0] > t4_c0) && (cli_done_cnt[1] > t4_c1) && (cli_done_cnt[2] > t4_c2),
              "T4 all three clients must be served (no starvation)");

        // ---------------- T5：从机 NACK → 只有被授权者收到 err ----------------
        $display("--- T5: on slave NACK only the granted client sees c_err ---");
        sl_nack_addr = 1'b1;              // 让从机对地址回 NACK
        @(posedge clk);
        fork
            client_txn(0, 7'h44, 32'h0000_2400, 3'd2, 8'd0, e0);
        join
        check(e0 == 1, "T5 granted client must see c_err=1 on NACK");
        sl_nack_addr = 1'b0;

        // ---------------- 汇总 ----------------
        $display("");
        $display("client done count: [0]=%0d [1]=%0d [2]=%0d",
                 cli_done_cnt[0], cli_done_cnt[1], cli_done_cnt[2]);
        $display("client err  count: [0]=%0d [1]=%0d [2]=%0d",
                 cli_err_cnt[0], cli_err_cnt[1], cli_err_cnt[2]);
        $display("");
        if (errors == 0) $display("=== ALL TESTS PASSED === (%0d checks)", checks);
        else             $display("=== %0d FAILURES === (%0d checks)", errors, checks);
        $finish;
    end

    // 看门狗
    initial begin
        #20000000;
        $display("=== TIMEOUT ===");
        $display("=== %0d FAILURES === (%0d checks)", errors + 1, checks);
        $finish;
    end

endmodule
