`timescale 1 ns / 1 ps
module ge_top_user (
   input                 clk,
   input      [31:0]     paddr,
   input                 psel,
   input                 penable,
   input                 pwrite,
   input      [31:0]     pwdata,
   output     [31:0]     prdata,
   input                 rxc,
   input      [3:0]      rxd_hi_i,
   input      [3:0]      rxd_lo_i,
   input                 rx_dv_HI,
   input                 rx_dv_LO,
   output                tx_en_o_HI,
   output                tx_en_o_LO,
   output                txc_hi_o,
   output                txc_lo_o,
   output     [3:0]      txd_hi_o,
   output     [3:0]      txd_lo_o,
   output                phy_rst_n
);
   reg  [3:0] align_rxd_hi;
   wire [3:0] align_rxd_lo;
   reg        align_rx_dv_hi;
   wire       align_rx_dv_lo;
   always @(posedge rxc) begin
      align_rxd_hi   <= rxd_hi_i;
      align_rx_dv_hi <= rx_dv_HI;
   end
   assign align_rxd_lo   = rxd_lo_i;
   assign align_rx_dv_lo = rx_dv_LO;
   assign phy_rst_n      = 1'b1;

   wire       gmii_tx_clk, gmii_rx_clk;
   wire [7:0] gmii_txd;
   wire       gmii_tx_en;
   wire [7:0] gmii_rxd;
   wire       gmii_rx_dv, gmii_rx_er, gmii_crs, gmii_col;
   util_gmii_to_rgmii u_rgmii (
      .rst_n(1'b1), .rgmii_rxc(rxc),
      .rgmii_rx_hi(align_rxd_lo), .rgmii_rx_lo(align_rxd_hi),
      .rgmii_rx_dv(align_rx_dv_lo), .rgmii_rx_er(align_rx_dv_hi),
      .rgmii_tx_ctrl_hi(tx_en_o_HI), .rgmii_tx_ctrl_lo(tx_en_o_LO),
      .rgmii_txd_lo(txd_lo_o), .rgmii_txd_hi(txd_hi_o),
      .gmii_txd(gmii_txd), .gmii_tx_en(gmii_tx_en), .gmii_tx_er(1'b0),
      .gmii_tx_clk(gmii_tx_clk), .gmii_crs(gmii_crs), .gmii_col(gmii_col),
      .gmii_rxd(gmii_rxd), .gmii_rx_dv(gmii_rx_dv), .gmii_rx_er(gmii_rx_er),
      .gmii_rx_clk(gmii_rx_clk), .duplex_mode(1'b1));
   assign txc_hi_o = 1'b1;
   assign txc_lo_o = 1'b0;

   wire [31:0] tx_prdata, rx_prdata;
   wire [4:0]  widx = paddr[6:2];
   assign prdata = (widx <= 5'd29) ? tx_prdata : rx_prdata;

   ge_raw_tx u_tx (
      .clk(clk), .paddr(paddr), .psel(psel), .penable(penable), .pwrite(pwrite),
      .pwdata(pwdata), .prdata(tx_prdata), .tx_clk(gmii_tx_clk),
      .gmii_txd(gmii_txd), .gmii_tx_en(gmii_tx_en), .tx_done());

   ge_raw_rx u_rx (
      .clk(clk), .paddr(paddr), .psel(psel), .penable(penable), .pwrite(pwrite),
      .pwdata(pwdata), .prdata(rx_prdata),
      .rx_clk(gmii_rx_clk), .rx_dv(gmii_rx_dv), .rxd(gmii_rxd));
endmodule