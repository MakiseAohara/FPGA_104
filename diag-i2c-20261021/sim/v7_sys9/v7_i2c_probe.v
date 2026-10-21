`timescale 1ns / 1ps
// I2C 地址扫描探针（诊断用）：en 为高时接管总线，对 0x08..0x77 逐个发 [START][addr+W][读ACK][STOP]，
// 记录应答的地址个数和前两个地址。纯开漏：只拉低(oe=1,o=0)或释放，不推高。
module v7_i2c_probe #(
    parameter CLK_HZ = 148_500_000,
    parameter SCL_HZ = 50_000
)(
    input  wire       clk, rst_n,
    input  wire       en,
    input  wire       scl_i, sda_i,
    output wire       scl_o, scl_oe, sda_o, sda_oe,
    output wire       active,
    output reg  [7:0] res_cnt,
    output reg  [6:0] res_a0, res_a1,
    output reg  [7:0] scans
);
    localparam integer Q = CLK_HZ / (SCL_HZ * 4);
    reg [15:0] qc; wire tick = (qc == Q-1);
    reg scl_hi, sda_hi;
    assign scl_o = 1'b0; assign sda_o = 1'b0;
    assign scl_oe = active & ~scl_hi;
    assign sda_oe = active & ~sda_hi;
    localparam S_IDLE=0, S_REC=1, S_START=2, S_BITS=3, S_ACK=4, S_STOP=5, S_NEXT=6;
    reg [2:0] st; reg [1:0] ph; reg [3:0] bit_i; reg [6:0] addr; reg [3:0] rec_n;
    reg [7:0] shreg; reg [7:0] found_cnt; reg [6:0] a0, a1;
    reg act_r; assign active = act_r;
    reg [1:0] sda_s; always @(posedge clk) sda_s <= {sda_s[0], sda_i};
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            qc<=0; scl_hi<=1; sda_hi<=1; st<=S_IDLE; ph<=0; bit_i<=0; addr<=7'h08; rec_n<=0; shreg<=0;
            act_r<=0; found_cnt<=0; a0<=0; a1<=0; scans<=0; res_cnt<=0; res_a0<=0; res_a1<=0;
        end else begin
            qc <= tick ? 16'd0 : qc + 1'b1;
            if (!en && st != S_IDLE) begin st<=S_IDLE; act_r<=0; scl_hi<=1; sda_hi<=1; end
            else if (tick) case (st)
              S_IDLE: begin
                  scl_hi<=1; sda_hi<=1;
                  if (en) begin act_r<=1; addr<=7'h08; found_cnt<=0; a0<=0; a1<=0; rec_n<=0; ph<=0; st<=S_REC; end
                  else act_r<=0;
              end
              S_REC: begin   // 9 个时钟脉冲（SDA 释放）清除可能卡住的从机，然后进入 START
                  ph <= ph + 1'b1;
                  case (ph) 2'd0: begin scl_hi<=0; sda_hi<=1; end
                            2'd1: ;
                            2'd2: scl_hi<=1;
                            2'd3: begin if (rec_n == 4'd8) begin st<=S_START; ph<=0; end else rec_n<=rec_n+1'b1; end
                  endcase
              end
              S_START: begin
                  ph <= ph + 1'b1;
                  case (ph) 2'd0: begin scl_hi<=1; sda_hi<=1; end
                            2'd1: sda_hi<=0;                 // START：SCL 高时 SDA 下降
                            2'd2: scl_hi<=0;
                            2'd3: begin st<=S_BITS; ph<=0; bit_i<=0; shreg<={addr,1'b0}; end
                  endcase
              end
              S_BITS: begin
                  ph <= ph + 1'b1;
                  case (ph) 2'd0: begin scl_hi<=0; sda_hi<=shreg[7]; end
                            2'd1: scl_hi<=1;
                            2'd2: ;
                            2'd3: begin scl_hi<=0; shreg<={shreg[6:0],1'b0};
                                        if (bit_i == 4'd7) begin st<=S_ACK; ph<=0; end else bit_i<=bit_i+1'b1; end
                  endcase
              end
              S_ACK: begin
                  ph <= ph + 1'b1;
                  case (ph) 2'd0: begin scl_hi<=0; sda_hi<=1; end
                            2'd1: scl_hi<=1;
                            2'd2: begin if (!sda_s[1]) begin
                                      found_cnt <= found_cnt + 1'b1;
                                      if (found_cnt == 8'd0) a0 <= addr; else if (found_cnt == 8'd1) a1 <= addr;
                                  end end
                            2'd3: begin scl_hi<=0; st<=S_STOP; ph<=0; end
                  endcase
              end
              S_STOP: begin
                  ph <= ph + 1'b1;
                  case (ph) 2'd0: begin scl_hi<=0; sda_hi<=0; end
                            2'd1: scl_hi<=1;
                            2'd2: sda_hi<=1;                 // STOP：SCL 高时 SDA 上升
                            2'd3: begin st<=S_NEXT; ph<=0; end
                  endcase
              end
              S_NEXT: begin
                  if (addr == 7'h77) begin scans<=scans+1'b1; res_cnt<=found_cnt; res_a0<=a0; res_a1<=a1; st<=S_IDLE; act_r<=0; end   // 一轮结束；en 仍为高则下一拍重新开始
                  else begin addr<=addr+1'b1; st<=S_START; ph<=0; end
              end
            endcase
        end
    end
endmodule
