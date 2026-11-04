`timescale 1ns/1ps
// RGB888 overlay. txt/th inputs are synchronous RAM outputs (one clock).
// Four register stages align ROM reads, region masks, video and sync signals.
module mmt_osd_overlay #(
    parameter H_ACTIVE=1920, V_ACTIVE=1080, XW=11, YW=11,
    parameter TH_SCALE=8, TH_X0=1632, TH_Y0=32,
    parameter FONT_W=8, FONT_H=16, TXT_SCALE=2,
    parameter TXT_COLS=48, TXT_LINES=3, TXT_X0=40, TXT_Y0=960,
    parameter BORDER=8
)(
    input wire vclk, vrst_n,
    input wire [7:0] i_r, i_g, i_b,
    input wire i_de, i_hs, i_vs,
    output reg [7:0] o_r, o_g, o_b,
    output reg o_de, o_hs, o_vs,
    output wire [9:0] th_rd_addr,
    input wire [7:0] th_rd_data,
    output wire [7:0] txt_rd_addr,
    input wire [7:0] txt_rd_data,
    input wire alarm
);
    reg [7:0] font_rom [0:1519];
    initial $readmemh("font8x16.hex",font_rom);
    reg [XW-1:0] x_next;
    reg [YW-1:0] y_line;
    reg de_d, vs_d;
    wire first_pixel=i_de && !de_d;
    wire [XW-1:0] x=first_pixel ? {XW{1'b0}} : x_next;
    wire [YW-1:0] y=first_pixel ? y_line+1'b1 : y_line;
    always @(posedge vclk or negedge vrst_n) begin
        if (!vrst_n) begin
            x_next<=0; y_line<={YW{1'b1}}; de_d<=0; vs_d<=0;
        end else begin
            de_d<=i_de; vs_d<=i_vs;
            if (i_vs && !vs_d) begin x_next<=0; y_line<={YW{1'b1}}; end
            else if (i_de) begin
                x_next<=x+1'b1;
                if (first_pixel) y_line<=y;
            end
        end
    end
    wire thermal=i_de && x>=TH_X0 && x<TH_X0+32*TH_SCALE &&
        y>=TH_Y0 && y<TH_Y0+24*TH_SCALE;
    wire text_area=i_de && x>=TXT_X0 && x<TXT_X0+TXT_COLS*FONT_W*TXT_SCALE &&
        y>=TXT_Y0 && y<TXT_Y0+TXT_LINES*FONT_H*TXT_SCALE;
    wire border=i_de && alarm && (x<BORDER || x>=H_ACTIVE-BORDER ||
        y<BORDER || y>=V_ACTIVE-BORDER);
    wire [XW-1:0] tx=x-TXT_X0;
    wire [YW-1:0] ty=y-TXT_Y0;
    // Text is contiguous: line*48+column, matching sw/main.c (not stride 64).
    assign txt_rd_addr=text_area ? (ty/(FONT_H*TXT_SCALE))*TXT_COLS+
        tx/(FONT_W*TXT_SCALE) : 0;
    assign th_rd_addr=thermal ? ((y-TH_Y0)/TH_SCALE)*32+(x-TH_X0)/TH_SCALE : 0;
    wire [3:0] row=(ty/TXT_SCALE)%FONT_H;
    wire [2:0] col=(tx/TXT_SCALE)%FONT_W;

    reg [23:0] rgb0,rgb1,rgb2;
    // flags = {vs,hs,de,border,text,thermal}
    reg [5:0] f0,f1,f2;
    reg [3:0] row0;
    reg [2:0] col0,col1;
    reg [7:0] font1,heat1,heat2;
    reg font_bit2;
    wire [6:0] ch=(txt_rd_data>=32 && txt_rd_data<=126) ? txt_rd_data-32 : 0;
    wire [10:0] font_addr={ch,row0};
    always @(posedge vclk or negedge vrst_n) begin
        if (!vrst_n) begin
            rgb0<=0; rgb1<=0; rgb2<=0; f0<=0; f1<=0; f2<=0;
            row0<=0; col0<=0; col1<=0; heat1<=0; heat2<=0; font_bit2<=0;
        end else begin
            rgb0<={i_r,i_g,i_b}; f0<={i_vs,i_hs,i_de,border,text_area,thermal};
            row0<=row; col0<=col;
            rgb1<=rgb0; f1<=f0; col1<=col0; heat1<=th_rd_data;
            rgb2<=rgb1; f2<=f1; heat2<=heat1; font_bit2<=font1[7-col1];
        end
    end
    // Dedicated synchronous ROM read, without reset on the memory output.
    always @(posedge vclk) font1<=font_rom[font_addr];
    reg [23:0] heat_rgb;
    always @* begin
        if (heat2<86) heat_rgb={(heat2*8'd3),8'd0,8'd0};
        else if (heat2<171) heat_rgb={8'd255,((heat2-8'd86)*8'd3),8'd0};
        else heat_rgb={8'd255,8'd255,((heat2-8'd171)*8'd3)};
    end
    always @(posedge vclk or negedge vrst_n) begin
        if (!vrst_n) begin
            o_r<=0; o_g<=0; o_b<=0; o_de<=0; o_hs<=0; o_vs<=0;
        end else begin
            {o_vs,o_hs,o_de}<=f2[5:3];
            if (f2[2]) {o_r,o_g,o_b}<=24'hff0000;
            else if (f2[1]) begin
                if (font_bit2) {o_r,o_g,o_b}<=24'h00ff00;
                else {o_r,o_g,o_b}<={1'b0,rgb2[23:17],1'b0,rgb2[15:9],1'b0,rgb2[7:1]};
            end else if (f2[0]) {o_r,o_g,o_b}<=heat_rgb;
            else {o_r,o_g,o_b}<=rgb2;
        end
    end
endmodule
