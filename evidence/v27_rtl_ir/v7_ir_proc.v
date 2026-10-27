`timescale 1ns / 1ps
//==========================================================================
//  v7_ir_proc.v — MLX90640 原始帧 → 相对热力图 + 热点增量（无 RISC-V、无 Melexis 库）
//  原理：为每个像素保存"慢更新基线"（低通），当前原始计数 − 基线 = 相对升温。
//  好处：原始计数含逐像素固定偏置（棋盘格/增益），相减后固定图案自动消失，
//        不需要校准系数；只需把"计数→℃"做一个线性换算（上板标定）。
//  输出：heat_* 写热力图 RAM（32×24=768，地址 = 行*32+列）；hot_delta = 最大相对升温（计数）。
//==========================================================================
module v7_ir_proc #(
    parameter IR_HS     = 2,     // 热力图灰度 = 升温计数 >> IR_HS（上板标定）
    parameter NOISE     = 12,    // 低于此值的升温不显示
    parameter FREEZE_TH = 48,    // 上一帧最大升温超过此值时冻结基线
    parameter RECOVER_FRAMES = 240 // MERGE15: 冻结连续帧数上限（本工程 125 ms/帧 -> 240 帧≈30 s）
)(
    input  wire        clk, rst_n,
    input  wire        frame_valid,         // 新红外帧写完脉冲
    input  wire        learn_req,           // 重新学习基线
    input  wire        ai_person,           // MERGE15: AI 判定有人时不自动重学
    output reg  [7:0]  hot_cnt,             // MERGE15: 本帧 heat>NOISE 的像素数（饱和 255）
    output reg  [9:0]  rd_addr,
    input  wire [15:0] rd_data,
    output reg         heat_we,
    output reg  [9:0]  heat_wa,
    output reg  [7:0]  heat_wd,
    output reg  [15:0] hot_delta,
    output reg         valid
);
    localparam S_IDLE=0, S_ADDR=1, S_W1=2, S_W2=3, S_USE=4;
    reg [2:0] st; reg [9:0] i;
    reg learn_pend, learn_cur, freeze_prev, pend_frame;
    reg [15:0] frozen_cnt;                  // MERGE15: freeze_prev 连续为 1 的帧数
    reg [15:0] maxd;
    wire [15:0] base_q;
    reg base_we; reg [15:0] base_wd; reg [9:0] base_wa;
    mmt_dpram #(.DW(16), .AW(10), .DEPTH(768)) u_base (
        .clk(clk), .we(base_we), .waddr(base_wa), .wdata(base_wd),
        .raddr(rd_addr), .rdata(base_q));
    wire signed [16:0] raw = {rd_data[15], rd_data};
    wire signed [16:0] base = {base_q[15], base_q};
    wire signed [16:0] d = raw - base;
    wire [15:0] d_pos = d[16] ? 16'd0 : d[15:0];
    // MERGE12/MERGE9: 有符号对称舍入（原先负数直接 >>>3 是向下取整，基线会永远追不上）
    wire signed [17:0] d_ext = d;
    wire signed [17:0] bstep18 = (d > 0) ? ((d_ext + 18'sd7) >>> 3)
                                       : -(((-d_ext) + 18'sd7) >>> 3);
    wire signed [16:0] bstep = bstep18[16:0];
    wire [15:0] hs = d_pos >> IR_HS;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st<=S_IDLE; i<=0; rd_addr<=0; learn_pend<=1; learn_cur<=0; freeze_prev<=0; pend_frame<=0;
            maxd<=0; base_we<=0; base_wd<=0; base_wa<=0; heat_we<=0; heat_wa<=0; heat_wd<=0;
            hot_delta<=0; valid<=0; frozen_cnt<=0; hot_cnt<=0;
        end else begin
            base_we<=0; heat_we<=0;
            if (learn_req) learn_pend <= 1'b1;
            if (frame_valid) pend_frame <= 1'b1;
            case (st)
              S_IDLE: if (pend_frame) begin
                    pend_frame<=0; i<=0; maxd<=0; hot_cnt<=8'd0; learn_cur<=learn_pend; learn_pend<=0; st<=S_ADDR; end
              S_ADDR: begin rd_addr<=i; st<=S_W1; end
              S_W1:   st<=S_W2;
              S_W2:   st<=S_USE;
              S_USE: begin
                  base_wa<=i; heat_wa<=i; heat_we<=1'b1;
                  if (learn_cur) begin
                      base_we<=1'b1; base_wd<=rd_data; heat_wd<=8'd0;
                  end else begin
                      if (!freeze_prev) begin base_we<=1'b1; base_wd<=base_q + bstep[15:0]; end
                      heat_wd <= (d_pos <= NOISE) ? 8'd0 : ((hs > 16'd255) ? 8'd255 : (hs[7:0] == 0 ? 8'd1 : hs[7:0]));
                      if (d_pos > maxd) maxd <= d_pos;
                      if ((d_pos > NOISE) && (hot_cnt != 8'd255)) hot_cnt <= hot_cnt + 8'd1;
                  end
                  if (i == 10'd767) begin
                      st<=S_IDLE;
                      if (!learn_cur) begin
                          hot_delta <= (d_pos > maxd) ? d_pos : maxd;
                          freeze_prev <= (((d_pos > maxd) ? d_pos : maxd) > FREEZE_TH);
                          // MERGE15: 冻结连续超限且无 AI 人体时，拉一次内部 learn 重学基线
                          if ((((d_pos > maxd) ? d_pos : maxd) > FREEZE_TH)) begin
                              if (frozen_cnt < RECOVER_FRAMES) frozen_cnt <= frozen_cnt + 16'd1;
                              if (!ai_person && (frozen_cnt >= (RECOVER_FRAMES - 1))) learn_pend <= 1'b1;
                          end else begin
                              frozen_cnt <= 16'd0;
                          end
                      end else begin
                          frozen_cnt <= 16'd0;
                          freeze_prev <= 1'b0;
                      end
                      valid <= 1'b1; learn_cur <= 1'b0;
                  end else begin i<=i+10'd1; st<=S_ADDR; end
              end
              default: st<=S_IDLE;
            endcase
        end
    end
endmodule
