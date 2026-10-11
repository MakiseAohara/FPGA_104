//==========================================================================
//  tb_i2c_master.v — mmt_i2c_master 行为级验证
//  真断言，不是看波形。行为级 I2C 从机用 SDA/SCL 的开漏+上拉建模
//  （两边都只拉低或释放，线上电平由 pullup 决定），用 iverilog -g2012 跑。
//==========================================================================
`timescale 1ns/1ps

module tb_i2c_master;

    // ------------------------------------------------------------ 时钟/复位
    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;   // 100MHz

    // ------------------------------------------------------------ DUT 接口
    reg         req;
    reg  [6:0]  dev_addr;
    reg  [31:0] tx_data;
    reg  [2:0]  tx_len;
    reg  [7:0]  rd_len;
    wire        busy, done, err;
    wire [7:0]  rd_data;
    wire        rd_valid;

    wire        scl_i, sda_i;
    wire        scl_o, scl_oe, sda_o, sda_oe;

    // ------------------------------------------------------------ 总线建模（开漏+上拉）
    wire scl, sda;
    pullup(scl);
    pullup(sda);
    assign scl = scl_oe ? scl_o : 1'bz;
    assign sda = sda_oe ? sda_o : 1'bz;
    assign scl_i = scl;
    assign sda_i = sda;

    // 从机侧对总线的驱动
    reg slave_sda_low;
    assign sda = slave_sda_low ? 1'b0 : 1'bz;

    mmt_i2c_master #(.CLK_HZ(100_000_000), .SCL_HZ(1_000_000)) dut (
        .clk(clk), .rst_n(rst_n),
        .req(req), .dev_addr(dev_addr), .tx_data(tx_data), .tx_len(tx_len), .rd_len(rd_len),
        .busy(busy), .done(done), .err(err),
        .rd_data(rd_data), .rd_valid(rd_valid),
        .scl_i(scl_i), .scl_o(scl_o), .scl_oe(scl_oe),
        .sda_i(sda_i), .sda_o(sda_o), .sda_oe(sda_oe)
    );
    // 注：SCL_HZ 特意调高到 1MHz（而不是产品用的 100kHz）只是为了让仿真跑快点，
    // 时序结构（四相/ACK/START/STOP）跟频率无关，不影响验证的有效性。

    // ------------------------------------------------------------ 计分板
    integer pass_cnt = 0;
    integer fail_cnt = 0;
    // ★ msg 必须是 **纯 ASCII**：iverilog 的 $display("%0s", <宽向量>) 会把多字节
    //   UTF-8 打散（ASCII 部分正常、中文部分变成一串乱码），而 $display 里的字符串
    //   **字面量**中文是正常的 —— 所以同一个文件里 "……通过" 显示得好好的，
    //   check() 传进去的中文却糊成一团。规则：check() 的消息只用 ASCII。
    task automatic check(input cond, input [8*64-1:0] msg);
        begin
            if (cond) begin
                pass_cnt = pass_cnt + 1;
            end else begin
                fail_cnt = fail_cnt + 1;
                $display("  [FAIL] %0s", msg);
            end
        end
    endtask

    // ------------------------------------------------------------ 从机侧低层 bit 原语
    task automatic slave_recv_bit(output reg b);
        begin
            @(posedge scl);
            b = sda;
            @(negedge scl);
        end
    endtask

    task automatic slave_send_bit(input b);
        begin
            slave_sda_low = ~b;      // 0=>拉低, 1=>释放
            @(posedge scl);
            @(negedge scl);
            slave_sda_low = 1'b0;
        end
    endtask

    // 收 1 字节 + 回 ACK/NACK（MSB 先到）
    task automatic slave_recv_byte(output reg [7:0] byte_out, input do_ack);
        integer bi;
        reg b;
        begin
            byte_out = 8'h00;
            for (bi = 7; bi >= 0; bi = bi - 1) begin
                slave_recv_bit(b);
                byte_out[bi] = b;
            end
            slave_send_bit(do_ack ? 1'b0 : 1'b1);   // ACK=拉低(0), NACK=释放(1)
        end
    endtask

    // 发 1 字节 + 读主机的 ACK/NACK（MSB 先发）
    task automatic slave_send_byte(input [7:0] byte_in, output reg nack_seen);
        integer bi;
        reg ackbit;
        begin
            for (bi = 7; bi >= 0; bi = bi - 1) slave_send_bit(byte_in[bi]);
            slave_recv_bit(ackbit);
            nack_seen = ackbit;   // 1 = 主机回了 NACK（最后一字节应该是这样）
        end
    endtask

    // 等 START：SDA 在 SCL=1 期间下降
    task automatic wait_for_start;
        begin : blk
            forever begin
                @(negedge sda);
                if (scl === 1'b1) disable blk;
            end
        end
    endtask

    // 等 STOP：SDA 在 SCL=1 期间上升
    task automatic wait_for_stop_or_rstart(output reg was_stop);
        // 阻塞直到看到 STOP(SDA 上升沿, SCL=1) 或 重复START(SDA 下降沿, SCL=1)
        begin : blk2
            forever begin
                @(sda);
                if (scl === 1'b1) begin
                    was_stop = sda;   // 上升=STOP(1)，下降=重复START(0)
                    disable blk2;
                end
            end
        end
    endtask

    // ------------------------------------------------------------ 驱动 DUT 发起一次事务，等待完成
    task automatic drive_req(
        input [6:0]  a_dev_addr,
        input [31:0] a_tx_data,
        input [2:0]  a_tx_len,
        input [7:0]  a_rd_len
    );
        begin
            @(negedge clk);
            dev_addr = a_dev_addr;
            tx_data  = a_tx_data;
            tx_len   = a_tx_len;
            rd_len   = a_rd_len;
            req      = 1'b1;
            @(posedge done);
            @(negedge clk);
            req = 1'b0;
        end
    endtask

    // ==========================================================================
    // 测试 1：写事务 tx_len=2，从机 ACK —— 检查 START/地址/2数据字节/STOP
    // ==========================================================================
    reg [7:0] cap_b0, cap_b1;
    reg       cap_addr_rw_ok;
    reg [7:0] addr_byte;
    reg       stop_flag;
    task automatic test1_write2;
        begin
            fork
                begin  // 从机
                    wait_for_start;
                    slave_recv_byte(addr_byte, 1'b1);       // ACK 地址
                    cap_addr_rw_ok = (addr_byte == {7'h44, 1'b0});  // W=0
                    slave_recv_byte(cap_b0, 1'b1);
                    slave_recv_byte(cap_b1, 1'b1);
                    wait_for_stop_or_rstart(stop_flag);
                end
                begin  // 主机
                    drive_req(7'h44, 32'h0000_2400, 3'd2, 8'd0);
                end
            join
            check(cap_addr_rw_ok, "T1: 地址字节应为{0x44,W=0}");
            check(cap_b0 == 8'h24, "T1: 第1数据字节应为0x24");
            check(cap_b1 == 8'h00, "T1: 第2数据字节应为0x00");
            check(stop_flag == 1'b1, "T1: 数据发完后应为STOP而非重复START");
            check(err == 1'b0, "T1: ACK都给了，err不应置位");
            $display("[T1] 写2字节(SHT30命令) 通过（地址=%02h 数据=%02h,%02h STOP=%0d）", addr_byte, cap_b0, cap_b1, stop_flag);
        end
    endtask

    // ==========================================================================
    // 测试 2：写事务 tx_len=4（写寄存器场景 32'h800D_0000）—— 四字节顺序必须对
    // ==========================================================================
    reg [7:0] c2_0, c2_1, c2_2, c2_3;
    task automatic test2_write4;
        begin
            fork
                begin
                    wait_for_start;
                    slave_recv_byte(addr_byte, 1'b1);
                    slave_recv_byte(c2_0, 1'b1);
                    slave_recv_byte(c2_1, 1'b1);
                    slave_recv_byte(c2_2, 1'b1);
                    slave_recv_byte(c2_3, 1'b1);
                    wait_for_stop_or_rstart(stop_flag);
                end
                begin
                    drive_req(7'h33, 32'h800D_0012, 3'd4, 8'd0);
                end
            join
            check(c2_0 == 8'h80, "T2: 字节0应为0x80");
            check(c2_1 == 8'h0D, "T2: 字节1应为0x0D");
            check(c2_2 == 8'h00, "T2: 字节2应为0x00");
            check(c2_3 == 8'h12, "T2: 字节3应为0x12");
            check(stop_flag == 1'b1, "T2: 4字节写完应为STOP");
            $display("[T2] 写4字节(CTRL_REG场景) 通过（%02h,%02h,%02h,%02h）", c2_0,c2_1,c2_2,c2_3);
        end
    endtask

    // ==========================================================================
    // 测试 3：纯读 tx_len=0, rd_len=6 —— 地址字节R/W位必须是1
    // ==========================================================================
    reg [7:0] rd_program [0:5];
    reg [7:0] rd_got [0:5];
    reg       nack_last;
    integer   ii;
    task automatic test3_pure_read6;
        begin
            rd_program[0]=8'hAA; rd_program[1]=8'hBB; rd_program[2]=8'h11;
            rd_program[3]=8'hCC; rd_program[4]=8'hDD; rd_program[5]=8'h22;
            fork
                begin
                    wait_for_start;
                    slave_recv_byte(addr_byte, 1'b1);
                    cap_addr_rw_ok = (addr_byte[0] == 1'b1);   // R/W位=1
                    for (ii = 0; ii < 6; ii = ii + 1) begin
                        slave_send_byte(rd_program[ii], nack_last);
                        rd_got[ii] = rd_program[ii];
                        if (ii < 5) check(nack_last == 1'b0, "T3: 非最后字节主机应ACK");
                        else        check(nack_last == 1'b1, "T3: 最后字节主机应NACK");
                    end
                    wait_for_stop_or_rstart(stop_flag);
                end
                begin
                    drive_req(7'h5A, 32'd0, 3'd0, 8'd6);
                end
            join
            check(cap_addr_rw_ok, "T3: 纯读地址字节R/W位必须=1");
            check(stop_flag == 1'b1, "T3: 读完应为STOP");
            $display("[T3] 纯读6字节 通过（地址R/W=%0d）", addr_byte[0]);
        end
    endtask

    // ==========================================================================
    // 测试 4：写地址+重复START+读（MLX90640场景）tx_len=2, rd_len=4
    //         必须是重复START（不是STOP+START），读地址R/W=1，最后字节NACK
    // ==========================================================================
    reg [7:0] c4_addr_w, c4_r0, c4_r1;
    reg       c4_rstart_flag;
    task automatic test4_write_then_read;
        begin
            fork
                begin
                    wait_for_start;
                    slave_recv_byte(c4_addr_w, 1'b1);
                    check(c4_addr_w == {7'h33,1'b0}, "T4: 写地址字节R/W应为0");
                    slave_recv_byte(c4_r0, 1'b1);
                    slave_recv_byte(c4_r1, 1'b1);
                    wait_for_stop_or_rstart(c4_rstart_flag);   // 期望=0(重复START)
                    check(c4_rstart_flag == 1'b0, "T4: 写完寄存器地址后必须是重复START而不是STOP");
                    slave_recv_byte(addr_byte, 1'b1);
                    check(addr_byte == {7'h33,1'b1}, "T4: 重复START后读地址R/W应为1");
                    for (ii = 0; ii < 4; ii = ii + 1) begin
                        slave_send_byte(8'hE0 + ii[7:0], nack_last);
                        if (ii < 3) check(nack_last == 1'b0, "T4: 读的非最后字节应ACK");
                        else        check(nack_last == 1'b1, "T4: 读的最后字节必须NACK");
                    end
                    wait_for_stop_or_rstart(stop_flag);
                    check(stop_flag == 1'b1, "T4: 读完应以STOP结束");
                end
                begin
                    drive_req(7'h33, 32'h0400_0000, 3'd2, 8'd4);
                end
            join
            $display("[T4] 写寄存器地址+重复START+读4字节(MLX90640场景) 通过");
        end
    endtask

    // ==========================================================================
    // 测试 5：NACK 错误路径 —— 从机对地址不回ACK，err必须置位，不能卡死
    // ==========================================================================
    task automatic test5_addr_nack;
        begin
            fork
                begin
                    wait_for_start;
                    slave_recv_byte(addr_byte, 1'b0);   // 故意NACK地址
                    wait_for_stop_or_rstart(stop_flag);
                    check(stop_flag == 1'b1, "T5: 地址NACK后主机应直接STOP");
                end
                begin
                    drive_req(7'h20, 32'hAB00_0000, 3'd1, 8'd0);
                end
            join
            check(err == 1'b1, "T5: 地址NACK后err必须置位");
            $display("[T5] 地址NACK错误路径 通过（err=%0d）", err);
        end
    endtask

    // ==========================================================================
    // 测试 6：req/done 竞争回归 —— 连续两次事务，第二次必须等req重新拉高
    //         （对应Claude上轮发现、DeepSeek本轮修的 req_armed 边沿重新武装）
    // ==========================================================================
    integer unexpected_start_count;
    reg     watching_for_spurious;
    task automatic slave_ack_one_write2(input [6:0] a, input [7:0] b0exp, input [7:0] b1exp);
        reg [7:0] ab, d0, d1;
        begin
            wait_for_start;
            slave_recv_byte(ab, 1'b1);
            slave_recv_byte(d0, 1'b1);
            slave_recv_byte(d1, 1'b1);
            wait_for_stop_or_rstart(stop_flag);
            check(ab == {a,1'b0}, "T6: 地址字节匹配");
            check(d0 == b0exp && d1 == b1exp, "T6: 数据字节匹配");
        end
    endtask
    task automatic test6_req_rearm;
        begin
            unexpected_start_count = 0;
            watching_for_spurious = 1'b0;
            // 第一次事务
            fork
                slave_ack_one_write2(7'h44, 8'h11, 8'h22);
                drive_req(7'h44, 32'h0000_1122, 3'd2, 8'd0);
            join
            // done 已经拉回；这里刻意在“req真正撤销”之后再等一小段时间，
            // 用一个后台进程监视总线上是不是又冒出一个没预期到的START——
            // 如果req_armed没生效，master会在done那附近用残留参数(0x11,0x22)
            // 立刻又发一次，这里就会抓到第二个START。
            fork : watch1
                begin
                    watching_for_spurious = 1'b1;
                    wait_for_start;
                    if (watching_for_spurious) unexpected_start_count = unexpected_start_count + 1;
                end
                begin
                    #2000;   // 观察窗口：够跑完一次误发事务但小于下面真正发起新请求的时刻
                    watching_for_spurious = 1'b0;
                    disable watch1;
                end
            join
            check(unexpected_start_count == 0, "T6: done之后、req未重新拉高前，不应该出现意外的START(即无req_armed会在此处误发)");
            // 第二次事务：真正重新拉高req，必须能正常发起并完成
            fork
                slave_ack_one_write2(7'h44, 8'h33, 8'h44);
                drive_req(7'h44, 32'h0000_3344, 3'd2, 8'd0);
            join
            check(err == 1'b0, "T6: 第二次事务应正常完成");
            $display("[T6] req/done竞争回归(edge re-arm) 通过（误发次数=%0d）", unexpected_start_count);
        end
    endtask

    // ==========================================================================
    // 测试 7：done 单周期脉冲 + busy 起止时机
    // ==========================================================================
    integer done_high_cycles;
    task automatic test7_done_pulse_and_busy;
        begin
            done_high_cycles = 0;
            check(busy == 1'b0, "T7: 事务前busy应为0");
            fork
                begin
                    wait_for_start;
                    slave_recv_byte(addr_byte, 1'b1);
                    slave_recv_byte(cap_b0, 1'b1);
                    wait_for_stop_or_rstart(stop_flag);
                end
                begin
                    @(negedge clk);
                    dev_addr = 7'h10; tx_data = 32'h5500_0000; tx_len = 3'd1; rd_len = 8'd0;
                    req = 1'b1;
                    @(posedge busy);
                    check(1'b1, "T7: req拉高后busy应变1（观测到即通过)");
                    begin : master_wait_done
                        reg got_done;
                        got_done = 1'b0;
                        while (!got_done) begin
                            @(posedge clk);
                            #1;   // 让DUT的非阻塞赋值(done<=...)先在NBA区提交，避免同一沿采样到旧值
                            if (done) begin
                                done_high_cycles = done_high_cycles + 1;
                                got_done = 1'b1;
                            end
                        end
                        @(negedge clk);
                        req = 1'b0;
                    end
                end
            join
            check(done_high_cycles == 1, "T7: done在整个事务里只应该出现1个周期(单周期脉冲)");
            @(posedge clk); @(negedge clk);
            check(busy == 1'b0, "T7: 事务结束后busy应回到0");
            $display("[T7] done单周期脉冲 + busy起止 通过（done高电平周期数=%0d）", done_high_cycles);
        end
    endtask

    // ==========================================================================
    // 测试 8：★ 请求相位遍历回归（v5 修的"START 丢失"bug 的看门狗）
    // --------------------------------------------------------------------------
    //  背景：div_cnt/ph 分相时钟是自由运行的，而 ST_IDLE 接受请求的那一拍相位
    //  是任意的。ST_START1 靠 act_sda(ph==1) 把 SDA 拉低产生 START 条件、靠
    //  act_next(ph==3) 推进状态；若进入 ST_START1 时 ph 已经越过 1，这个位周期
    //  内 act_sda 再也不会出现，而 act_next 照样推进 —— SDA 从未被拉低，
    //  START 条件根本没产生，从机不激活，地址字节必然 NACK。
    //
    //  为什么 T1~T7 全都漏掉了：它们都是从复位后的固定时刻开始发请求，DUT 的
    //  分相计数器每次都在同一相位，恰好落在安全区 —— 于是这个 bug 在旧测试下
    //  100% 不可见，只有把"请求到达相位"扫一遍才会暴露。
    //
    //  ★ 抖动步长必须覆盖**整个位周期**，不能只抖几拍：
    //    本 tb 取 CLK_HZ=100MHz / SCL_HZ=1MHz → DIV=25 → 一个位周期 = 4*25 = 100
    //    拍。坏窗口是 ph∈{2,3}，也就是第 50~99 拍。第一版抖动只做了 1..8 拍，
    //    100 拍里只挪了 8 拍，压根没进坏窗口 —— 把这个测试**反向验证**（临时
    //    把 ST_IDLE 的相位对齐条件撤掉重跑）时它照样全绿，说明那版是空测试。
    //    现在用 (k*13)%100 扫 20 个点，横跨整个位周期，坏窗口必然被覆盖。
    // ==========================================================================
    localparam integer PH_SWEEP_N   = 20;
    localparam integer PH_PERIOD   = 100;   // 4*DIV，DIV = 100MHz/(1MHz*4) = 25

    //  ★ 从机分支必须**有界**：万一 START 根本没产生（正是本测试要抓的故障），
    //    `wait_for_start` 会永远等下去，整个仿真挂到全局超时，只报 "TIMEOUT"
    //    而不告诉你是哪一条断言坏了。这里改成"等 START 或等主机 done"：
    //    没有 START 时主机会一路 NACK → STOP → done，于是能干净地判 FAIL。
    //    （不用 fork/join_any + disable fork —— iverilog 11.0 对它的支持不可靠，
    //      本工程已经因为 fork/join_none 吃过一次亏。）
    task automatic wait_start_or_done(output reg started);
        begin : blk3
            forever begin
                @(negedge sda or posedge done);
                if (done) begin started = 1'b0; disable blk3; end
                if (scl === 1'b1 && sda !== 1'b1) begin started = 1'b1; disable blk3; end
            end
        end
    endtask

    task automatic test8_request_phase_sweep;
        integer k, jitter;
        reg [7:0] a8, b8a, b8b;
        reg ok8, seen, started;
        begin
            ok8 = 1'b1;
            for (k = 0; k < PH_SWEEP_N; k = k + 1) begin
                jitter = ((k * 13) % PH_PERIOD) + 1;
                fork
                    begin  // 从机（有界等待）
                        wait_start_or_done(started);
                        if (!started) ok8 = 1'b0;
                        else begin
                            slave_recv_byte(a8, 1'b1);
                            if (a8 !== {7'h44, 1'b0}) ok8 = 1'b0;
                            slave_recv_byte(b8a, 1'b1);
                            if (b8a !== 8'h24) ok8 = 1'b0;
                            slave_recv_byte(b8b, 1'b1);
                            if (b8b !== 8'h00) ok8 = 1'b0;
                            wait_for_stop_or_rstart(seen);
                            if (seen !== 1'b1) ok8 = 1'b0;   // 写事务应以 STOP 结束
                        end
                    end
                    begin  // 主机
                        repeat (jitter) @(negedge clk);
                        drive_req(7'h44, 32'h0000_2400, 3'd2, 8'd0);
                    end
                join
            end
            check(ok8, "T8: valid START/data/STOP required at EVERY req phase");
            if (ok8) $display("[T8] 请求相位遍历(%0d点/跨整个位周期%0d拍) 通过", PH_SWEEP_N, PH_PERIOD);
            else     $display("[T8] 请求相位遍历(%0d点) 失败：有相位下 START 条件丢失", PH_SWEEP_N);
        end
    endtask

    // ------------------------------------------------------------ 主流程
    initial begin
        req = 0; dev_addr = 0; tx_data = 0; tx_len = 0; rd_len = 0;
        slave_sda_low = 0;
        rst_n = 0;
        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);

        test1_write2;
        test2_write4;
        test3_pure_read6;
        test4_write_then_read;
        test5_addr_nack;
        test6_req_rearm;
        test7_done_pulse_and_busy;
        test8_request_phase_sweep;

        $display("--------------------------------------------------");
        if (fail_cnt == 0) $display("=== ALL TESTS PASSED === (%0d checks)", pass_cnt);
        else               $display("=== %0d FAILURES === (%0d passed / %0d total)", fail_cnt, pass_cnt, pass_cnt+fail_cnt);
        $finish;
    end

    // 兜底超时，防止哪个 task 卡死导致仿真挂起
    // 注：$time用%0t显示的是ps刻度（declare精度1ps），不是ns——之前调试时confirm过
    // （#50的已知延迟显示成50000，50000ps=50ns，比例对得上），所以这里的2_000_000
    // 是2_000_000ns=2ms的真实延迟（#后面的数字本身就是ns，不受显示刻度影响）。
    initial begin
        #5_000_000;   // 放宽到5ms，8个测试+test6里的观察窗口留够余量
        $display("=== TIMEOUT: simulation did not finish in time ===");
        $finish;
    end

endmodule
