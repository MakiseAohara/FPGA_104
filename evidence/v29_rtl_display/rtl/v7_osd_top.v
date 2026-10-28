//==========================================================================
//  v7_osd_top.v — OSD 封装（M3：文字RAM/热力图RAM 由 v7_mmt_core 写入）
//  MERGE16: 透传 hot_cnt / body_x10 给 overlay 的信息条
//==========================================================================
`timescale 1ns / 1ps
module v7_osd_top #(
    parameter BLINK_BIT = 25,
    parameter BLINK_EN  = 1
)(
    input  wire        vclk, vrst_n,
    input  wire [7:0]  i_r, i_g, i_b,
    input  wire        i_de, i_hs, i_vs,
    output wire [7:0]  o_r, o_g, o_b,
    output wire        o_de, o_hs, o_vs,
    input  wire        alarm_in,
    input  wire        txt_we, input wire [7:0] txt_wa, input wire [7:0] txt_wd,
    input  wire        th_we,  input wire [9:0] th_wa,  input wire [7:0] th_wd,
    // MERGE16
    input  wire [7:0]  hot_cnt,
    input  wire signed [15:0] body_x10
);
    reg [BLINK_BIT:0] blink_cnt;
    always @(posedge vclk or negedge vrst_n)
        if (!vrst_n) blink_cnt <= 0; else blink_cnt <= blink_cnt + 1'b1;
    wire alarm = alarm_in & ((BLINK_EN==0) ? 1'b1 : blink_cnt[BLINK_BIT]);

    reg [7:0] txt_ram [0:255];
    always @(posedge vclk) if (txt_we) txt_ram[txt_wa] <= txt_wd;
    wire [7:0] txt_rd_addr; reg [7:0] txt_rd_data;
    always @(posedge vclk) txt_rd_data <= txt_ram[txt_rd_addr];

    // 热力图 RAM 复制 4 份（MERGE16 只用第 0 份，保留接口兼容）
    reg [7:0] th_ram0 [0:1023]; reg [7:0] th_ram1 [0:1023]; reg [7:0] th_ram2 [0:1023]; reg [7:0] th_ram3 [0:1023];
    always @(posedge vclk) if (th_we) begin th_ram0[th_wa] <= th_wd; th_ram1[th_wa] <= th_wd; th_ram2[th_wa] <= th_wd; th_ram3[th_wa] <= th_wd; end
    wire [9:0] th_a0, th_a1, th_a2, th_a3; reg [7:0] th_d0, th_d1, th_d2, th_d3;
    always @(posedge vclk) begin th_d0 <= th_ram0[th_a0]; th_d1 <= th_ram1[th_a1]; th_d2 <= th_ram2[th_a2]; th_d3 <= th_ram3[th_a3]; end

    v7_osd_overlay u_osd (
        .vclk(vclk), .vrst_n(vrst_n),
        .i_r(i_r), .i_g(i_g), .i_b(i_b), .i_de(i_de), .i_hs(i_hs), .i_vs(i_vs),
        .o_r(o_r), .o_g(o_g), .o_b(o_b), .o_de(o_de), .o_hs(o_hs), .o_vs(o_vs),
        .th_rd_addr0(th_a0), .th_rd_addr1(th_a1), .th_rd_addr2(th_a2), .th_rd_addr3(th_a3),
        .th_rd_data0(th_d0), .th_rd_data1(th_d1), .th_rd_data2(th_d2), .th_rd_data3(th_d3),
        .txt_rd_addr(txt_rd_addr), .txt_rd_data(txt_rd_data),
        .alarm(alarm),
        .hot_cnt(hot_cnt), .body_x10(body_x10));
endmodule
