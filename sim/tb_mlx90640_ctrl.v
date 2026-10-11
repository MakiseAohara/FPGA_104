//==========================================================================
//  tb_mlx90640_ctrl.v  —  MLX90640 红外阵列控制器自检测试平台
//--------------------------------------------------------------------------
//  验证点：
//   T1 开机初始化是"读-改-写、只动刷新率字段"：
//        读 CTRL_REG(0x800D) → 只替换 bit[9:7] → 写回。
//      期望值**不是**照抄 RTL 的掩码算出来的，而是分三条**语义**检查：
//        a) 写进去的值 bit[9:7] == 本 tb 指定的 REFRESH_CODE
//        b) bit[15:10] 与预装初值 CTRL_INIT 的对应位相同
//        c) bit[6:0]   与预装初值 CTRL_INIT 的对应位相同
//      b/c 合起来就是"其余字段原样保留"的证据：如果那次"读"失败，
//      ctrl_val_old 会是 0，写回去只剩下刷新率字段，b/c 必然失败。
//   T2 轮询 STATUS_REG(0x8000) 的 data-ready 位，就绪后写 0x0030 清标志位，
//      且**每帧只清一次**。
//   T3 整帧 26 个 chunk（24×32 像素字 + 2×32 辅助字 = 832 字）顺序搬进 BRAM：
//      frame_addr 必须严格 0..831 递增，frame_data 必须逐字对得上器件 RAM。
//   T4 ta_raw 取的是 frameData[800]（Ptat），对应器件 RAM 字地址
//      0x0700 + (800-768) = 0x0720。
//   T5 从机全 NACK → bus_err 置位；撤掉 NACK 并重新置 data-ready 后能自行恢复
//      并送出第 2 帧。
//
//  仿真参数取舍：
//    CLK_HZ=10MHz / SCL_HZ=1.25MHz → DIV = 10e6/(1.25e6*4) = 2，一个 SCL 位
//    8 个时钟。一帧 = 26 chunk ×(地址 2 字节 + 数据 64 字节) ≈ 12.5ms 仿真时间。
//    FRAME_PERIOD_MS 压到 3ms；REFRESH_CODE 故意取 3'b101(=16Hz) 而不是默认的
//    3'b010，免得 T1 是"和默认值恰好相等"蒙对的。
//
//  ★ 复位是主 initial 块自己控的，不用固定延时：
//    器件 RAM 有 832 个字要预装（每字 2 个时钟 ≈ 166us），如果复位用
//    `#300 rst_n=1` 那种固定延时，DUT 会在预装还没做完时就发起第一次
//    CTRL_REG 读，读回来是 0 —— T1 会因为测试平台的时序问题假失败。
//    所以：先拉低复位 → 预装 → 再放复位。
//==========================================================================
`timescale 1ns / 1ps

module tb_mlx90640_ctrl;

    localparam CLK_HZ          = 10_000_000;
    localparam SCL_HZ          = 1_250_000;
    localparam FRAME_PERIOD_MS = 3;
    localparam [2:0] REFRESH_CODE = 3'b101;

    localparam [15:0] CTRL_INIT   = 16'h1234;   // 预装的 CTRL_REG 初值
    localparam [15:0] RAM_PATTERN = 16'h3C00;   // ram[i] = RAM_PATTERN + i
    localparam integer RAM_N      = 832;
    localparam integer FRAME_WORDS = 832;

    reg clk = 1'b0, rst_n = 1'b0;
    always #50 clk = ~clk;                      // 10MHz，周期 100ns

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

    // ★ 扁平向量必须是 3*（N=3）：写成 2* 会被 iverilog 报
    //   "Port c_dev_addr expects 21 bits, got 14" 并补零，导致事务全错。
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
    wire        f_wr, f_valid, d_bus_err, d_init_done;
    wire [9:0]  f_addr;
    wire [15:0] f_data, f_cnt, d_ta;

    mmt_mlx90640_ctrl #(
        .CLK_HZ(CLK_HZ), .I2C_ADDR(7'h33),
        .FRAME_PERIOD_MS(FRAME_PERIOD_MS), .REFRESH_CODE(REFRESH_CODE)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .frame_wr(f_wr), .frame_addr(f_addr), .frame_data(f_data),
        .frame_cnt(f_cnt), .frame_valid(f_valid), .ta_raw(d_ta),
        .bus_err(d_bus_err), .init_done(d_init_done),
        .req(s_req), .dev_addr(s_dev), .tx_data(s_tx), .tx_len(s_txl), .rd_len(s_rdl),
        .busy(m_busy), .done(h_done[0]), .err(h_err[0]),
        .rd_data(h_rdd[0*8 +: 8]), .rd_valid(h_rdv[0]),
        .hub_grant(h_grant[0])
    );

    // ---------------------------------------------------------- 器件模型
    reg  [15:0] pre_addr, pre_data;
    reg         pre_we;
    reg         nack_all;
    reg         set_ready;
    wire [15:0] m_ctrl, m_status, m_clr_cnt, m_cwr_cnt, m_cwr_val, m_last_addr, m_last_data, m_rd_words;
    wire        m_start, m_stop;

    mlx90640_model #(.ADDR(7'h33)) u_dev (
        .scl(scl), .sda(sda),
        .pre_word_addr(pre_addr), .pre_word_data(pre_data), .pre_we(pre_we),
        .nack_all(nack_all), .set_data_ready(set_ready),
        .ctrl_reg(m_ctrl), .status_reg(m_status),
        .status_clr_cnt(m_clr_cnt), .ctrl_wr_cnt(m_cwr_cnt), .ctrl_wr_val(m_cwr_val),
        .last_wr_addr(m_last_addr), .last_wr_data(m_last_data),
        .got_start(m_start), .got_stop(m_stop), .rd_word_cnt(m_rd_words)
    );

    // ---------------------------------------------------------- 计分板
    integer errors = 0, checks = 0;

    // ★ msg 必须纯 ASCII：iverilog 的 $display("%0s", <宽向量>) 会把多字节
    //   UTF-8 打散成乱码（$display 里的字符串字面量中文是正常的，
    //   只有"经向量传参"的那条路会糊）。
    task automatic check(input cond, input [8*64-1:0] msg);
        begin
            checks = checks + 1;
            if (!cond) begin errors = errors + 1; $display("  [FAIL] %0s", msg); end
        end
    endtask

    task automatic preload(input [15:0] a, input [15:0] d);
        begin
            pre_addr = a; pre_data = d; pre_we = 1'b1;
            @(posedge clk); pre_we = 1'b0; @(posedge clk);
        end
    endtask

    task automatic pulse_ready;
        begin set_ready = 1'b1; @(posedge clk); set_ready = 1'b0; @(posedge clk); end
    endtask

    // ---------------------------------------------------------- 观测
    integer fw_cnt   = 0;      // frame_wr 次数
    integer exp_addr = 0;      // 期望的下一个 frame_addr
    integer ea_err   = 0;      // 地址顺序错
    integer ed_err   = 0;      // 数据内容错

    always @(posedge clk) begin
        if (f_wr) begin
            fw_cnt = fw_cnt + 1;
            if (f_addr !== exp_addr[9:0])                  ea_err = ea_err + 1;
            if (f_data !== (RAM_PATTERN + exp_addr[15:0])) ed_err = ed_err + 1;
            exp_addr = exp_addr + 1;
            if (exp_addr == FRAME_WORDS) exp_addr = 0;     // 下一帧从头再来
        end
    end

    integer berr_cnt = 0;
    reg     berr_d = 1'b0;
    always @(posedge clk) begin
        berr_d <= d_bus_err;
        if (d_bus_err && !berr_d) berr_cnt = berr_cnt + 1;
    end

    // 有界等待：ok=1 表示条件满足，0 表示超时
    localparam W_INIT = 0, W_F1 = 1, W_BERR = 2, W_F2 = 3;
    task automatic wait_cond(input integer which, input integer max_clk, output reg ok);
        integer n;
        begin
            ok = 1'b0;
            n  = 0;
            while (n < max_clk && !ok) begin
                case (which)
                    W_INIT: ok = d_init_done;
                    W_F1:   ok = (f_cnt >= 16'd1);
                    W_BERR: ok = (berr_cnt >= 1);
                    W_F2:   ok = (f_cnt >= 16'd2);
                    default: ok = 1'b1;
                endcase
                if (!ok) begin @(posedge clk); n = n + 1; end
            end
        end
    endtask

    reg w_ok;
    integer i;

    // ---------------------------------------------------------- 主流程
    initial begin
        rst_n    = 1'b0;
        pre_addr = 16'd0; pre_data = 16'd0; pre_we = 1'b0;
        nack_all = 1'b0; set_ready = 1'b0;

        #1000;   // 让器件模型的 initial 初始化先跑完，避免 t=0 的写竞争
        preload(16'h800D, CTRL_INIT);
        preload(16'h8000, 16'h0000);
        for (i = 0; i < RAM_N; i = i + 1)
            preload(16'h0400 + i[15:0], RAM_PATTERN + i[15:0]);

        pulse_ready;                 // 第一帧数据就绪
        repeat (5) @(posedge clk);
        rst_n = 1'b1;

        // ================= T1 初始化：读-改-写，只动刷新率字段 =============
        $display("--- T1: init must read CTRL_REG then write back with only refresh field changed ---");
        wait_cond(W_INIT, 500_000, w_ok);          // 50ms 上限
        check(w_ok, "T1 init_done must assert");
        check(m_cwr_cnt == 16'd1, "T1 CTRL_REG must be written exactly once");
        check(m_cwr_val[9:7] == REFRESH_CODE, "T1 written refresh field must equal REFRESH_CODE");
        check(m_cwr_val[15:10] == CTRL_INIT[15:10], "T1 bits15:10 must keep the value read back");
        check(m_cwr_val[6:0] == CTRL_INIT[6:0], "T1 bits6:0 must keep the value read back");
        check(d_bus_err == 1'b0, "T1 no bus_err during init");
        $display("     ctrl_reg: init=%04x written=%04x (expect refresh field=%b)",
                 CTRL_INIT, m_cwr_val, REFRESH_CODE);

        // ================= T3/T4 整帧搬运 =================================
        $display("--- T3: full frame (26 chunks / 832 words) must land in order ---");
        wait_cond(W_F1, 3_000_000, w_ok);          // 300ms 上限
        check(w_ok, "T3 first frame must complete");
        check(fw_cnt == FRAME_WORDS, "T3 exactly 832 frame words per frame");
        check(ea_err == 0, "T3 frame_addr must increase strictly 0..831");
        check(ed_err == 0, "T3 every frame word must match the device RAM pattern");
        check(d_bus_err == 1'b0, "T3 no bus_err on the happy path");
        check(m_clr_cnt == 16'd1, "T2 STATUS must be cleared exactly once per frame");
        check(m_status[3] == 1'b0, "T2 data-ready bit must be cleared by the controller");

        $display("--- T4: ta_raw must be frameData[800] (device RAM word 0x0720) ---");
        check(d_ta == (RAM_PATTERN + 16'd800), "T4 ta_raw must equal RAM word 800");

        // ================= T5 错误路径 + 恢复 =============================
        $display("--- T5: slave NACK -> bus_err, then must recover ---");
        nack_all = 1'b1;                            // 下一次轮询事务会全 NACK
        wait_cond(W_BERR, 1_000_000, w_ok);         // 100ms 上限
        check(w_ok, "T5 NACK must raise bus_err");
        nack_all = 1'b0;
        pulse_ready;                                // 器件又产生了一帧新数据
        wait_cond(W_F2, 3_000_000, w_ok);           // 300ms 上限
        check(w_ok, "T5 must recover and deliver a 2nd frame after the error");
        check(d_bus_err == 1'b0, "T5 bus_err must clear after recovery");
        check(m_clr_cnt == 16'd2, "T5 second frame must also clear STATUS once");
        check(fw_cnt == FRAME_WORDS * 2, "T5 second frame must carry 832 words too");
        check(ea_err == 0, "T5 frame_addr order must still be correct on frame 2");
        check(ed_err == 0, "T5 frame data must still match on frame 2");

        $display("");
        if (errors == 0) $display("=== ALL TESTS PASSED === (%0d checks)", checks);
        else             $display("=== %0d FAILURES === (%0d checks)", errors, checks);
        $finish;
    end

    // 兜底超时（时间单位 1ns；10MHz 时钟下 100ms = 1e6 个时钟，够跑两帧）
    initial begin
        #100_000_000;
        $display("=== TIMEOUT ===");
        $display("=== %0d FAILURES === (%0d checks)", errors + 1, checks);
        $finish;
    end

endmodule
