`timescale 1ns/1ps
module tb_pwr;
    reg clk=0; always #5 clk=~clk;
    reg rstn=0; initial begin #100 rstn=1; end
    reg [7:0] pix; reg de, vs;
    wire done, motion, frz, alrn, low, pvs; wire [15:0] area;
    v7_pwr_ctl #(.IDLE_FRAMES(8), .DIV(4)) pw (.clk(clk), .rst_n(rstn), .vs_rise(vs), .human(motion), .low_pwr(low), .proc_vs(pvs));
    v7_freeze_ctl #(.FREEZE_MAX(600)) fz (.clk(clk), .rst_n(rstn), .frame_done(done), .motion(motion), .bg_freeze(frz), .auto_learn(alrn));
    v7_frame_diff #(.IMG_W(16), .IMG_H(12), .AW(8)) fd (.clk(clk), .rst_n(rstn), .pix_data(pix), .pix_de(de), .pix_vs(pvs),
        .threshold(8'd25), .min_area(16'd60), .bg_freeze(frz), .learn_req(alrn), .frame_done(done), .area(area), .motion(motion));
    integer f, k, ndone=0, low_since=-1, wake_f=-1, ndone_low=0, nframes_low=0; reg [7:0] level;
    localparam F_INTR = 60;
    always @(posedge clk) if (done) begin ndone <= ndone + 1; if (low) ndone_low <= ndone_low + 1; end
    initial begin
        pix=0; de=0; vs=0; level=100; #300;
        for (f=0; f<80; f=f+1) begin
            level = (f >= F_INTR) ? 8'd200 : 8'd100;
            vs=1; @(posedge clk); vs=0; repeat(23) @(posedge clk);
            for (k=0;k<192;k=k+1) begin pix=level; de=1; @(posedge clk); end
            de=0; repeat(30) @(posedge clk);
            if (low && low_since<0) low_since = f;
            if (low) nframes_low = nframes_low + 1;
            if (f>=F_INTR && !low && wake_f<0) wake_f = f;
        end
        $display("RESULT entered_low_at_frame=%0d frames_in_low=%0d processed_in_low=%0d (expect ~1/4) intrusion_frame=%0d woke_at_frame=%0d final_low=%b",
                 low_since, nframes_low, ndone_low, F_INTR, wake_f, low);
        $finish;
    end
endmodule
