`timescale 1ns / 1ps
//==========================================================================
//  v7_frame_diff.v — 帧差运动检测（v7 底座版；基于 mmt_frame_diff 的三处改动）
//  1) 背景"首帧直写"：复位/请求后的第一整帧把像素直接写成背景（原版清零后
//     因 >>>5 对正差值向下取整，背景永远追不上，会长期误判运动）
//  2) 背景更新对正差值向上取整（远离 0 取整），可以收敛到当前像素
//  3) pix_vs 用"帧起始脉冲"（vsync 上升沿，位于消隐期），不能与首个有效像素同拍
//==========================================================================
module v7_frame_diff #(
    parameter IMG_W = 160, parameter IMG_H = 120, parameter BG_SHIFT = 5,
    parameter XW = 8, parameter YW = 8, parameter AW = 15
)(
    input  wire        clk, rst_n,
    input  wire [7:0]  pix_data,
    input  wire        pix_de,
    input  wire        pix_vs,
    input  wire [7:0]  threshold,
    input  wire [15:0] min_area,
    input  wire        bg_freeze,
    input  wire        learn_req,
    output reg         frame_done,
    output reg  [15:0] area,
    output reg         motion
);
    localparam PIX_NUM = IMG_W * IMG_H;
    reg [31:0] pix_cnt; reg frame_active;
    reg [7:0] pix_q; reg de_q; reg [31:0] addr_q;
    reg [31:0] acc_area;
    reg learn_pend, learn_cur;
    wire [7:0] bg_q;
    wire [8:0] diff_raw = (pix_q > bg_q) ? ({1'b0,pix_q}-{1'b0,bg_q}) : ({1'b0,bg_q}-{1'b0,pix_q});
    wire mask = (diff_raw > {1'b0,threshold});
    wire signed [9:0] delta = $signed({2'b0,pix_q}) - $signed({2'b0,bg_q});
    wire signed [9:0] step  = (delta > 0) ? ((delta + 10'sd31) >>> BG_SHIFT) : (delta >>> BG_SHIFT);
    wire [7:0] bg_new = bg_q + step[7:0];
    wire bg_we = de_q && (learn_cur || !bg_freeze);
    wire [7:0] bg_wd = learn_cur ? pix_q : bg_new;
    mmt_dpram #(.DW(8), .AW(AW), .DEPTH(PIX_NUM)) u_bg_ram (
        .clk(clk), .we(bg_we), .waddr(addr_q[AW-1:0]), .wdata(bg_wd),
        .raddr(pix_cnt[AW-1:0]), .rdata(bg_q));
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pix_cnt<=0; frame_active<=0; pix_q<=0; de_q<=0; addr_q<=0; acc_area<=0;
            learn_pend<=1; learn_cur<=0; frame_done<=0; area<=0; motion<=0;
        end else begin
            frame_done <= 1'b0;
            if (learn_req) learn_pend <= 1'b1;
            if (pix_vs) begin
                pix_cnt<=0; frame_active<=1'b1; acc_area<=0;
                learn_cur <= learn_pend | learn_req; learn_pend <= 1'b0;
            end else if (pix_de && frame_active && (pix_cnt < PIX_NUM)) begin
                pix_cnt <= pix_cnt + 32'd1;
            end
            pix_q  <= pix_data;
            de_q   <= (pix_de && frame_active && !pix_vs && (pix_cnt < PIX_NUM));
            addr_q <= pix_cnt;
            if (de_q && mask && !learn_cur) acc_area <= acc_area + 32'd1;
            if (frame_active && de_q && (addr_q == PIX_NUM-1)) begin
                frame_active <= 1'b0; frame_done <= 1'b1;
                if (learn_cur) begin learn_cur <= 1'b0; motion <= 1'b0; area <= 16'd0; end
                else begin
                    area   <= acc_area[15:0] + {15'd0, mask};   // 含最后一个像素
                    motion <= ((acc_area + {31'd0,mask}) >= {16'd0,min_area});
                end
            end
        end
    end
endmodule
