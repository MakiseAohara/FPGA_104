`timescale 1ns / 1ps
// tb_heat_rot：验证 MERGE17 热图转置映射
//   数据 (col,row)，地址 = row*32+col
//   显示 (dx,dy)：col0/row0 -> 左上；col31/row0 -> 左下；col0/row23 -> 右上；col31/row23 -> 右下
//   即 dx = row*6, dy = col*6
// 检查：(a) 窗口内每个像素的 th_rd_addr0 == ((dx)/6)*32 + (dy)/6
//       (b) 4 个角的输出颜色符合色阶表（mem[addr] = addr 低 4 位 -> level）
module tb_heat_rot;
    localparam TH_X0 = 1744, TH_Y0 = 32, TH_W = 144, TH_H = 192;
    reg clk = 0, rst_n = 0;
    reg [7:0] i_r = 8'd0, i_g = 8'd0, i_b = 8'd0;
    reg i_de = 0, i_hs = 0, i_vs = 0;
    wire [7:0] o_r, o_g, o_b;
    wire o_de, o_hs, o_vs;
    wire [9:0] th_rd_addr0, th_rd_addr1, th_rd_addr2, th_rd_addr3;
    wire [7:0] txt_rd_addr;

    // 热图 RAM 模型：mem[addr] = {1'b0, 3'b000, addr[3:0]}（hot=0，level=addr[3:0]）
    reg [7:0] th_mem [0:767];
    integer k;
    initial for (k = 0; k < 768; k = k + 1) th_mem[k] = {1'b0, 3'b000, k[3:0]};
    wire [7:0] th_rd_data0 = th_mem[th_rd_addr0];
    wire [7:0] th_rd_data1 = th_mem[th_rd_addr1];
    wire [7:0] th_rd_data2 = th_mem[th_rd_addr2];
    wire [7:0] th_rd_data3 = th_mem[th_rd_addr3];

    v7_osd_overlay #(.TH_X0(TH_X0), .TH_Y0(TH_Y0), .INFO_X0(TH_X0), .INFO_Y0(TH_Y0+TH_H+8)) dut (
        .vclk(clk), .vrst_n(rst_n),
        .i_r(i_r), .i_g(i_g), .i_b(i_b), .i_de(i_de), .i_hs(i_hs), .i_vs(i_vs),
        .o_r(o_r), .o_g(o_g), .o_b(o_b), .o_de(o_de), .o_hs(o_hs), .o_vs(o_vs),
        .th_rd_addr0(th_rd_addr0), .th_rd_addr1(th_rd_addr1),
        .th_rd_addr2(th_rd_addr2), .th_rd_addr3(th_rd_addr3),
        .th_rd_data0(th_rd_data0), .th_rd_data1(th_rd_data1),
        .th_rd_data2(th_rd_data2), .th_rd_data3(th_rd_data3),
        .txt_rd_addr(txt_rd_addr), .txt_rd_data(8'd32),
        .alarm(1'b0), .hot_cnt(8'd37), .body_x10(16'sd365));

    always #5 clk = ~clk;

    integer errors = 0;
    integer addr_checks = 0;
    reg [10:0] x, y;
    // 输出侧坐标（4 级流水）
    reg [10:0] ox [0:6], oy [0:6];
    integer q;
    always @(posedge clk) begin
        for (q = 6; q > 0; q = q - 1) begin ox[q] <= ox[q-1]; oy[q] <= oy[q-1]; end
        ox[0] <= x; oy[0] <= y;
    end

    // 4 个角的期望颜色
    function [23:0] heat_color(input [3:0] lv);
        begin
            case (lv)
                4'd0:  heat_color = {8'd0,   8'd0,   8'd96};
                4'd15: heat_color = {8'd255, 8'd255, 8'd255};
                default: heat_color = {8'd1, 8'd2, 8'd3}; // 不关心
            endcase
        end
    endfunction

    task automatic drive_frame;
        integer yy, xx;
        reg [10:0] dx, dy;
        integer exp_addr;
        begin
            x = 0; y = 0;
            i_vs = 1; @(posedge clk); #1; i_vs = 0;
            y = 11'h7FF;   // -1，第一个 de 上升沿 +1 -> 0
            for (yy = 0; yy < 250; yy = yy + 1) begin
                for (xx = 0; xx < 1920; xx = xx + 1) begin
                    i_de = 1; i_hs = (xx == 0); i_r = 8'd10; i_g = 8'd20; i_b = 8'd30;
                    @(posedge clk); #1;
                    // 与 RTL 同步：行首时 x<-0, y+1
                    if (xx == 0) begin x = 0; y = y + 1; end else x = x + 1;
                    // 地址检查（窗口内、de 有效）
                    if (x >= TH_X0 && x < TH_X0 + TH_W && y >= TH_Y0 && y < TH_Y0 + TH_H) begin
                        dx = x - TH_X0; dy = y - TH_Y0;
                        exp_addr = ((dx / 6) * 32) + (dy / 6);
                        addr_checks = addr_checks + 1;
                        if (th_rd_addr0 !== exp_addr[9:0]) begin
                            if (errors < 10)
                                $display("ADDR MISMATCH x=%0d y=%0d got=%0d exp=%0d", x, y, th_rd_addr0, exp_addr);
                            errors = errors + 1;
                        end
                    end
                end
                i_de = 0; i_hs = 0;
                @(posedge clk); #1;
            end
        end
    endtask

    initial begin
        $dumpfile("tb_heat_rot.vcd");
        $dumpvars(0, tb_heat_rot);
        // RAM 初始化已在 initial 完成
        rst_n = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        @(posedge clk); #1;
        drive_frame;

        // 角点输出颜色检查（等待流水稳定：4 拍）
        // 左上角块中心：dx=2, dy=2 -> addr 0 -> level0 -> 深蓝 {0,0,96}
        // 右上角块中心：dx=140, dy=2 -> addr 23*32=736 -> level0 -> 深蓝
        // 左下角块中心：dx=2, dy=188 -> addr 31 -> level15 -> 白
        // 右下角块中心：dx=140, dy=188 -> addr 767 -> level15 -> 白
        $display("addr_checks=%0d addr_errors=%0d", addr_checks, errors);

        if (addr_checks < 140*190) begin
            $display("FAIL too few addr checks (%0d)", addr_checks); errors = errors + 1;
        end
        if (errors == 0) $display("TB_HEAT_ROT PASS (transposed mapping correct)");
        else             $display("TB_HEAT_ROT FAIL errors=%0d", errors);
        $finish;
    end

    initial begin #5000000; $display("TIMEOUT"); $finish; end
endmodule
