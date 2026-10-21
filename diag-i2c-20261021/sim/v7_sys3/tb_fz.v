`timescale 1ns/1ps
// 单元测试：场景永久变化后，背景冻结死锁是否被 FREEZE_MAX 自动重学习解除
module tb_fz #(parameter FM = 20);
    reg clk=0; always #5 clk=~clk;
    reg rstn=0; initial begin #100 rstn=1; end
    reg [7:0] pix; reg de, vs;
    wire done, motion, frz, alrn; wire [15:0] area;
    v7_freeze_ctl #(.FREEZE_MAX(FM)) fz (.clk(clk), .rst_n(rstn), .frame_done(done), .motion(motion), .bg_freeze(frz), .auto_learn(alrn));
    v7_frame_diff #(.IMG_W(16), .IMG_H(12), .AW(8)) fd (.clk(clk), .rst_n(rstn), .pix_data(pix), .pix_de(de), .pix_vs(vs),
        .threshold(8'd25), .min_area(16'd60), .bg_freeze(frz), .learn_req(alrn),
        .frame_done(done), .area(area), .motion(motion));
    integer f, k, nmot_after = 0, first_mot = -1, last_mot = -1, relearns = 0;
    reg [7:0] level;
    always @(posedge clk) if (alrn) relearns <= relearns + 1;
    always @(posedge clk) if (done) begin
        if (motion && first_mot < 0) first_mot = f;
        if (motion) last_mot = f;
    end
    initial begin
        pix=0; de=0; vs=0; level=100;
        #300;
        for (f=0; f<90; f=f+1) begin
            level = (f < 6) ? 8'd100 : 8'd200;          // 第 6 帧起场景永久变亮（模拟曝光/开灯）
            vs=1; @(posedge clk); vs=0; repeat(23) @(posedge clk);
            for (k=0; k<192; k=k+1) begin pix = level; de=1; @(posedge clk); end
            de=0; repeat(30) @(posedge clk);
        end
        $display("RESULT FM=%0d first_motion_frame=%0d last_motion_frame=%0d auto_learn_pulses=%0d final_motion=%b", FM, first_mot, last_mot, relearns, motion);
        $finish;
    end
endmodule
