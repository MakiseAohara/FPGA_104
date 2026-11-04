`timescale 1ns / 1ps
//==========================================================================
//  v7_ir_proc.v — MERGE16: MLX90640 原始帧 -> 自动拉伸热力图 + 热点增量
//
//  与 MERGE15 的差异（仅热图色阶部分）：
//   1) 每帧两遍读同一帧 RAM：第一遍统计本帧 d_pos 的 min/max，第二遍按
//      min/max 归一化成 0..15 色阶（蓝->青->绿->黄->红->白 16 档由 OSD 查表），
//      冷处也会画（不再靠"色阶=0 透明"隐藏）。
//   2) 最小跨度 MIN_SPAN：按板上标定 IR_K=3 / IR_SH=3（0.1℃ = hot_delta*3/8）
//      => 1℃ ≈ 26.7 raw，2℃ ≈ 53.3 raw，取 54。跨度不足 54 时按 54 拉伸，
//      防止无人时把噪声放大成花屏。
//   3) heat_wd[7] = 该像素 d_pos > NOISE（ir_hot 同款判据），供 OSD 画红框；
//      heat_wd[3:0] = 0..15 色阶。hot_cnt / hot_delta / freeze 逻辑不变。
//   4) 两遍共约 9.2k 周期 @148.5MHz ≈ 62µs << 125ms 帧周期。
//==========================================================================
module v7_ir_proc #(
    parameter IR_HS     = 2,     // 兼容保留（不再用于热图色阶）
    parameter NOISE     = 12,    // 低于此值不判为热点
    parameter FREEZE_TH = 48,    // 上一帧最大升温超过此值时冻结基线
    parameter RECOVER_FRAMES = 240, // MERGE15: 冻结连续帧数上限（125 ms/帧 -> 240 帧≈30 s）
    parameter MIN_SPAN  = 54     // MERGE16: 最小色阶跨度（raw 计数，≈2℃）
)(
    input  wire        clk, rst_n,
    input  wire        frame_valid,         // 新红外帧写完脉冲
    input  wire        learn_req,           // 重新学习基线
    input  wire        ai_person,           // MERGE15: AI 判定有人时不自动重学
    output reg  [7:0]  hot_cnt,             // 本帧 heat>NOISE 的像素数（饱和 255）
    output wire [15:0] frame_min,           // MERGE16: 本帧 d_pos 最小值（调试）
    output wire [15:0] frame_max,           // MERGE16: 本帧 d_pos 最大值（调试）
    output reg  [9:0]  rd_addr,
    input  wire [15:0] rd_data,
    output reg         heat_we,
    output reg  [9:0]  heat_wa,
    output reg  [7:0]  heat_wd,
    output reg  [15:0] hot_delta,
    output reg         valid
);
    localparam S_IDLE=0, S_A1=1, S_W1=2, S_W2=3, S_U1=4,
                         S_A2=5, S_W3=6, S_W4=7, S_U2=8;
    reg [3:0] st; reg [9:0] i;
    reg learn_pend, learn_cur, freeze_prev, pend_frame;
    reg [15:0] frozen_cnt;
    reg [15:0] maxd;
    reg [15:0] mn_q, mx_q;
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

    // ---------------- MERGE16: 色阶自动拉伸 ----------------
    wire [15:0] span_raw = (mx_q > mn_q) ? (mx_q - mn_q) : 16'd0;
    wire [15:0] span_use = (span_raw < MIN_SPAN) ? MIN_SPAN[15:0] : span_raw;
    // 用 2 的幂近似满量程：找 span_use 的 MSB(k)，level = diff >> (k-4)（k>=4）
    reg [3:0] msb_k;
    integer bi;
    always @(*) begin
        msb_k = 4'd0;
        for (bi = 0; bi < 16; bi = bi + 1)
            if (span_use[bi]) msb_k = bi[3:0];
    end
    wire [3:0]  lv_shift = (msb_k > 4'd4) ? (msb_k - 4'd4) : 4'd0;
    wire [15:0] diff_q = (d_pos > mn_q) ? (d_pos - mn_q) : 16'd0;
    wire [15:0] lv_full = diff_q >> lv_shift;
    wire [3:0]  level = (lv_full > 16'd15) ? 4'd15 : lv_full[3:0];
    wire        hot_pix = (d_pos > NOISE);

    assign frame_min = mn_q;
    assign frame_max = mx_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st<=S_IDLE; i<=0; rd_addr<=0; learn_pend<=1; learn_cur<=0; freeze_prev<=0; pend_frame<=0;
            maxd<=0; mn_q<=16'hFFFF; mx_q<=16'd0;
            base_we<=0; base_wd<=0; base_wa<=0; heat_we<=0; heat_wa<=0; heat_wd<=0;
            hot_delta<=0; valid<=0; frozen_cnt<=0; hot_cnt<=0;
        end else begin
            base_we<=0; heat_we<=0;
            if (learn_req) learn_pend <= 1'b1;
            if (frame_valid) pend_frame <= 1'b1;
            case (st)
              S_IDLE: if (pend_frame) begin
                    pend_frame<=0; i<=0; maxd<=0; hot_cnt<=8'd0;
                    mn_q<=16'hFFFF; mx_q<=16'd0;
                    learn_cur<=learn_pend; learn_pend<=0; st<=S_A1; end
              // ---- 第一遍：统计 min/max ----
              S_A1: begin rd_addr<=i; st<=S_W1; end
              S_W1:   st<=S_W2;
              S_W2:   st<=S_U1;
              S_U1: begin
                  if (d_pos < mn_q) mn_q <= d_pos;
                  if (d_pos > mx_q) mx_q <= d_pos;
                  if (i == 10'd767) begin i<=10'd0; st<=S_A2; end
                  else begin i<=i+10'd1; st<=S_A1; end
              end
              // ---- 第二遍：归一化 + 写热图 + 基线更新 ----
              S_A2: begin rd_addr<=i; st<=S_W3; end
              S_W3:   st<=S_W4;
              S_W4:   st<=S_U2;
              S_U2: begin
                  base_wa<=i; heat_wa<=i; heat_we<=1'b1;
                  if (learn_cur) begin
                      base_we<=1'b1; base_wd<=rd_data; heat_wd<=8'd0;
                  end else begin
                      if (!freeze_prev) begin base_we<=1'b1; base_wd<=base_q + bstep[15:0]; end
                      heat_wd <= {hot_pix, 3'b000, level};
                      if (d_pos > maxd) maxd <= d_pos;
                      if (hot_pix && (hot_cnt != 8'd255)) hot_cnt <= hot_cnt + 8'd1;
                  end
                  if (i == 10'd767) begin
                      st<=S_IDLE;
                      if (!learn_cur) begin
                          hot_delta <= (d_pos > maxd) ? d_pos : maxd;
                          freeze_prev <= (((d_pos > maxd) ? d_pos : maxd) > FREEZE_TH);
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
                  end else begin i<=i+10'd1; st<=S_A2; end
              end
              default: st<=S_IDLE;
            endcase
        end
    end
endmodule
