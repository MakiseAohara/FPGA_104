`timescale 1ns/1ps
module counter(input clk, input rst_n, output reg [3:0] q);
  always @(posedge clk or negedge rst_n)
    if (!rst_n) q <= 4'd0; else q <= q + 4'd1;
endmodule
