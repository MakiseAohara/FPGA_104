//==========================================================================
//  v7_osd_overlay.v — MERGE16: 热图重做（6× 放大/不透明/16 档自动色阶/hot 红框）
//                            + 热图下方信息条（HOT 像素数 / EST 体表温度）
//
//  与 MERGE15 的差异：
//   1) 热图窗口 32×24 放大 6 倍并**转置**：显示宽=行数24×6=144、高=列数32×6=192，右上角 (TH_X0=1744, TH_Y0=32)；
//      窗口内**不透明**：色阶 0 也画深蓝，不再透出原视频。
//   2) 色阶 16 档查表：蓝->青->绿->黄->红->白（色阶由 v7_ir_proc 按帧 min/max 拉伸）。
//      热图 RAM 字节：bit7 = 该像素 hot（d_pos>NOISE），bit[3:0] = 0..15 色阶。
//   3) hot 像素在 6×6 块的四边画 1 像素红框（块内仍显示色阶）。
//   4) 热图下方信息条（5×7 点阵，字符格 6×8）：
//        HOT=<0..255> EST=<0..45>.<0..9>C
//      hot_cnt / body_x10 由 v7_mmt_core 提供。
//  原有主文字（3 行 × 48 字符）与报警红框逻辑保持不变。
//==========================================================================
`timescale 1ns / 1ps

module v7_osd_overlay #(
    parameter H_ACTIVE   = 1920,
    parameter V_ACTIVE   = 1080,
    parameter XW         = 11,
    parameter YW         = 11,
    // ---- 温度热力图小窗 ----
    parameter TH_SCALE   = 6,           // MERGE16: 4 -> 6（32×24 -> 192×144）
    parameter TH_X0      = 1744,        // MERGE17: 1920-144-32（右侧留 32 边距）
    parameter TH_Y0      = 32,
    // ---- 主文字 ----
    parameter FONT_W     = 8,
    parameter FONT_H     = 16,
    parameter TXT_SCALE  = 2,
    parameter TXT_COLS   = 48,
    parameter TXT_LINES  = 3,
    parameter TXT_X0     = 40,
    parameter TXT_Y0     = 960,
    parameter BORDER     = 8,
    // ---- 信息条（热图下方） ----
    parameter INFO_X0    = 1744,
    parameter INFO_Y0    = 232,         // MERGE17: 32 + 192 + 8
    parameter INFO_CW    = 6,           // 字符格宽（5×7 点阵 + 1 间隔）
    parameter INFO_CH    = 8            // 字符格高
)(
    input  wire        vclk,
    input  wire        vrst_n,

    input  wire [7:0]  i_r,
    input  wire [7:0]  i_g,
    input  wire [7:0]  i_b,
    input  wire        i_de,
    input  wire        i_hs,
    input  wire        i_vs,

    output reg  [7:0]  o_r,
    output reg  [7:0]  o_g,
    output reg  [7:0]  o_b,
    output reg         o_de,
    output reg         o_hs,
    output reg         o_vs,

    // 热力图数据（bit7=hot, bit[3:0]=色阶）
    output wire [9:0]  th_rd_addr0, th_rd_addr1, th_rd_addr2, th_rd_addr3,
    input  wire [7:0]  th_rd_data0, th_rd_data1, th_rd_data2, th_rd_data3,

    // 主文字
    output wire [7:0]  txt_rd_addr,
    input  wire [7:0]  txt_rd_data,

    input  wire        alarm,
    // MERGE16: 信息条
    input  wire [7:0]  hot_cnt,
    input  wire signed [15:0] body_x10
);

    //====================================================================
    // 主字模 ROM：8×16 × 95 字符
    //====================================================================
    reg [7:0] font_rom [0:1519];
    initial begin
        $readmemh("v7_font8x16.hex", font_rom);
    end

    //====================================================================
    // 坐标提取
    //====================================================================
    reg [XW-1:0] x_cnt;
    reg [YW-1:0] y_cnt;
    reg          de_d, vs_d;
    reg          in_frame;

    wire vs_rise = i_vs & ~vs_d;
    wire de_rise = i_de & ~de_d;

    always @(posedge vclk or negedge vrst_n) begin
        if (!vrst_n) begin
            x_cnt    <= {XW{1'b0}};
            y_cnt    <= {YW{1'b1}};
            de_d     <= 1'b0;
            vs_d     <= 1'b0;
            in_frame <= 1'b0;
        end else begin
            de_d <= i_de;
            vs_d <= i_vs;
            if (vs_rise) begin
                y_cnt    <= {YW{1'b1}};
                x_cnt    <= {XW{1'b0}};
                in_frame <= 1'b1;
            end else if (de_rise && in_frame) begin
                x_cnt <= {XW{1'b0}};
                y_cnt <= y_cnt + 1'b1;
            end else if (i_de && in_frame) begin
                x_cnt <= x_cnt + 1'b1;
            end
        end
    end

    //====================================================================
    // S0：区域判定
    //====================================================================
    localparam TH_W = 24 * TH_SCALE;   // MERGE17: 宽 = 行数(24)×6
    localparam TH_H = 32 * TH_SCALE;   // MERGE17: 高 = 列数(32)×6

    wire in_therm = (x_cnt >= TH_X0) && (x_cnt < TH_X0 + TH_W) &&
                    (y_cnt >= TH_Y0) && (y_cnt < TH_Y0 + TH_H);

    localparam TXT_W = TXT_COLS * FONT_W * TXT_SCALE;
    localparam TXT_H = TXT_LINES * FONT_H * TXT_SCALE;
    wire in_text = (x_cnt >= TXT_X0) && (x_cnt < TXT_X0 + TXT_W) &&
                   (y_cnt >= TXT_Y0) && (y_cnt < TXT_Y0 + TXT_H);

    localparam INFO_LEN = 17;
    localparam INFO_W   = INFO_LEN * INFO_CW;
    wire in_info = (x_cnt >= INFO_X0) && (x_cnt < INFO_X0 + INFO_W) &&
                   (y_cnt >= INFO_Y0) && (y_cnt < INFO_Y0 + INFO_CH);

    wire in_border = (x_cnt < BORDER) || (x_cnt >= H_ACTIVE - BORDER) ||
                     (y_cnt < BORDER) || (y_cnt >= V_ACTIVE - BORDER);
    wire show_border = alarm & in_border;

    // ---- 热图源坐标（最近邻，6× 放大）----
    wire [XW-1:0] th_dx = x_cnt - TH_X0;
    wire [YW-1:0] th_dy = y_cnt - TH_Y0;
    // /6 近似：(v*171)>>10（171/1024 = 0.16699 ≈ 1/6）
    // MERGE17 转置：显示 x -> 红外行号(row)，显示 y -> 红外列号(col)
    //   数据 (col,row) 地址 = row*32+col；显示 (dx,dy) = (row*6+块内x, col*6+块内y)
    wire [17:0] sx_mul = {7'd0, th_dx} * 18'd171;
    wire [17:0] sy_mul = {7'd0, th_dy} * 18'd171;
    wire [4:0]  th_row = sx_mul[14:10];      // 0..23（行号）
    wire [4:0]  th_col = sy_mul[14:10];      // 0..31（列号）
    wire [9:0]  th_addr = {th_row, th_col};  // row*32 + col
    // 块内偏移：dx - 6*row / dy - 6*col
    wire [10:0] six_rx = {6'd0, th_row} * 11'd6;
    wire [10:0] six_cy = {6'd0, th_col} * 11'd6;
    wire [3:0]  blk_x  = th_dx[3:0] - six_rx[3:0];
    wire [3:0]  blk_y  = th_dy[3:0] - six_cy[3:0];
    wire        blk_edge = (blk_x == 4'd0) || (blk_x == 4'd5) ||
                           (blk_y == 4'd0) || (blk_y == 4'd5);

    assign th_rd_addr0 = th_addr;
    assign th_rd_addr1 = th_addr;
    assign th_rd_addr2 = th_addr;
    assign th_rd_addr3 = th_addr;

    // ---- 主文字坐标 ----
    wire [XW-1:0] tx = x_cnt - TXT_X0;
    wire [YW-1:0] ty = y_cnt - TXT_Y0;
    wire [5:0]    txt_col  = tx / (FONT_W * TXT_SCALE);
    wire [5:0]    txt_line = ty / (FONT_H * TXT_SCALE);
    wire [3:0]    font_row = ty[4:1];
    wire [2:0]    font_col = tx[3:1];
    wire [7:0]    txt_addr = {txt_line, txt_col};
    assign txt_rd_addr = txt_addr;

    //====================================================================
    // 信息条：HOT=nnn EST=nn.nC（5×7 点阵，字符格 6×8）
    //====================================================================
    wire [15:0] body_u  = body_x10[15] ? 16'd0 : body_x10[15:0];
    wire [15:0] body_int = body_u / 16'd10;
    wire [3:0]  body_fr  = body_u % 16'd10;
    wire [15:0] hot_u    = {8'd0, hot_cnt};
    wire [15:0] hot_h    = hot_u / 16'd100;
    wire [15:0] hot_t    = (hot_u % 16'd100) / 16'd10;
    wire [3:0]  hot_o    = hot_u % 16'd10;
    wire [15:0] bi_t     = body_int / 16'd10;
    wire [3:0]  bi_o     = body_int % 16'd10;

    wire [XW-1:0] ix = x_cnt - INFO_X0;
    wire [YW-1:0] iy = y_cnt - INFO_Y0;
    wire [4:0]  info_idx = ix / INFO_CW;
    wire [2:0]  info_row = iy[2:0];
    wire [2:0]  info_col = ix[2:0];

    // 字符编码：0..9 数字；10=H 11=O 12=T 13='=' 14=E 15=S 16='.' 17=C 18=' '
    reg [4:0] info_ch;
    always @(*) begin
        case (info_idx)
            5'd0:  info_ch = 5'd10;
            5'd1:  info_ch = 5'd11;
            5'd2:  info_ch = 5'd12;
            5'd3:  info_ch = 5'd13;
            5'd4:  info_ch = {1'b0, hot_h[3:0]};
            5'd5:  info_ch = {1'b0, hot_t[3:0]};
            5'd6:  info_ch = {1'b0, hot_o};
            5'd7:  info_ch = 5'd18;
            5'd8:  info_ch = 5'd14;
            5'd9:  info_ch = 5'd15;
            5'd10: info_ch = 5'd12;
            5'd11: info_ch = 5'd13;
            5'd12: info_ch = {1'b0, bi_t[3:0]};
            5'd13: info_ch = {1'b0, bi_o};
            5'd14: info_ch = 5'd16;
            5'd15: info_ch = {1'b0, body_fr};
            default: info_ch = 5'd17;
        endcase
    end

    function [4:0] glyph(input [4:0] ch, input [2:0] row);
        begin
            case (ch)
                5'd0: case(row) 0:glyph=5'b01110;1:glyph=5'b10001;2:glyph=5'b10011;3:glyph=5'b10101;4:glyph=5'b11001;5:glyph=5'b10001;default:glyph=5'b01110; endcase
                5'd1: case(row) 0:glyph=5'b00100;1:glyph=5'b01100;2:glyph=5'b00100;3:glyph=5'b00100;4:glyph=5'b00100;5:glyph=5'b00100;default:glyph=5'b01110; endcase
                5'd2: case(row) 0:glyph=5'b01110;1:glyph=5'b10001;2:glyph=5'b00001;3:glyph=5'b00010;4:glyph=5'b00100;5:glyph=5'b01000;default:glyph=5'b11111; endcase
                5'd3: case(row) 0:glyph=5'b11111;1:glyph=5'b00010;2:glyph=5'b00100;3:glyph=5'b00010;4:glyph=5'b00001;5:glyph=5'b10001;default:glyph=5'b01110; endcase
                5'd4: case(row) 0:glyph=5'b00010;1:glyph=5'b00110;2:glyph=5'b01010;3:glyph=5'b10010;4:glyph=5'b11111;5:glyph=5'b00010;default:glyph=5'b00010; endcase
                5'd5: case(row) 0:glyph=5'b11111;1:glyph=5'b10000;2:glyph=5'b11110;3:glyph=5'b00001;4:glyph=5'b00001;5:glyph=5'b10001;default:glyph=5'b01110; endcase
                5'd6: case(row) 0:glyph=5'b00110;1:glyph=5'b01000;2:glyph=5'b10000;3:glyph=5'b11110;4:glyph=5'b10001;5:glyph=5'b10001;default:glyph=5'b01110; endcase
                5'd7: case(row) 0:glyph=5'b11111;1:glyph=5'b00001;2:glyph=5'b00010;3:glyph=5'b00100;4:glyph=5'b01000;5:glyph=5'b01000;default:glyph=5'b01000; endcase
                5'd8: case(row) 0:glyph=5'b01110;1:glyph=5'b10001;2:glyph=5'b10001;3:glyph=5'b01110;4:glyph=5'b10001;5:glyph=5'b10001;default:glyph=5'b01110; endcase
                5'd9: case(row) 0:glyph=5'b01110;1:glyph=5'b10001;2:glyph=5'b10001;3:glyph=5'b01111;4:glyph=5'b00001;5:glyph=5'b00010;default:glyph=5'b01100; endcase
                5'd10:case(row) 0:glyph=5'b10001;1:glyph=5'b10001;2:glyph=5'b10001;3:glyph=5'b11111;4:glyph=5'b10001;5:glyph=5'b10001;default:glyph=5'b10001; endcase
                5'd11:case(row) 0:glyph=5'b01110;1:glyph=5'b10001;2:glyph=5'b10001;3:glyph=5'b10001;4:glyph=5'b10001;5:glyph=5'b10001;default:glyph=5'b01110; endcase
                5'd12:case(row) 0:glyph=5'b11111;1:glyph=5'b00100;2:glyph=5'b00100;3:glyph=5'b00100;4:glyph=5'b00100;5:glyph=5'b00100;default:glyph=5'b00100; endcase
                5'd13:case(row) 0:glyph=5'b00000;1:glyph=5'b00000;2:glyph=5'b11111;3:glyph=5'b00000;4:glyph=5'b11111;5:glyph=5'b00000;default:glyph=5'b00000; endcase
                5'd14:case(row) 0:glyph=5'b11111;1:glyph=5'b10000;2:glyph=5'b10000;3:glyph=5'b11110;4:glyph=5'b10000;5:glyph=5'b10000;default:glyph=5'b11111; endcase
                5'd15:case(row) 0:glyph=5'b01111;1:glyph=5'b10000;2:glyph=5'b10000;3:glyph=5'b01110;4:glyph=5'b00001;5:glyph=5'b00001;default:glyph=5'b11110; endcase
                5'd16:case(row) 0:glyph=5'b00000;1:glyph=5'b00000;2:glyph=5'b00000;3:glyph=5'b00000;4:glyph=5'b00000;5:glyph=5'b01100;default:glyph=5'b01100; endcase
                5'd17:case(row) 0:glyph=5'b01110;1:glyph=5'b10001;2:glyph=5'b10000;3:glyph=5'b10000;4:glyph=5'b10000;5:glyph=5'b10001;default:glyph=5'b01110; endcase
                default: glyph = 5'b00000;
            endcase
        end
    endfunction
    wire [4:0] info_glyph = glyph(info_ch, info_row);
    wire       info_pix   = in_info && (info_col < 3'd5) && info_glyph[3'd4 - info_col];

    //====================================================================
    // P 级
    //====================================================================
    reg [3:0] p_font_row;
    reg [2:0] p_font_col;
    reg       p_in_text, p_show_border, p_in_therm, p_in_info, p_info_pix, p_blk_edge;
    reg [7:0] p_r, p_g, p_b;
    reg       p_de, p_hs, p_vs;

    always @(posedge vclk or negedge vrst_n) begin
        if (!vrst_n) begin
            p_font_row <= 4'd0; p_font_col <= 3'd0;
            p_in_text <= 1'b0; p_show_border <= 1'b0; p_in_therm <= 1'b0;
            p_in_info <= 1'b0; p_info_pix <= 1'b0; p_blk_edge <= 1'b0;
            p_r <= 8'd0; p_g <= 8'd0; p_b <= 8'd0;
            p_de <= 1'b0; p_hs <= 1'b0; p_vs <= 1'b0;
        end else begin
            p_font_row <= font_row; p_font_col <= font_col;
            p_in_text <= in_text; p_show_border <= show_border; p_in_therm <= in_therm;
            p_in_info <= in_info; p_info_pix <= info_pix; p_blk_edge <= blk_edge;
            p_r <= i_r; p_g <= i_g; p_b <= i_b;
            p_de <= i_de; p_hs <= i_hs; p_vs <= i_vs;
        end
    end

    reg [7:0] p_th_data;
    always @(posedge vclk) p_th_data <= th_rd_data0;

    //====================================================================
    // Q2 级
    //====================================================================
    reg [3:0] q2_font_row;
    reg [2:0] q2_font_col;
    reg       q2_in_text, q2_show_border, q2_in_therm, q2_in_info, q2_info_pix, q2_blk_edge;
    reg [7:0] q2_r, q2_g, q2_b, q2_th;
    reg       q2_de, q2_hs, q2_vs;

    always @(posedge vclk or negedge vrst_n) begin
        if (!vrst_n) begin
            q2_font_row <= 4'd0; q2_font_col <= 3'd0;
            q2_in_text <= 1'b0; q2_show_border <= 1'b0; q2_in_therm <= 1'b0;
            q2_in_info <= 1'b0; q2_info_pix <= 1'b0; q2_blk_edge <= 1'b0;
            q2_r <= 8'd0; q2_g <= 8'd0; q2_b <= 8'd0; q2_th <= 8'd0;
            q2_de <= 1'b0; q2_hs <= 1'b0; q2_vs <= 1'b0;
        end else begin
            q2_font_row <= p_font_row; q2_font_col <= p_font_col;
            q2_in_text <= p_in_text; q2_show_border <= p_show_border; q2_in_therm <= p_in_therm;
            q2_in_info <= p_in_info; q2_info_pix <= p_info_pix; q2_blk_edge <= p_blk_edge;
            q2_r <= p_r; q2_g <= p_g; q2_b <= p_b; q2_th <= p_th_data;
            q2_de <= p_de; q2_hs <= p_hs; q2_vs <= p_vs;
        end
    end

    //====================================================================
    // S1：主字模数据
    //====================================================================
    reg [7:0] s1_txt_char;
    reg [3:0] s1_font_row;
    reg [2:0] s1_font_col;
    reg       s1_in_text, s1_show_border, s1_in_therm, s1_in_info, s1_info_pix, s1_blk_edge;
    reg [7:0] s1_th_data, s1_r, s1_g, s1_b;
    reg       s1_de, s1_hs, s1_vs;

    reg [7:0] t1_txt, t2_txt;
    always @(posedge vclk) begin t1_txt <= txt_rd_data; t2_txt <= t1_txt; end

    always @(posedge vclk or negedge vrst_n) begin
        if (!vrst_n) begin
            s1_txt_char <= 8'd0; s1_font_row <= 4'd0; s1_font_col <= 3'd0;
            s1_in_text <= 1'b0; s1_show_border <= 1'b0; s1_in_therm <= 1'b0;
            s1_in_info <= 1'b0; s1_info_pix <= 1'b0; s1_blk_edge <= 1'b0;
            s1_th_data <= 8'd0; s1_r <= 8'd0; s1_g <= 8'd0; s1_b <= 8'd0;
            s1_de <= 1'b0; s1_hs <= 1'b0; s1_vs <= 1'b0;
        end else begin
            s1_txt_char   <= t2_txt;
            s1_font_row   <= q2_font_row;
            s1_font_col   <= q2_font_col;
            s1_in_text    <= q2_in_text; s1_in_therm <= q2_in_therm;
            s1_show_border<= q2_show_border;
            s1_in_info    <= q2_in_info; s1_info_pix <= q2_info_pix; s1_blk_edge <= q2_blk_edge;
            s1_th_data    <= q2_th;
            s1_r <= q2_r; s1_g <= q2_g; s1_b <= q2_b;
            s1_de <= q2_de; s1_hs <= q2_hs; s1_vs <= q2_vs;
        end
    end

    // S2：字模读取
    wire [7:0] ch = (s1_txt_char >= 8'd32 && s1_txt_char <= 8'd126) ? (s1_txt_char - 8'd32) : 8'd0;
    wire [10:0] font_addr = {ch, s1_font_row};
    reg  [7:0]  font_byte;
    always @(posedge vclk) font_byte <= font_rom[font_addr];
    reg [2:0] s2_font_col;
    always @(posedge vclk) s2_font_col <= s1_font_col;
    wire s2_font_bit_w = font_byte[3'd7 - s2_font_col];

    // S2 输出寄存器
    reg       s2_font_bit;
    reg [7:0] s2_th_data;
    reg       s2_in_text, s2_show_border, s2_in_therm, s2_in_info, s2_info_pix, s2_blk_edge;
    reg [7:0] s2_r, s2_g, s2_b;
    reg       s2_de, s2_hs, s2_vs;

    always @(posedge vclk or negedge vrst_n) begin
        if (!vrst_n) begin
            s2_font_bit <= 1'b0; s2_th_data <= 8'd0;
            s2_in_text <= 1'b0; s2_show_border <= 1'b0; s2_in_therm <= 1'b0;
            s2_in_info <= 1'b0; s2_info_pix <= 1'b0; s2_blk_edge <= 1'b0;
            s2_r <= 8'd0; s2_g <= 8'd0; s2_b <= 8'd0;
            s2_de <= 1'b0; s2_hs <= 1'b0; s2_vs <= 1'b0;
        end else begin
            s2_font_bit    <= s2_font_bit_w;
            s2_th_data     <= s1_th_data;
            s2_in_text     <= s1_in_text; s2_in_therm <= s1_in_therm;
            s2_show_border <= s1_show_border;
            s2_in_info     <= s1_in_info; s2_info_pix <= s1_info_pix; s2_blk_edge <= s1_blk_edge;
            s2_r <= s1_r; s2_g <= s1_g; s2_b <= s1_b;
            s2_de <= s1_de; s2_hs <= s1_hs; s2_vs <= s1_vs;
        end
    end

    //====================================================================
    // 16 档色阶查表：蓝 -> 青 -> 绿 -> 黄 -> 红 -> 白
    //====================================================================
    reg [7:0] heat_r, heat_g, heat_b;
    always @(*) begin
        case (s2_th_data[3:0])
            4'd0:  begin heat_r=8'd0;   heat_g=8'd0;   heat_b=8'd96;  end
            4'd1:  begin heat_r=8'd0;   heat_g=8'd0;   heat_b=8'd160; end
            4'd2:  begin heat_r=8'd0;   heat_g=8'd0;   heat_b=8'd224; end
            4'd3:  begin heat_r=8'd0;   heat_g=8'd64;  heat_b=8'd255; end
            4'd4:  begin heat_r=8'd0;   heat_g=8'd144; heat_b=8'd255; end
            4'd5:  begin heat_r=8'd0;   heat_g=8'd224; heat_b=8'd224; end
            4'd6:  begin heat_r=8'd0;   heat_g=8'd255; heat_b=8'd128; end
            4'd7:  begin heat_r=8'd0;   heat_g=8'd255; heat_b=8'd32;  end
            4'd8:  begin heat_r=8'd96;  heat_g=8'd255; heat_b=8'd0;   end
            4'd9:  begin heat_r=8'd192; heat_g=8'd255; heat_b=8'd0;   end
            4'd10: begin heat_r=8'd255; heat_g=8'd224; heat_b=8'd0;   end
            4'd11: begin heat_r=8'd255; heat_g=8'd160; heat_b=8'd0;   end
            4'd12: begin heat_r=8'd255; heat_g=8'd64;  heat_b=8'd0;   end
            4'd13: begin heat_r=8'd255; heat_g=8'd0;   heat_b=8'd0;   end
            4'd14: begin heat_r=8'd255; heat_g=8'd96;  heat_b=8'd96;  end
            default: begin heat_r=8'd255; heat_g=8'd255; heat_b=8'd255; end
        endcase
    end

    wire th_hot = s2_th_data[7];
    wire [7:0] th_rgb_r = (th_hot && s2_blk_edge) ? 8'hFF : heat_r;
    wire [7:0] th_rgb_g = (th_hot && s2_blk_edge) ? 8'd0   : heat_g;
    wire [7:0] th_rgb_b = (th_hot && s2_blk_edge) ? 8'd0   : heat_b;

    //====================================================================
    // S3：合成（报警红框 > 信息条 > 主文字 > 热图 > 原始视频）
    //====================================================================
    always @(posedge vclk or negedge vrst_n) begin
        if (!vrst_n) begin
            o_r <= 8'd0; o_g <= 8'd0; o_b <= 8'd0;
            o_de <= 1'b0; o_hs <= 1'b0; o_vs <= 1'b0;
        end else begin
            o_de <= s2_de;
            o_hs <= s2_hs;
            o_vs <= s2_vs;
            if (s2_show_border) begin
                o_r <= 8'hFF; o_g <= 8'h00; o_b <= 8'h00;
            end else if (s2_in_info) begin
                if (s2_info_pix) begin
                    o_r <= 8'hFF; o_g <= 8'hC0; o_b <= 8'h00;
                end else begin
                    o_r <= 8'h08; o_g <= 8'h08; o_b <= 8'h08;
                end
            end else if (s2_in_text) begin
                if (s2_font_bit_w) begin
                    o_r <= 8'h00; o_g <= 8'hFF; o_b <= 8'h00;
                end else begin
                    o_r <= {1'b0, s2_r[7:1]};
                    o_g <= {1'b0, s2_g[7:1]};
                    o_b <= {1'b0, s2_b[7:1]};
                end
            end else if (s2_in_therm) begin
                o_r <= th_rgb_r; o_g <= th_rgb_g; o_b <= th_rgb_b;
            end else begin
                o_r <= s2_r; o_g <= s2_g; o_b <= s2_b;
            end
        end
    end

endmodule
