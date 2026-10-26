`timescale 1ns/1ps
// Mirror debayer_top_2to1's gain-port binding, without camera/DDR/JTAG.
module tb_gain_numeric;
reg clk=0, rstn=0, vs=0, hs=0, de=0, valid=0;
reg [15:0] pixels=0, r=256, g=256, b=256;
wire [15:0] result;
wire out_vs,out_hs,out_de,out_valid;
integer variant,line,x,expected_high,expected_low,checks=0;
always #5 clk=~clk;
rgb_gain_v1 #(.P_DEPTH(8),.Q_WIDTH(16)) dut (
  .i_pclk(clk),.i_arstn(rstn),.i_vs(vs),.i_hs(hs),.i_de(de),
  .i_valid(valid),.i_data(pixels),.gain_r(b),.gain_g(g),.gain_b(r),
  .o_vs(out_vs),.o_hs(out_hs),.o_de(out_de),.o_valid(out_valid),.o_data(result)
);
function integer expected;
input integer pixel,gain;
integer value;
begin value=(pixel*gain)>>8;expected=(value>255)?255:value;end
endfunction
initial begin
  for(variant=0;variant<4;variant=variant+1) begin
    @(negedge clk);rstn=0;de=0;valid=0;vs=0;
    case(variant)
      0: begin r=280;g=232;b=344;end
      1: begin r=256;g=256;b=256;end
      2: begin r=65535;g=65535;b=65535;end
      3: begin r=0;g=0;b=0;end
    endcase
    repeat(4) @(posedge clk);
    @(negedge clk);rstn=1;vs=1;
    repeat(2) @(posedge clk);
    @(negedge clk);vs=0;
    repeat(2) @(posedge clk);
    for(line=0;line<2;line=line+1) begin
      for(x=0;x<256;x=x+1) begin
        @(negedge clk);de=1;valid=1;pixels=((255-x)<<8)|x;
        expected_high=expected(255-x,(line==0)?g:r);
        expected_low=expected(x,(line==0)?b:g);
        @(posedge clk);#1;
        if(result[15:8]!==expected_high[7:0] || result[7:0]!==expected_low[7:0] ||
           out_de!==1 || out_valid!==1)
          $fatal(1,"gain mismatch variant=%0d line=%0d x=%0d actual=%x expected=%02x%02x",variant,line,x,result,expected_high,expected_low);
        checks=checks+1;
      end
      @(negedge clk);de=0;valid=0;
      repeat(2) @(posedge clk);
    end
  end
  $display("NUMERIC_GAIN_CHECKS=%0d CHANNEL_VALUES=%0d",checks,checks*2);
  $finish;
end
initial begin #1000000;$fatal(1,"timeout");end
endmodule
