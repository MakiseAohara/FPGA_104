`timescale 1ns/1ps
module tb;
  reg clk=0, rst_n=0; wire [3:0] q; integer errs=0;
  counter u(.clk(clk), .rst_n(rst_n), .q(q));
  always #5 clk = ~clk;
  initial begin
    #12 rst_n=1;
    @(posedge clk);
    repeat (5) begin
      @(posedge clk); #1;
      $display("q=%0d", q);
    end
    if (q !== 4'd5) begin $display("FAIL: expect 5 got %0d", q); errs=errs+1; end
    else            $display("PASS: counter counted to 5");
    if (errs==0) $display("=== ALL TESTS PASSED ==="); else $display("=== %0d FAILURES ===", errs);
    $finish;
  end
endmodule
