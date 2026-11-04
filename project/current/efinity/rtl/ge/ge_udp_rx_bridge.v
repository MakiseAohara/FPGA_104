`timescale 1 ns / 1 ps
/* ge_udp_rx_bridge.v - 把 mac_top 的 UDP 负载复制进本地 2KB RAM，供 APB 读取 */
module ge_udp_rx_bridge #(parameter AW = 9) (
   input                 clk,
   input      [31:0]     paddr,
   input                 psel,
   input                 penable,
   input                 pwrite,
   input      [31:0]     pwdata,
   output reg [31:0]     prdata,
   input                 rx_clk,
   input                 udp_valid,
   input      [15:0]     udp_len,
   input      [7:0]      udp_rdata,
   output reg [10:0]     udp_raddr
);
   reg  [10:0] src_i;
   reg  [1:0]  bsel;
   reg  [31:0] wbuf;
   reg  [AW-1:0] waddr, waddr_r;
   reg           wr_en;
   reg  [31:0]   wr_data;
   reg           busy;
   reg  [15:0]   f_len;
   reg           f_tgl;
   wire [31:0]   rd_data;
   reg  [AW-1:0] rd_addr;

   ge_dpram32 #(.AW(AW)) u_ram (
      .wr_clk(rx_clk), .wr_en(wr_en), .wr_addr(waddr_r), .wr_data(wr_data),
      .rd_clk(clk), .rd_addr(rd_addr), .rd_data(rd_data));

   always @(posedge rx_clk) begin
      wr_en <= 1'b0;
      if (udp_valid && !busy) begin
         busy <= 1'b1; src_i <= 0; bsel <= 2'd0; waddr <= 0; f_len <= udp_len;
         udp_raddr <= 0;
      end else if (busy) begin
         udp_raddr <= src_i + 11'd1;
         if (src_i < f_len) begin
            case (bsel)
               2'd0: wbuf[7:0]   <= udp_rdata;
               2'd1: wbuf[15:8]  <= udp_rdata;
               2'd2: wbuf[23:16] <= udp_rdata;
               default: wbuf[31:24] <= udp_rdata;
            endcase
            if (bsel == 2'd3) begin
               wr_en   <= 1'b1;
               wr_data <= {udp_rdata, wbuf[23:0]};
               waddr_r <= waddr;
               waddr   <= waddr + 1'b1;
            end
            bsel  <= bsel + 2'd1;
            src_i <= src_i + 11'd1;
         end else begin
            busy  <= 1'b0;
            f_tgl <= ~f_tgl;
         end
      end
   end

   reg  [1:0]  tgl_s;
   reg         ready;
   reg  [15:0] len_l;
   wire wr = psel && penable && pwrite;
   wire rd = psel && penable && !pwrite;
   wire [4:0] widx = paddr[6:2];
   always @(posedge clk) begin
      tgl_s <= {tgl_s[0], f_tgl};
      if (tgl_s[1] != tgl_s[0]) begin ready <= 1'b1; len_l <= f_len; end
      if (wr && widx == 5'd29 && pwdata[2]) begin
         ready <= 1'b0; rd_addr <= 0; len_l <= 16'd0;
      end
      if (rd && widx == 5'd31) rd_addr <= rd_addr + 1'b1;
   end

   always @(*) begin
      case (widx)
         5'd30: prdata = {15'd0, ready, len_l[15:0]};
         5'd31: prdata = rd_data;
         default: prdata = 32'd0;
      endcase
   end
endmodule
