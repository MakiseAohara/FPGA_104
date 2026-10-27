// MERGE15: v7_ir_proc 死锁恢复 + 热像素计数仿真
//  (a) 首帧学习后注入 +100 偏移：旧版 freeze_prev 永远为 1；新版 RECOVER_FRAMES 后自动重学
//  (b) 6 个热像素 -> hot_cnt=6/ir_hot=1；1 个噪声点 -> hot_cnt=1/ir_hot=0
`timescale 1ns / 1ps
module tb_ir_proc_v15;
    reg clk = 0, rst_n = 0;
    reg frame_valid = 0, learn_req = 0, ai_person = 0;
    reg [15:0] raw_base = 16'd1000;
    integer    hot_n = 0;
    reg [15:0] hot_off = 16'd0;

    wire [9:0] ra_new, ra_old;
    reg  [15:0] rd_new, rd_old;
    wire [7:0]  hc_new, hc_old;
    wire [15:0] hd_new, hd_old;
    wire        v_new, v_old;

    always #5 clk = ~clk;

    // 每帧像素数据：raw_base + (addr < hot_n ? hot_off : 0)
    always @* begin
        rd_new = raw_base + ((ra_new < hot_n) ? hot_off : 16'd0);
        rd_old = raw_base + ((ra_old < hot_n) ? hot_off : 16'd0);
    end

    v7_ir_proc #(.RECOVER_FRAMES(240)) u_new (
        .clk(clk), .rst_n(rst_n), .frame_valid(frame_valid), .learn_req(learn_req),
        .ai_person(ai_person), .hot_cnt(hc_new),
        .rd_addr(ra_new), .rd_data(rd_new), .heat_we(), .heat_wa(), .heat_wd(),
        .hot_delta(hd_new), .valid(v_new));

    // 旧版（MERGE14）作为死锁对照，端口无 ai_person/hot_cnt
    v7_ir_proc_old u_old (
        .clk(clk), .rst_n(rst_n), .frame_valid(frame_valid), .learn_req(learn_req),
        .rd_addr(ra_old), .rd_data(rd_old), .heat_we(), .heat_wa(), .heat_wd(),
        .hot_delta(hd_old), .valid(v_old));

    integer errors = 0;
    integer i, new_rec = -1, old_locked = 0;
    integer old_frozen_frames = 0;
    reg sim_ir_hot;

    task automatic do_frame(input [15:0] base, input integer hn, input [15:0] off);
        begin
            raw_base = base; hot_n = hn; hot_off = off;
            frame_valid <= 1'b1;
            @(posedge clk); @(posedge clk);
            frame_valid <= 1'b0;
            repeat (4*768 + 80) @(posedge clk);
        end
    endtask

    task check(input cond, input [511:0] name);
        begin
            if (cond) $display("  PASS %0s", name);
            else begin errors = errors + 1; $display("  FAIL %0s", name); end
        end
    endtask

    initial begin
        $display("=== MERGE15 TB: v7_ir_proc deadlock recovery + hot count ===");
        rst_n = 0; repeat (6) @(posedge clk); rst_n = 1; repeat (4) @(posedge clk);

        // 首帧：学习基线 raw=1000
        do_frame(16'd1000, 0, 16'd0);
        $display("  after learn frame: new freeze=%b old freeze=%b", u_new.freeze_prev, u_old.freeze_prev);
        check((u_new.freeze_prev == 0) && (u_old.freeze_prev == 0), "first learn frame clears freeze");

        // (a) 注入 +100 偏移，连续 60 帧（RECOVER_FRAMES=20，覆盖 20 帧门槛）
        ai_person = 0;
        for (i = 0; i < 300; i = i + 1) begin
            do_frame(16'd1100, 0, 16'd0);
            if (u_old.freeze_prev == 1) old_frozen_frames = old_frozen_frames + 1;
            if ((new_rec < 0) && (u_new.freeze_prev == 0) && (i > 2)) new_rec = i;
        end
        $display("  after 300 frames offset: new freeze=%b (recovered at frame %0d) old freeze=%b (frozen frames=%0d)",
                 u_new.freeze_prev, new_rec, u_old.freeze_prev, old_frozen_frames);
        check((new_rec >= 0) && (new_rec <= 260), "new recovers within RECOVER_FRAMES+margin (240 frames=30s@125ms)");
        check((u_old.freeze_prev == 1) && (old_frozen_frames >= 55), "old stays locked (MERGE14 behavior reproduced)");

        // ai_person=1 时不应自动重学（先注入偏移，保持有人）
        ai_person = 1;
        for (i = 0; i < 250; i = i + 1) do_frame(16'd1200, 0, 16'd0);
        check(u_new.freeze_prev == 1, "ai_person=1 blocks auto relearn");
        ai_person = 0;
        for (i = 0; i < 300; i = i + 1) do_frame(16'd1200, 0, 16'd0);
        check(u_new.freeze_prev == 0, "recovery resumes after ai_person=0");

        // (b) 热像素计数：先让基线=当前值（上一步已重学为 1200）
        //     本帧 6 个像素 heat=100 (>NOISE=12) -> hot_cnt=6, 模拟 ir_hot=1
        do_frame(16'd1200, 6, 16'd100);
        sim_ir_hot = v_new && (hc_new >= 6);
        $display("  6 hot pixels: hot_cnt=%0d ir_hot(sim)=%b", hc_new, sim_ir_hot);
        check((hc_new == 6) && (sim_ir_hot == 1), "6 hot pixels -> hot_cnt=6, ir_hot=1");

        // 1 个热像素 -> hot_cnt=1, 模拟 ir_hot=0
        do_frame(16'd1200, 1, 16'd100);
        sim_ir_hot = v_new && (hc_new >= 6);
        $display("  1 hot pixel: hot_cnt=%0d ir_hot(sim)=%b", hc_new, sim_ir_hot);
        check((hc_new == 1) && (sim_ir_hot == 0), "1 hot pixel -> hot_cnt=1, ir_hot=0");

        // 无热像素 -> 0
        do_frame(16'd1200, 0, 16'd0);
        check(hc_new == 0, "no hot pixel -> hot_cnt=0");

        #20;
        if (errors == 0) $display("=== RESULT: ALL TESTS PASSED ===");
        else             $display("=== RESULT: TESTS FAILED (%0d) ===", errors);
        $finish;
    end
endmodule
