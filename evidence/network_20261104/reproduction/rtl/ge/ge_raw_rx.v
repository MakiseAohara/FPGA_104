`timescale 1ns/1ps
// Four immutable frame slots; single writer per pointer, Gray CDC ownership.
module ge_raw_rx #(parameter AW=9)(
 input clk, rst_n,
 input [31:0] paddr, input psel,penable,pwrite,
 input [31:0] pwdata, output reg [31:0] prdata,
 input rx_clk,rx_dv,input [7:0] rxd
);
 reg [2:0] wp=0,wg=0,rp=0,rg=0;
 (* async_reg="true" *) reg [2:0] rg1=0,rg2=0,wg1=0,wg2=0;
 wire full=(wg=={~rg2[2:1],rg2[0]});
 wire ready=(rg!=wg2);
 reg [AW-1:0] length[0:3];
 reg [AW-1:0] rdptr=0;
 wire [31:0] rddata;
 reg active=0,taking=0,overflow=0;
 reg [AW+2:0] count=0;
 reg [31:0] packed_word=0;
 reg wen=0;
 reg [AW+1:0] waddr=0;
 reg [31:0] wdata=0;
 reg [7:0] frames=0,drops=0;
 wire wr=psel && penable && pwrite;
 wire rd=psel && penable && !pwrite;
 wire [4:0] index=paddr[6:2];
 ge_dpram32 #(.AW(AW+2)) ram(
 .wr_clk(rx_clk),.wr_en(wen),.wr_addr(waddr),.wr_data(wdata),
 .rd_clk(clk),.rd_addr({rp[1:0],rdptr}),.rd_data(rddata));
 always @(posedge rx_clk or negedge rst_n) begin
  if(!rst_n) begin
   wp<=0;wg<=0;rg1<=0;rg2<=0;active<=0;taking<=0;overflow<=0;
   count<=0;packed_word<=0;wen<=0;waddr<=0;wdata<=0;frames<=0;drops<=0;
  end else begin
   rg1<=rg;rg2<=rg1;wen<=0;
   if(rx_dv) begin
    if(!active) begin
     active<=1;taking<=!full;overflow<=0;count<=1;
     packed_word<={24'b0,rxd};
     if(frames!=255)frames<=frames+1'b1;
    end else begin
     count<=count+1'b1;
     case(count[1:0])
      0:packed_word<={24'b0,rxd};
      1:packed_word[15:8]<=rxd;
      2:packed_word[23:16]<=rxd;
      3:if(taking && !overflow) begin
       wen<=1;waddr<={wp[1:0],count[AW+1:2]};wdata<={rxd,packed_word[23:0]};
      end
     endcase
     if(count>=(1<<(AW+2))-5)overflow<=1;
    end
   end else if(active) begin
    active<=0;
    if(taking && !overflow) begin
     // Flush final bytes immediately; no extra frame gap is required.
     if(count[1:0]!=0)begin
      wen<=1;waddr<={wp[1:0],count[AW+1:2]};wdata<=packed_word;
     end
     length[wp[1:0]]<=(count+3)>>2;
     wp<=wp+1'b1;wg<=((wp+1'b1)>>1)^(wp+1'b1);
    end else if(drops!=255)drops<=drops+1'b1;
   end
  end
 end
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n)begin rp<=0;rg<=0;wg1<=0;wg2<=0;rdptr<=0;end
  else begin
   wg1<=wg;wg2<=wg1;
   if(wr && index==29 && pwdata[2])rdptr<=0; // rewind
   if(rd && index==31 && ready)rdptr<=rdptr+1'b1;
   if(wr && index==29 && pwdata[3] && ready)begin // release after reading
    rp<=rp+1'b1;rg<=((rp+1'b1)>>1)^(rp+1'b1);rdptr<=0;
   end
  end
 end
 always @* begin
  case(index)
   30:prdata={frames,drops,5'b0,ready,1'b0,(ready?length[rp[1:0]]:{AW{1'b0}})};
   31:prdata=rddata;
   default:prdata=0;
  endcase
 end
endmodule
