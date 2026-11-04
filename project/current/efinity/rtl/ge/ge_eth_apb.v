//=============================================================================
// ge_eth_apb.v - GE (RGMII) APB bridge: SoC <-> UDP payloads
//   TX: APB writes 32-bit words into 512 B buffer, then GO -> one UDP packet
//   RX: one received UDP packet lands in 512 B buffer, readable over APB
//   APB domain = core_clk (100 MHz); GE domain = rxc (125 MHz from PHY)
//   reg map (paddr[6:2]): 27 TXDATA(W) 28 TXLEN(W) 29 CTRL(W/R) 30 STATUS(R) 31 RXDATA(R)
//=============================================================================
`timescale 1 ns / 1 ns

module ge_dpram32 #(parameter AW = 7) (
   input                 wr_clk,
   input                 wr_en,
   input      [AW-1:0]   wr_addr,
   input      [31:0]     wr_data,
   input                 rd_clk,
   input      [AW-1:0]   rd_addr,
   output reg [31:0]     rd_data
);
   reg [31:0] mem [0:(1<<AW)-1];
   always @(posedge wr_clk) if (wr_en) mem[wr_addr] <= wr_data;
   always @(posedge rd_clk) rd_data <= mem[rd_addr];
endmodule

module ge_eth_apb (
   input                 clk,
   input      [31:0]     paddr,
   input                 psel,
   input                 penable,
   input                 pwrite,
   input      [31:0]     pwdata,
   output reg [31:0]     prdata,
   input                 ge_clk,
   input                 arp_found,
   input                 mac_send_end,
   output reg [7:0]      ram_wr_data,
   output reg            ram_wr_en,
   input                 udp_ram_data_req,
   output reg [15:0]     udp_send_data_length,
   output reg            udp_tx_req,
   output reg            arp_request_req,
   input      [7:0]      udp_rec_ram_rdata,
   output reg [10:0]     udp_rec_ram_read_addr,
   input      [15:0]     udp_rec_data_length,
   input                 udp_rec_data_valid
);
   localparam AW = 7;

   wire wr = psel && penable && pwrite;
   wire rd = psel && penable && !pwrite;
   wire [4:0] widx = paddr[6:2];

   reg  [AW-1:0] tx_wptr;
   reg  [15:0]   tx_len;
   reg           go_tgl;
   reg  [AW-1:0] rx_rptr;
   reg  [31:0]   rx_ram_q;
   reg           rx_flip;
   reg           tx_wren;
   reg  [31:0]   tx_wdata;
   reg  [AW-1:0] ge_rd_addr;
   wire [31:0]   ge_rd_data;

   ge_dpram32 #(.AW(AW)) u_tx_ram (
      .wr_clk(clk), .wr_en(tx_wren), .wr_addr(tx_wptr), .wr_data(tx_wdata),
      .rd_clk(ge_clk), .rd_addr(ge_rd_addr), .rd_data(ge_rd_data));

   reg  [AW-1:0] ge_wr_addr;
   reg  [31:0]   ge_wr_data;
   reg           ge_wr_en;
   ge_dpram32 #(.AW(AW)) u_rx_ram (
      .wr_clk(ge_clk), .wr_en(ge_wr_en), .wr_addr(ge_wr_addr), .wr_data(ge_wr_data),
      .rd_clk(clk), .rd_addr(rx_rptr), .rd_data(rx_ram_q));

   reg  [2:0]  busy_s, arp_s, done_s, rxvalid_s;
   reg  [15:0] pkt_cnt_s, rx_len_s;
   reg         arp_ok_s;
   always @(posedge clk) arp_ok_s <= arp_ok;
   reg         ge_busy, done_tgl, rx_tgl;
   reg  [15:0] pkt_cnt, rx_len;

   always @(posedge clk) begin
      busy_s    <= {busy_s[1:0],    ge_busy};
      arp_s     <= {arp_s[1:0],     arp_found};
      done_s    <= {done_s[1:0],    done_tgl};
      rxvalid_s <= {rxvalid_s[1:0], rx_tgl};
      pkt_cnt_s <= pkt_cnt;
      rx_len_s  <= rx_len;
   end

   always @(posedge clk) begin
      tx_wren  <= 1'b0;
      rx_flip  <= 1'b0;
      if (wr && widx == 5'd27) begin
         tx_wdata <= pwdata; tx_wren <= 1'b1;
         tx_wptr  <= tx_wptr + 1'b1;
      end
      if (wr && widx == 5'd28) tx_len <= pwdata[15:0];
      if (wr && widx == 5'd29) begin
         if (pwdata[0]) go_tgl <= ~go_tgl;
         if (pwdata[1]) begin tx_wptr <= 0; rx_rptr <= 0; rx_flip <= 1'b1; end
      end
      if (rd && widx == 5'd31) rx_rptr <= rx_rptr + 1'b1;
   end

   always @(*) begin
      case (widx)
         5'd29: prdata = {28'd0, rxvalid_s[2], done_s[2], busy_s[2], arp_ok_s};
         5'd30: prdata = {pkt_cnt_s, rx_len_s};
         5'd31: prdata = rx_ram_q;
         default: prdata = 32'd0;
      endcase
   end

   localparam S_IDLE = 3'd0, S_PRE = 3'd1, S_STREAM = 3'd2, S_REQ = 3'd3, S_END = 3'd4;
   reg  [2:0]  st;
   reg  [1:0]  go_s;
   reg  [15:0] sent;
   reg  [1:0]  bsel;
   reg  [31:0] cur_word;
   reg  [2:0]  req_cnt;
   reg  [7:0]  cur_byte;
   reg  [16:0] arp_tick;
   reg  [1:0]  rx_flip_s;
   reg         arp_ok;          /* sticky: ARP 已解析过 */

   always @(posedge ge_clk) begin
      go_s <= {go_s[0], go_tgl};
   end

   always @(posedge ge_clk) begin
      ram_wr_en       <= 1'b0;
      udp_tx_req      <= 1'b0;
      arp_request_req <= 1'b0;
      arp_tick        <= arp_tick + 1'b1;
      case (st)
         S_IDLE: begin
            ge_busy <= 1'b0;
            // keep ARP resolved: ask every ~1M cycles until found
            if (!arp_ok && arp_tick == 17'd0) arp_request_req <= 1'b1;
            if (go_s[1] != go_s[0] && tx_len != 0 && arp_ok) begin
               ge_busy <= 1'b1;
               ge_rd_addr <= 0;
               bsel <= 2'd0;
               sent <= 16'd0;
               udp_send_data_length <= tx_len;
               st <= S_PRE;
            end
         end
         S_PRE: begin
            cur_word <= ge_rd_data;
            st <= S_STREAM;
         end
         S_STREAM: begin
            ram_wr_en   <= 1'b1;
            ram_wr_data <= cur_byte;
            sent        <= sent + 1'b1;
            if (sent + 1'b1 >= tx_len) begin
               st <= S_REQ;
               req_cnt <= 3'd0;
            end else if (bsel == 2'd3) begin
               bsel <= 2'd0;
               ge_rd_addr <= ge_rd_addr + 1'b1;
               cur_word <= ge_rd_data;
            end else begin
               bsel <= bsel + 1'b1;
            end
         end
         S_REQ: begin
            udp_send_data_length <= tx_len;
            udp_tx_req <= 1'b1;
            req_cnt <= req_cnt + 1'b1;
            if (req_cnt == 3'd5) st <= S_END;
         end
         S_END: begin
            if (mac_send_end) begin
               pkt_cnt  <= pkt_cnt + 1'b1;
               done_tgl <= ~done_tgl;
               ge_busy  <= 1'b0;
               st <= S_IDLE;
            end
         end
      endcase
   end

   always @(*) begin
      case (bsel)
         2'd0: cur_byte = cur_word[7:0];
         2'd1: cur_byte = cur_word[15:8];
         2'd2: cur_byte = cur_word[23:16];
         default: cur_byte = cur_word[31:24];
      endcase
   end

   // ---------------- RX: packet -> buffer ----------------
   reg  [1:0]  rx_st;
   reg  [10:0] rx_i;
   reg  [1:0]  rx_bsel;
   reg  [31:0] rx_word;
   reg  [AW-1:0] rx_wptr;

   always @(posedge ge_clk) rx_flip_s <= {rx_flip_s[0], rx_flip};

   always @(posedge ge_clk) if (arp_found) arp_ok <= 1'b1;

   always @(posedge ge_clk) begin
      if (rx_st == 2'd0) begin
         if (udp_rec_data_valid) begin
            rx_len     <= udp_rec_data_length;
            rx_i       <= 11'd0;
            rx_bsel    <= 2'd0;
            rx_wptr    <= 0;
            udp_rec_ram_read_addr <= 11'd0;
            rx_st      <= 2'd1;
         end
      end else begin
         udp_rec_ram_read_addr <= rx_i + 11'd1;
         if (rx_i < rx_len) begin
            case (rx_bsel)
               2'd0: rx_word[7:0]   <= udp_rec_ram_rdata;
               2'd1: rx_word[15:8]  <= udp_rec_ram_rdata;
               2'd2: rx_word[23:16] <= udp_rec_ram_rdata;
               default: rx_word[31:24] <= udp_rec_ram_rdata;
            endcase
            rx_i    <= rx_i + 11'd1;
            rx_bsel <= rx_bsel + 2'd1;
            if (rx_bsel == 2'd3) begin
               ge_wr_en  <= 1'b1;
               case (rx_bsel)
                  2'd3: ge_wr_data <= {udp_rec_ram_rdata, rx_word[23:0]};
                  default: ge_wr_data <= rx_word;
               endcase
               ge_wr_addr <= rx_wptr;
               rx_wptr    <= rx_wptr + 1'b1;
            end
         end else begin
            rx_st  <= 2'd0;
            rx_tgl <= ~rx_tgl;
         end
      end
      if (rx_flip_s[1] != rx_flip_s[0]) rx_tgl <= 1'b0;
   end

endmodule
