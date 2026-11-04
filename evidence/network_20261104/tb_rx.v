`timescale 1ns/1ps
module tb;
reg clk=0,rx_clk=0,rst_n=0,psel=0,penable=0,pwrite=0,rx_dv=0;
reg [31:0] paddr=0,pwdata=0;reg [7:0] rxd=0;wire [31:0] prdata;
integer j;reg [31:0] value;
always #5 clk=~clk;always #4 rx_clk=~rx_clk;
ge_raw_rx dut(.*);
task send_frame(input integer count,input integer seed);
integer k;begin
 for(k=0;k<count;k=k+1)begin @(negedge rx_clk);rx_dv=1;rxd=(seed+k)&255;end
 @(negedge rx_clk);rx_dv=0;repeat(12)@(negedge rx_clk);
end endtask
task wr(input integer index,input [31:0] data);
begin
 @(negedge clk);paddr=index*4;pwrite=1;pwdata=data;psel=1;penable=0;
 @(negedge clk);penable=1;@(negedge clk);psel=0;penable=0;pwrite=0;
end endtask
task rd(input integer index,output [31:0] data);
begin
 @(negedge clk);paddr=index*4;pwrite=0;psel=1;penable=0;
 @(negedge clk);penable=1;#1;data=prdata;
 @(negedge clk);psel=0;penable=0;
end endtask
task consume(input integer count,input integer seed);
integer k,n;reg [31:0] data,expected,st;
begin
 rd(30,st);if(!st[10] || st[8:0]!=(count+3)/4)$fatal(1,"status %h count=%d",st,count);
 wr(29,4); // rewind must NOT release the slot
 for(k=0;k<(count+3)/4;k=k+1)begin
  rd(31,data);expected=0;
  for(n=0;n<4;n=n+1)if(k*4+n<count)expected=expected|(((seed+k*4+n)&255)<<(n*8));
  if(data!==expected)$fatal(1,"word %d got=%h expected=%h",k,data,expected);
 end
 wr(29,8); // release only after all bytes were read
end endtask
initial begin
 repeat(3)@(negedge clk);rst_n=1;
 send_frame(64,10);send_frame(65,20);send_frame(66,30);send_frame(67,40);
 send_frame(80,50); // full: drop, never overwrite a queued frame
 repeat(6)@(negedge clk);
 consume(64,10);consume(65,20);consume(66,30);consume(67,40);
 rd(30,value);if(value[10] || value[23:16]!=1)$fatal(1,"full/drop status=%h",value);
 for(j=0;j<16;j=j+1)begin
  fork send_frame(61+j,j*7);begin repeat(300)@(negedge clk);consume(61+j,j*7);end join
 end
 send_frame(1500,90);consume(1500,90);
 @(negedge clk);rst_n=0;repeat(4)@(negedge clk);rst_n=1;
 send_frame(71,111);consume(71,111);
 $display("PASS RX: four slots, full drop, tails 0/1/2/3, minimum IFG, 16 pointer wraps, 1500 bytes, reset");$finish;
end
initial begin #1000000;$fatal(1,"timeout");end
endmodule
