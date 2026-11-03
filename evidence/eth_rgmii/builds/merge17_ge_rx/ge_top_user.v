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
   /* RX_CTL 的下降沿是 RXERR，不需要；RXDV 在上升沿采样即可（H3=EXT_CONFIG_CLK 复用脚不支持 DDIO） */
   assign align_rx_dv_lo = 1'b0;
   /* PHY 复位脉冲：上电/配置后先拉低约 84 ms（core_clk 100 MHz 的 bit23），再释放。
   之前是恒 1，等于从没复位过 PHY；反复重配后 PHY 可能停在半初始化状态，导致不建链。 */
reg [23:0] phy_rst_cnt = 24'd0;
always @(posedge clk) if (!phy_rst_cnt[23]) phy_rst_cnt <= phy_rst_cnt + 1'b1;
assign phy_rst_n      = phy_rst_cnt[23];

   wire       gmii_tx_clk, gmii_rx_clk;
   wire [7:0] gmii_txd, gmii_rxd;
   wire       gmii_tx_en, gmii_rx_dv, gmii_rx_er, gmii_crs, gmii_col;
   util_gmii_to_rgmii u_rgmii (
      .rst_n(1'b1), .rgmii_rxc(rxc),
      .rgmii_rx_hi(align_rxd_lo), .rgmii_rx_lo(align_rxd_hi),
      .rgmii_rx_dv(align_rx_dv_hi), .rgmii_rx_er(1'b0),
      .rgmii_tx_ctrl_hi(tx_en_o_HI), .rgmii_tx_ctrl_lo(tx_en_o_LO),
      .rgmii_txd_lo(txd_lo_o), .rgmii_txd_hi(txd_hi_o),
      .gmii_txd(gmii_txd), .gmii_tx_en(gmii_tx_en), .gmii_tx_er(1'b0),
      .gmii_tx_clk(gmii_tx_clk), .gmii_crs(gmii_crs), .gmii_col(gmii_col),
      .gmii_rxd(gmii_rxd), .gmii_rx_dv(gmii_rx_dv), .gmii_rx_er(gmii_rx_er),
      .gmii_rx_clk(gmii_rx_clk), .duplex_mode(1'b1));
   assign txc_hi_o = 1'b1;
   assign txc_lo_o = 1'b0;

   /* ---- 发送：自研 raw TX（已验证可发任意长度帧） ---- */
   wire [31:0] tx_prdata, rx_prdata;
   wire [4:0]  widx = paddr[6:2];
   assign prdata = (widx <= 5'd29) ? tx_prdata : rx_prdata;
   ge_raw_tx u_tx (
      .clk(clk), .paddr(paddr), .psel(psel), .penable(penable), .pwrite(pwrite),
      .pwdata(pwdata), .prdata(tx_prdata), .tx_clk(gmii_tx_clk),
      .gmii_txd(gmii_txd), .gmii_tx_en(gmii_tx_en), .tx_done());

   /* ---- 接收：厂商 gmii_arbi（RX 缓冲/对齐）+ mac_top ---- */
   wire [15:0] pack_total_len;
   wire        e_rst_n, e_rx_dv, e_tx_en;
   wire [7:0]  e_rxd, e_txd;
   gmii_arbi u_arbi (
      .clk(gmii_tx_clk), .rst_n(1'b1), .speed(2'b10), .link(1'b1),
      .pack_total_len(pack_total_len), .e_rst_n(e_rst_n),
      .gmii_rx_dv(gmii_rx_dv), .gmii_rxd(gmii_rxd),
      .gmii_tx_en(gmii_tx_en), .gmii_txd(gmii_txd),
      .e_rx_dv(e_rx_dv), .e_rxd(e_rxd), .e_tx_en(e_tx_en), .e_txd(e_txd));
   reg        rx_dv_d;
   reg  [7:0] rxd_d;
   always @(posedge gmii_tx_clk) begin
      rx_dv_d <= e_rx_dv;
      rxd_d   <= e_rxd;
   end
   wire [7:0]  udp_rec_ram_rdata;
   wire [10:0] udp_rec_ram_read_addr;
   wire [15:0] udp_rec_data_length;
   wire        udp_rec_data_valid;
   wire        arp_found, mac_not_exist;
   mac_top u_mac (
      .gmii_tx_clk(gmii_tx_clk), .gmii_rx_clk(gmii_rx_clk), .rst_n(1'b1),
      .source_mac_addr(48'h00_0a_35_01_fe_c0), .TTL(8'h80),
      .source_ip_addr(32'hA9FE2F3E), .destination_ip_addr(32'hA9FE2F3D),
      .udp_send_source_port(16'h1f90), .udp_send_destination_port(16'h1f90),
      .ram_wr_data(8'd0), .ram_wr_en(1'b0),
      .udp_ram_data_req(), .udp_send_data_length(16'd0),
      .udp_tx_req(1'b0), .arp_request_req(1'b0),
      .mac_data_valid(), .mac_send_end(), .mac_tx_data(),
      .rx_dv(rx_dv_d), .mac_rx_datain(rxd_d),
      .udp_rec_ram_rdata(udp_rec_ram_rdata),
      .udp_rec_ram_read_addr(udp_rec_ram_read_addr),
      .udp_rec_data_length(udp_rec_data_length),
      .udp_rec_data_valid(udp_rec_data_valid),
      .arp_found(arp_found), .mac_not_exist(mac_not_exist));

   /* ---- 接收：自研 ge_raw_rx（整帧进 BRAM，固件按 word30/31 读） ----
      原来接的是厂商 ge_udp_rx_bridge，它只把 UDP 负载搬到 APB，帧头/ARP/TCP 全被丢掉，
      固件的 net_core（ARP/ICMP/TCP/HTTP）根本拿不到完整帧 —— 这是"板内网页"不通的直接原因。 */
   ge_raw_rx u_rx (
      .clk(clk), .paddr(paddr), .psel(psel), .penable(penable),
      .pwrite(pwrite), .pwdata(pwdata), .prdata(rx_prdata),
      .rx_clk(gmii_rx_clk), .rx_dv(gmii_rx_dv), .rxd(gmii_rxd));

endmodule
