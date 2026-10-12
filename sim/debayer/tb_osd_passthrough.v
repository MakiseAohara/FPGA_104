// ============================================================================
//  tb_osd_passthrough.v -- does the OSD overlay pass R/G/B through honestly?
// ----------------------------------------------------------------------------
//  mmt_top.v feeds mmt_osd_overlay like this (mmt_top.v:1388-1390):
//        .i_r (hdmi_tx_bdata)      <-- BLUE into the red input
//        .i_g (hdmi_tx_gdata)
//        .i_b (hdmi_tx_rdata)      <-- RED into the blue input
//  and mmt_osd_overlay's output then goes to dvi_encoder dvi_encoder_m0 with an
//  honest connection (mmt_top.v:1277-1279 .i_rdata(osd_r) ...).
//
//  So if mmt_osd_overlay passes the main video area straight through, the R/B
//  crossing survives to the TMDS encoder and the picture is R/B swapped.
//
//  This testbench instantiates TWO copies of mmt_osd_overlay:
//     u_honest  : i_r <- rdata  (the wiring that should be there)
//     u_swapped : i_r <- bdata  (the wiring that is there today)
//  and prints what each one actually emits on o_r/o_g/o_b for a known pixel.
//
//  Run from D:\FPGA\mmt so that $readmemh("font8x16.hex") resolves.
// ============================================================================
`timescale 1ns/1ps

module tb_osd_passthrough;

    reg clk = 1'b0;
    reg rstn;
    always #5 clk = ~clk;

    // the three bytes that mmt_top.v produces for one pixel (r,g,b)
    reg [7:0] rdata = 8'h11;   // RED
    reg [7:0] gdata = 8'h22;   // GREEN
    reg [7:0] bdata = 8'h33;   // BLUE

    reg       de = 1'b0, hs = 1'b0, vs = 1'b0, alarm = 1'b0;
    reg [7:0] th_d = 8'h00, txt_d = 8'h00;

    // ---- honest copy -----------------------------------------------------
    wire [7:0] h_r, h_g, h_b;
    wire       h_de, h_hs, h_vs;
    wire [9:0] h_tha;
    wire [7:0] h_txa;

    mmt_osd_overlay #(.H_ACTIVE(64), .V_ACTIVE(16)) u_honest (
        .vclk(clk), .vrst_n(rstn),
        .i_r(rdata), .i_g(gdata), .i_b(bdata),
        .i_de(de), .i_hs(hs), .i_vs(vs),
        .o_r(h_r), .o_g(h_g), .o_b(h_b),
        .o_de(h_de), .o_hs(h_hs), .o_vs(h_vs),
        .th_rd_addr(h_tha), .th_rd_data(th_d),
        .txt_rd_addr(h_txa), .txt_rd_data(txt_d),
        .alarm(alarm)
    );

    // ---- copy wired exactly as mmt_top.v:1388-1390 does today -------------
    wire [7:0] s_r, s_g, s_b;
    wire       s_de, s_hs, s_vs;
    wire [9:0] s_tha;
    wire [7:0] s_txa;

    mmt_osd_overlay #(.H_ACTIVE(64), .V_ACTIVE(16)) u_swapped (
        .vclk(clk), .vrst_n(rstn),
        .i_r(bdata), .i_g(gdata), .i_b(rdata),   // <-- the crossing
        .i_de(de), .i_hs(hs), .i_vs(vs),
        .o_r(s_r), .o_g(s_g), .o_b(s_b),
        .o_de(s_de), .o_hs(s_hs), .o_vs(s_vs),
        .th_rd_addr(s_tha), .th_rd_data(th_d),
        .txt_rd_addr(s_txa), .txt_rd_data(txt_d),
        .alarm(alarm)
    );

    // ---- sample the outputs while o_de is high ---------------------------
    reg h_de_d, s_de_d;
    integer line;
    integer pass, fail;

    always @(posedge clk) begin
        h_de_d <= h_de;
        s_de_d <= s_de;
        if (rstn && h_de && !h_de_d) begin
            $display("  line %0d : driven r/g/b = %02h/%02h/%02h", line, rdata, gdata, bdata);
            $display("             honest  (i_r<-rdata) -> o_r/g/b = %02h/%02h/%02h",
                     h_r, h_g, h_b);
            $display("             CURRENT (i_r<-bdata) -> o_r/g/b = %02h/%02h/%02h",
                     s_r, s_g, s_b);
            line = line + 1;
        end
    end

    initial begin
        pass = 0; fail = 0; line = 0;
        rstn = 1'b0; de = 1'b0; hs = 1'b0; vs = 1'b0;
        repeat (20) @(posedge clk);
        rstn = 1'b1;
        repeat (5) @(posedge clk);

        $display("================================================================");
        $display(" mmt_osd_overlay pass-through / R-B wiring test");
        $display(" driven pixel bytes: rdata=%02h (RED) gdata=%02h bdata=%02h (BLUE)",
                 rdata, gdata, bdata);
        $display("================================================================");

        // one short frame, a few lines, no overlay region reached
        vs = 1'b1; hs = 1'b1;
        repeat (4) @(posedge clk);
        vs = 1'b0;
        repeat (4) @(posedge clk);

        for (line = 0; line < 0; line = line + 1) ; // no-op, keeps line var used

        repeat (4) begin
            de = 1'b1;
            repeat (16) @(posedge clk);
            de = 1'b0;
            repeat (8) @(posedge clk);
        end
        repeat (10) @(posedge clk);

        $display("");
        $display("---- verdict ----");
        if (h_r == rdata && h_g == gdata && h_b == bdata) begin
            $display("[PASS] honest wiring passes r/g/b straight through");
            pass = pass + 1;
        end else begin
            $display("[FAIL] honest wiring did NOT pass r/g/b through");
            fail = fail + 1;
        end
        if (s_r == bdata && s_g == gdata && s_b == rdata) begin
            $display("[PASS] CURRENT wiring delivers BLUE (%02h) on o_r -> the red channel", bdata);
            $display("       ... and RED (%02h) on o_b -> the blue channel", rdata);
            $display("       => with an honest encoder connection the picture is R/B SWAPPED");
            pass = pass + 1;
        end else begin
            $display("[FAIL] CURRENT wiring did not reproduce the expected crossing");
            fail = fail + 1;
        end

        $display("");
        $display("[SUMMARY] PASS=%0d FAIL=%0d", pass, fail);
        if (fail == 0) $display("=== OSD PASSTHROUGH TEST: ALL CHECKS PASSED ===");
        else           $display("=== OSD PASSTHROUGH TEST: %0d CHECK(S) FAILED ===", fail);
        $finish;
    end

    initial begin
        #200000;
        $display("[TB] *** TIMEOUT ***");
        $finish;
    end

endmodule
