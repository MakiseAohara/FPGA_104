`timescale 1ns/1ps
// 系统级仿真：合成 1080p 视频(静止→入侵者出现) + SHT30 模型 + MLX90640 模型
module tb_v7_sys #(parameter NOIR = 0);
    localparam HACT=1920,HFP=88,HSP=44,HBP=148,VACT=1080,VFP=4,VSP=5,VBP=36;
    localparam HT=HACT+HFP+HSP+HBP, VT=VACT+VFP+VSP+VBP;
    localparam NF = 7, F_INTR = 3;
    reg clk=0; always #3.367 clk=~clk;
    reg rstn=0; initial begin #200 rstn=1; end
    reg [7:0] r,g,b; reg de,hs,vs;
    reg key_n=1, key_l=1;
    wire scl, sda; pullup(scl); pullup(sda);
    wire c_scl_o,c_scl_oe,c_sda_o,c_sda_oe;
    assign scl = c_scl_oe ? c_scl_o : 1'bz;
    assign sda = c_sda_oe ? c_sda_o : 1'bz;
    wire buzzer; wire [1:0] led; wire alarm_active;
    wire txt_we; wire [7:0] txt_wa, txt_wd; wire th_we; wire [9:0] th_wa; wire [7:0] th_wd;
    wire [7:0] o_r,o_g,o_b; wire o_de,o_hs,o_vs;

    v7_mmt_core #(.CLK_HZ(148_500_000), .SCL_HZ(3_000_000), .SHT_PERIOD_MS(2), .IR_PERIOD_MS(2)) core (
        .clk(clk), .rst_n(rstn), .in_r(r), .in_g(g), .in_b(b), .in_de(de), .in_hs(hs), .in_vs(vs),
        .ai_person(1'b0), .key_night_n(key_n), .key_learn_n(key_l),
        .scl_i(scl), .sda_i(sda), .scl_o(c_scl_o), .scl_oe(c_scl_oe), .sda_o(c_sda_o), .sda_oe(c_sda_oe),
        .buzzer(buzzer), .led(led), .alarm_active(alarm_active),
        .txt_we(txt_we), .txt_wa(txt_wa), .txt_wd(txt_wd), .th_we(th_we), .th_wa(th_wa), .th_wd(th_wd));
    v7_osd_top #(.BLINK_EN(0)) osd (.vclk(clk), .vrst_n(rstn), .i_r(r), .i_g(g), .i_b(b), .i_de(de), .i_hs(hs), .i_vs(vs),
        .o_r(o_r), .o_g(o_g), .o_b(o_b), .o_de(o_de), .o_hs(o_hs), .o_vs(o_vs),
        .alarm_in(alarm_active), .txt_we(txt_we), .txt_wa(txt_wa), .txt_wd(txt_wd), .th_we(th_we), .th_wa(th_wa), .th_wd(th_wd));

    // ---- SHT30 从机：25.3C / 48.2%RH ----
    reg [15:0] sl_addr; reg [7:0] sl_wdata; reg sl_we; wire [7:0] sl_rdata;
    i2c_slave_model #(.ADDR(7'h44), .MEM_N(512)) u_sht (.scl(scl), .sda(sda),
        .mem_addr(sl_addr), .mem_wdata(sl_wdata), .mem_we(sl_we), .mem_rdata(sl_rdata), .nack_addr(1'b0),
        .got_start(), .got_stop(), .addr_matched(), .last_byte(), .last_byte_valid(), .byte_count(), .wr_ptr_out(), .busy());
    task poke(input [15:0] a, input [7:0] d); begin sl_addr=a; sl_wdata=d; sl_we=1; @(posedge clk); sl_we=0; @(posedge clk); end endtask

    // ---- MLX90640 模型 ----
    reg [15:0] pre_a, pre_d; reg pre_we=0; reg set_ready=0;
    mlx90640_model #(.ADDR(7'h33)) u_mlx (.scl(scl), .sda(sda), .pre_word_addr(pre_a), .pre_word_data(pre_d), .pre_we(pre_we),
        .nack_all(1'b0), .set_data_ready(set_ready), .ctrl_reg(), .status_reg(), .status_clr_cnt(), .ctrl_wr_cnt(), .ctrl_wr_val(),
        .last_wr_addr(), .last_wr_data(), .got_start(), .got_stop(), .rd_word_cnt());
    task pre(input [15:0] a, input [15:0] d); begin pre_a=a; pre_d=d; pre_we=1; @(posedge clk); pre_we=0; @(posedge clk); end endtask
    integer i, ir_row, ir_col;
    task load_ir(input hot);
        integer k, rr, cc; reg [15:0] v;
        begin
            for (k=0;k<768;k=k+1) begin
                rr=k/32; cc=k%32;
                v = 16'd1000 + ((rr*7+cc*3)%13)*5 + ((rr+cc)%2)*40;      // 固定偏置图案（棋盘格）
                if (hot && rr>=8 && rr<=16 && cc>=12 && cc<=20) v = v + 16'd260 - ((rr-12)*(rr-12)+(cc-16)*(cc-16))*6;
                pre(16'h0400+k, v);
            end
        end
    endtask
    // 周期性置"数据就绪"，模拟传感器出帧
    reg run_ready=1;
    always begin #6000000; if (run_ready) begin set_ready=1; #20; set_ready=0; end end

    // ---- 视频发生器 ----
    integer x,y,f,fd,seed=1; reg [7:0] nz;
    reg [7:0] base;
    initial begin
        sl_addr=0; sl_wdata=0; sl_we=0;
        poke(0,102); poke(1,214); poke(2,44); poke(3,123); poke(4,100); poke(5,223);
        pre(16'h8000,16'h0000);
        load_ir(0);
        r=0;g=0;b=0;de=0;hs=0;vs=0;
        for (f=0; f<NF; f=f+1) begin
            if (f==F_INTR && !NOIR) begin load_ir(1); end
            for (y=0;y<VT;y=y+1) begin
                for (x=0;x<HT;x=x+1) begin
                    @(posedge clk);
                    vs <= (y>=VFP && y<VFP+VSP);
                    hs <= (x>=HFP && x<HFP+HSP);
                    de <= (y>=VFP+VSP+VBP) && (x>=HFP+HSP+HBP);
                    seed = seed*1103515245+12345; nz = seed[19:18];
                    base = 8'd90 + (((x-(HFP+HSP+HBP))>>6)&31) + (((y-(VFP+VSP+VBP))>>6)&15) + nz;
                    if (f>=F_INTR && (x-(HFP+HSP+HBP))>=800+20*(f-F_INTR) && (x-(HFP+HSP+HBP))<1200+20*(f-F_INTR)
                        && (y-(VFP+VSP+VBP))>=300 && (y-(VFP+VSP+VBP))<800) begin
                        r<=8'd215; g<=8'd170; b<=8'd150;
                    end else begin r<=base; g<=base; b<=base; end
                end
            end
        end
        #2000 $finish;
    end

    // ---- 输出帧抓取 ----
    integer fr=0, fq, fa; reg o_vs_d=0;
    initial begin
        fq=$fopen("quiet.ppm","wb"); $fwrite(fq,"P6\n%0d %0d\n255\n",HACT,VACT);
        fa=$fopen("alarm.ppm","wb"); $fwrite(fa,"P6\n%0d %0d\n255\n",HACT,VACT);
    end
    always @(posedge clk) begin
        o_vs_d<=o_vs;
        if (o_vs & ~o_vs_d) fr<=fr+1;
        if (o_de) begin
            if (fr==F_INTR) $fwrite(fq,"%c%c%c",o_r,o_g,o_b);
            if (fr==NF)     $fwrite(fa,"%c%c%c",o_r,o_g,o_b);
        end
    end
    // ---- 观测 ----
    reg vs_dd=0;
    always @(posedge clk) begin
        vs_dd<=vs;
        if (vs & ~vs_dd) $display("[%0t ms] frame start: area=%0d motion=%b hot=%0d ir_v=%b sht_v=%b score=%0d alarm_act=%b buzz=%b led=%b night=%b",
            $time/1000000, core.fd_area, core.fd_motion, core.hot_delta, core.ir_valid, core.sht_valid, core.score, alarm_active, buzzer, led, core.night);
    end
    always @(posedge core.sht_valid) $display("SHT valid: t=%0d rh=%0d amb_x10=%0d", core.sht_t, core.sht_rh, core.amb_x10);
    initial begin #400000000; $display("TIMEOUT"); $finish; end
endmodule
