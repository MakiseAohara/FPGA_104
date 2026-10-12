// ============================================================================
//  tb_debayer.v -- Bayer phase / colour-mapping testbench for debayer_top_2to1
// ----------------------------------------------------------------------------
//  Goal: decide, WITHOUT a screen, which colour ends up in which output
//  channel, i.e. whether the pipeline R/B-swaps ("purple picture").
//
//  Method (black box):
//    PART 1  light up ONLY one of the 4 Bayer SITES (x parity, y parity) and
//            see which output channel lights up -> site -> channel mapping.
//    PART 2  for each standard phase (RGGB/BGGR/GRBG/GBRG) and each pure
//            colour field (R/G/B) record the output triplet.  A correct
//            debayer returns (255,0,0)/(0,255,0)/(0,0,255).
//    PART 3  full output grids for the configurations that look correct, so
//            blank/edge lines can be told apart from real colour errors.
//
//  Byte packing on raw_datax4_i.  The RTL swaps bytes twice:
//      mmt_top.v:1067            .raw_datax4_i({ch0_b, ch0_g})
//      debayer_top_2to1.v:79     .i_p({w_gain_data[7:0], w_gain_data[15:8]})
//    net effect:  raw_datax4_i[15:8] -> raw_to_rgb "_0" group
//                 raw_datax4_i[7:0]  -> raw_to_rgb "_1" group
//      PACK=0 : raw = {PIX(x odd ), PIX(x even)}   low byte = even column
//      PACK=1 : raw = {PIX(x even), PIX(x odd )}   low byte = odd  column
//
//  Timing: DE high for W/2 clocks (2 pixels per clock), DE low for a few
//  clocks so line_buffer can reset its address and flip the RAM bank.
//
//  This file is a TESTBENCH; it does not modify any RTL (compiled read-only
//  from rtl\).
// ============================================================================
`timescale 1ns/1ps

module tb_debayer;

    localparam integer W   = 16;       // pixels per line
    localparam integer H   = 16;       // lines per frame
    localparam integer CPL = W/2;      // clocks per line (2 pixels/clock)

    reg  clk = 1'b0;
    reg  rstn;
    always #5 clk = ~clk;

    reg         raw_vs, raw_hs, raw_de, raw_valid;
    reg  [15:0] raw_data;
    wire        rgb_vs, rgb_hs, rgb_de, rgb_valid;
    wire [47:0] rgb_data;

    debayer_top_2to1 dut (
        .in_pclk      (clk),
        .in_rstn      (rstn),
        .raw_vs_i     (raw_vs),
        .raw_hs_i     (raw_hs),
        .raw_de_i     (raw_de),
        .raw_valid_i  (raw_valid),
        .raw_datax4_i (raw_data),
        .rgb_vs_o     (rgb_vs),
        .rgb_hs_o     (rgb_hs),
        .rgb_de_o     (rgb_de),
        .rgb_valid_o  (rgb_valid),
        .rgb_datax2_o (rgb_data)
    );

    // ------------------------------------------------------------------
    //  output capture -- rgb_datax2_o = {r1,g1,b1, r0,g0,b0}
    // ------------------------------------------------------------------
    reg [7:0] c0r [0:23][0:31];
    reg [7:0] c0g [0:23][0:31];
    reg [7:0] c0b [0:23][0:31];
    reg [7:0] c1r [0:23][0:31];
    reg [7:0] c1g [0:23][0:31];
    reg [7:0] c1b [0:23][0:31];

    integer   cap_line, cap_col;
    reg       rgb_de_d;
    integer   pulse_n, pulse_len, pulse_started;
    integer   cap_cols [0:23];

    always @(posedge clk) begin
        rgb_de_d <= rgb_de;

        if (rgb_de && !rgb_de_d) begin
            pulse_len     = 1;
            pulse_started = 1;
        end else if (rgb_de && rgb_de_d) begin
            pulse_len     = pulse_len + 1;
        end
        if (rgb_de_d && !rgb_de) begin
            if (pulse_started == 1 && pulse_n < 12)
                $display("[DE] output line pulse %0d : %0d clocks DE high (capture line %0d)",
                         pulse_n, pulse_len, cap_line);
            pulse_n = pulse_n + 1;
        end

        if (rgb_de && rgb_valid) begin
            if (!rgb_de_d) cap_col = 0;
            if (cap_line < 24 && cap_col < 32) begin
                c0r[cap_line][cap_col] <= rgb_data[23:16];
                c0g[cap_line][cap_col] <= rgb_data[15:8];
                c0b[cap_line][cap_col] <= rgb_data[7:0];
                c1r[cap_line][cap_col] <= rgb_data[47:40];
                c1g[cap_line][cap_col] <= rgb_data[39:32];
                c1b[cap_line][cap_col] <= rgb_data[31:24];
            end
            cap_col = cap_col + 1;
            cap_cols[cap_line] = cap_cols[cap_line] + 1;
        end
        if (rgb_de_d && !rgb_de) cap_line = cap_line + 1;
    end

    // ------------------------------------------------------------------
    //  stimulus helpers
    // ------------------------------------------------------------------
    function [7:0] pix_site;
        input integer x;
        input integer y;
        input integer probe;
        begin
            if (((x % 2) == (probe % 2)) && ((y % 2) == (probe / 2)))
                pix_site = 8'd255;
            else
                pix_site = 8'd0;
        end
    endfunction

    function integer site_colour;      // 0=R 1=G 2=B
        input integer xp;
        input integer yp;
        input integer phase;           // 0=RGGB 1=BGGR 2=GRBG 3=GBRG
        integer c;
        begin
            case (phase)
            0: c = (xp==0 && yp==0) ? 0 : (xp==1 && yp==0) ? 1 :
                     (xp==0 && yp==1) ? 1 : 2;                    // RGGB
            1: c = (xp==0 && yp==0) ? 2 : (xp==1 && yp==0) ? 1 :
                     (xp==0 && yp==1) ? 1 : 0;                    // BGGR
            2: c = (xp==0 && yp==0) ? 1 : (xp==1 && yp==0) ? 0 :
                     (xp==0 && yp==1) ? 2 : 1;                    // GRBG
            default:
               c = (xp==0 && yp==0) ? 1 : (xp==1 && yp==0) ? 2 :
                     (xp==0 && yp==1) ? 0 : 1;                    // GBRG
            endcase
            site_colour = c;
        end
    endfunction

    function [7:0] pix_field;
        input integer x;
        input integer y;
        input integer phase;
        input integer colour;
        begin
            if (site_colour(x % 2, y % 2, phase) == colour)
                pix_field = 8'd255;
            else
                pix_field = 8'd0;
        end
    endfunction

    // spatially varying scene: R ramps with x, G and B flat.
    // Used to check whether an output R/B swap is an EXACT compensation for a
    // row-phase error, or only works for flat colour fields.
    function [7:0] pix_ramp;
        input integer x;
        input integer y;
        input integer phase;
        integer c;
        begin
            c = site_colour(x % 2, y % 2, phase);
            if (c == 0)      pix_ramp = 8'd32 + 8*(x/2);   // R ramp
            else if (c == 1) pix_ramp = 8'd200;            // G flat
            else             pix_ramp = 8'd16;             // B flat
        end
    endfunction

    task drive_frame;
        input integer mode;
        input integer pack;
        input integer a;
        input integer b;
        integer y, c;
        reg [7:0] pe, po;
        begin
            raw_vs = 1'b0; raw_hs = 1'b0; raw_de = 1'b0;
            raw_valid = 1'b0; raw_data = 16'h0000;
            repeat (8) @(posedge clk);
            raw_vs = 1'b1;
            for (y = 0; y < H; y = y + 1) begin
                repeat (2) @(posedge clk);
                raw_de = 1'b1; raw_valid = 1'b1; raw_hs = 1'b1;
                for (c = 0; c < CPL; c = c + 1) begin
                    if (mode == 0) begin
                        pe = pix_site(2*c,     y, a);
                        po = pix_site(2*c + 1, y, a);
                    end else if (mode == 2) begin
                        pe = pix_ramp(2*c,     y, b);
                        po = pix_ramp(2*c + 1, y, b);
                    end else begin
                        pe = pix_field(2*c,     y, b, a);
                        po = pix_field(2*c + 1, y, b, a);
                    end
                    if (pack == 0) raw_data = {po, pe};
                    else           raw_data = {pe, po};
                    @(posedge clk);
                end
                raw_de = 1'b0; raw_valid = 1'b0; raw_hs = 1'b0;
                repeat (4) @(posedge clk);
            end
            repeat (4) @(posedge clk);
            raw_vs = 1'b0;
            repeat (12) @(posedge clk);
        end
    endtask

    task clear_cap;
        integer i, j;
        begin
            @(negedge clk);
            cap_line = 0; cap_col = 0;
            for (i = 0; i < 24; i = i + 1) begin
                cap_cols[i] = 0;
                for (j = 0; j < 32; j = j + 1) begin
                    c0r[i][j] = 8'h00; c0g[i][j] = 8'h00; c0b[i][j] = 8'h00;
                    c1r[i][j] = 8'h00; c1g[i][j] = 8'h00; c1b[i][j] = 8'h00;
                end
            end
        end
    endtask

    // verdict from frame sums
    function [7:0] dom3;
        input integer sr;
        input integer sg;
        input integer sb;
        begin
            if (sr > sg && sr > sb)       dom3 = "R";
            else if (sg > sr && sg > sb)  dom3 = "G";
            else if (sb > sr && sb > sg)  dom3 = "B";
            else if (sr==0 && sg==0 && sb==0) dom3 = "-";
            else dom3 = "?";
        end
    endfunction

    function [63:0] phname;
        input integer phase;
        begin
            case (phase)
            0: phname = "RGGB";
            1: phname = "BGGR";
            2: phname = "GRBG";
            default: phname = "GBRG";
            endcase
        end
    endfunction

    function [63:0] cname;
        input integer colour;
        begin
            case (colour)
            0: cname = "RED";
            1: cname = "GREEN";
            default: cname = "BLUE";
            endcase
        end
    endfunction

    task case_report;
        input integer mode;
        input integer pack;
        input integer a;
        input integer b;
        integer i, j, sr, sg, sb, cnt;
        begin
            sr = 0; sg = 0; sb = 0; cnt = 0;
            // skip lines 0..2 (legacy-tap / filling) and column 0 (blanked)
            for (i = 3; i < 14; i = i + 1)
                for (j = 1; j < CPL; j = j + 1) begin
                    sr = sr + c0r[i][j];
                    sg = sg + c0g[i][j];
                    sb = sb + c0b[i][j];
                    if (c0r[i][j] > 60 || c0g[i][j] > 60 || c0b[i][j] > 60) cnt = cnt + 1;
                end
            if (mode == 0)
                $display("  PACK=%0d site(x%0d,y%0d) -> sumR=%7d sumG=%7d sumB=%7d  bright=%3d  => %0s",
                         pack, a % 2, a / 2, sr, sg, sb, cnt, dom3(sr, sg, sb));
            else
                $display("  PACK=%0d phase=%0s field=%0s -> sumR=%7d sumG=%7d sumB=%7d  bright=%3d  => %0s",
                         pack, phname(b), cname(a), sr, sg, sb, cnt, dom3(sr, sg, sb));
        end
    endtask

    integer pack, probe, phase, colour, i, j;

    initial begin
        rstn = 1'b0;
        raw_vs = 0; raw_hs = 0; raw_de = 0; raw_valid = 0; raw_data = 16'h0;
        cap_line = 0; cap_col = 0; pulse_n = 0; pulse_len = 0; pulse_started = 0;
        for (i = 0; i < 24; i = i + 1) cap_cols[i] = 0;
        repeat (10) @(posedge clk);
        rstn = 1'b1;
        repeat (5) @(posedge clk);

        $display("================================================================");
        $display(" debayer_top_2to1 -- Bayer phase / colour mapping test");
        $display(" W=%0d H=%0d, 2 pixels/clock, all gains 3'd4 (= x1.0 pass-through)", W, H);
        $display("================================================================");

        $display("");
        $display("---- PART 1: single bright Bayer site -> output channel ----");
        for (pack = 0; pack <= 1; pack = pack + 1)
            for (probe = 0; probe <= 3; probe = probe + 1) begin
                clear_cap;
                drive_frame(0, pack, probe, 0);
                case_report(0, pack, probe, 0);
            end

        $display("");
        $display("---- PART 2: pure colour field -> output triplet ----");
        $display("   a correct debayer gives: RED -> R, GREEN -> G, BLUE -> B");
        for (pack = 0; pack <= 1; pack = pack + 1)
            for (phase = 0; phase <= 3; phase = phase + 1)
                for (colour = 0; colour <= 2; colour = colour + 1) begin
                    clear_cap;
                    drive_frame(1, pack, colour, phase);
                    case_report(1, pack, colour, phase);
                end

        $display("");
        $display("---- PART 3a: grid PACK=1 phase=RGGB RED field (r0/g0/b0) ----");
        clear_cap;
        drive_frame(1, 1, 0, 0);
        for (i = 0; i < 12; i = i + 1) begin
            $write("   L%0d(%0d):", i, cap_cols[i]);
            for (j = 0; j < 8; j = j + 1)
                $write(" %3d/%3d/%3d", c0r[i][j], c0g[i][j], c0b[i][j]);
            $write("\n");
        end

        $display("");
        $display("---- PART 3b: grid PACK=0 phase=GRBG RED field (r0/g0/b0) ----");
        clear_cap;
        drive_frame(1, 0, 0, 2);
        for (i = 0; i < 12; i = i + 1) begin
            $write("   L%0d(%0d):", i, cap_cols[i]);
            for (j = 0; j < 8; j = j + 1)
                $write(" %3d/%3d/%3d", c0r[i][j], c0g[i][j], c0b[i][j]);
            $write("\n");
        end

        $display("");
        $display("---- PART 4: ramp scene (R ramps with x, G=200, B=16) ----");
        $display("   interior output line 6, columns 1..7, printed r/g/b");
        for (phase = 0; phase <= 1; phase = phase + 1) begin
            clear_cap;
            drive_frame(2, 1, 0, phase);
            $write("   PACK=1 phase=%0s :", phname(phase));
            for (j = 1; j < 8; j = j + 1)
                $write("  %3d/%3d/%3d", c0r[6][j], c0g[6][j], c0b[6][j]);
            $write("\n");
        end

        $display("");
        $display("=== DEBAYER TEST DONE ===");
        $finish;
    end

    initial begin
        #5000000;
        $display("[TB] *** GLOBAL TIMEOUT ***");
        $finish;
    end

endmodule
