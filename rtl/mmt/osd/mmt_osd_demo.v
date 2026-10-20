`timescale 1ns/1ps
// Bring-up display only. The heatmap is a ROM pattern, not sensor telemetry.
// All signals use the existing HDMI pixel domain; no new board pins.
module mmt_osd_demo(
    input wire clk, rst_n,
    input wire [7:0] i_r,i_g,i_b,
    input wire i_de,i_hs,i_vs,
    input wire alarm,
    output wire [7:0] o_r,o_g,o_b,
    output wire o_de,o_hs,o_vs
);
    wire [9:0] th_addr;
    wire [7:0] txt_addr;
    reg [7:0] th_data,txt_data;
    reg [7:0] text_rom [0:143];
    initial $readmemh("osd_demo_text.hex",text_rom);
    always @(posedge clk) begin
        th_data<={th_addr[4:0],3'b000};
        txt_data<=(txt_addr<144) ? text_rom[txt_addr] : 8'd32;
    end
    reg vs_d;
    reg [7:0] frame_count;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin vs_d<=0;frame_count<=0;end
        else begin
            vs_d<=i_vs;
            if(i_vs && !vs_d) frame_count<=frame_count+1'b1;
        end
    end
    mmt_osd_overlay overlay(
        .vclk(clk),.vrst_n(rst_n),.i_r(i_r),.i_g(i_g),.i_b(i_b),
        .i_de(i_de),.i_hs(i_hs),.i_vs(i_vs),
        .o_r(o_r),.o_g(o_g),.o_b(o_b),.o_de(o_de),.o_hs(o_hs),.o_vs(o_vs),
        .th_rd_addr(th_addr),.th_rd_data(th_data),
        .txt_rd_addr(txt_addr),.txt_rd_data(txt_data),.alarm(alarm));
endmodule
