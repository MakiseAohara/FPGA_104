`timescale 1 ns / 1 ns
module ge_raw_rx #(parameter AW = 9) (
   input                 clk,
   input      [31:0]     paddr,
   input                 psel,
   input                 penable,
   input                 pwrite,
   input      [31:0]     pwdata,
   output reg [31:0]     prdata,
   input                 rx_clk,
   input                 rx_dv,
   input      [7:0]      rxd
);
   reg  [1:0]    bsel;
   reg  [31:0]   wbuf;
   reg  [AW-1:0] waddr;
   reg           wr_en;
   reg  [31:0]   wr_data;
   reg  [AW-1:0] rd_addr;
   wire [31:0]   rd_data;
   reg           dv_d;
   reg  [AW-1:0] last_words;
   reg           rx_tgl;

   ge_dpram32 #(.AW(AW)) u_rxbuf (
      .wr_clk(rx_clk), .wr_en(wr_en), .wr_addr(waddr), .wr_data(wr_data),
      .rd_clk(clk), .rd_addr(rd_addr), .rd_data(rd_data));

   always @(posedge rx_clk) begin
      dv_d       <= rx_dv;
      wr_en      <= 1'b0;
      rx_tgl     <= rx_tgl;
      if (rx_dv && !dv_d) begin
         bsel       <= 2'd0;
         waddr      <= 0;
         last_words <= 0;
      end else if (rx_dv) begin
         case (bsel)
            2'd0: wbuf[7:0]   <= rxd;
            2'd1: wbuf[15:8]  <= rxd;
            2'd2: wbuf[23:16] <= rxd;
            default: wbuf[31:24] <= rxd;
         endcase
         if (bsel == 2'd3) begin
            wr_en   <= 1'b1;
            wr_data <= {rxd, wbuf[23:0]};
            waddr   <= waddr + 1'b1;
         end
         bsel <= bsel + 1'b1;
      end else if (dv_d && !rx_dv) begin
         last_words <= waddr + ((bsel == 2'd0) ? 1'b0 : 1'b1);
         rx_tgl     <= ~rx_tgl;
      end
   end

   reg  [1:0]    valid_s;
   reg  [AW-1:0] rx_words;
   wire wr = psel && penable && pwrite;
   wire rd = psel && penable && !pwrite;
   wire [4:0] widx = paddr[6:2];
   always @(posedge clk) begin
      valid_s <= {valid_s[0], rx_tgl};
      if (valid_s[1] != valid_s[0]) rx_words <= last_words;
      if (wr && widx == 5'd29 && pwdata[2]) rd_addr <= 0;
      if (rd && widx == 5'd31) rd_addr <= rd_addr + 1'b1;
   end

   always @(*) begin
      case (widx)
         5'd30: prdata = {19'd0, valid_s[1], rx_words};
         5'd31: prdata = rd_data;
         default: prdata = 32'd0;
      endcase
   end
endmodule