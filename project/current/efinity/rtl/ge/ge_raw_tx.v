//=============================================================================
// ge_raw_tx.v - one-frame Ethernet transmitter fed by the SoC over APB
//   firmware composes the WHOLE frame (eth + ip + udp/tcp headers + payload)
//   RTL adds preamble/SFD and FCS.  No udp_tx/ip_tx/mac_tx involved.
//   APB regs (paddr[6:2]): 27 TXDATA(W) 28 TXLEN(W) 29 CTRL(W)/STATUS(R) 30 PKTS(R)
//=============================================================================
`timescale 1 ns / 1 ns
module ge_raw_tx (
   input                 clk,
   input      [31:0]     paddr,
   input                 psel,
   input                 penable,
   input                 pwrite,
   input      [31:0]     pwdata,
   output reg [31:0]     prdata,
   input                 tx_clk,
   output reg [7:0]      gmii_txd,
   output reg            gmii_tx_en,
   output reg            tx_done
);
   localparam AW = 9;                     // 512 x 32 = 2 KB（HTTP 响应够用）
   // ---- buffer written from APB ----
   reg  [AW-1:0] wptr;
   reg  [AW-1:0] waddr_r;   /* 与 wdata 同拍寄存的写地址（否则数据整体错一个字） */
   reg  [31:0]   wdata;
   reg           wen;
   reg  [15:0]   txlen;
   reg           go_level;
   reg  [AW-1:0] rdaddr;
   wire [31:0]   rddata;
   ge_dpram32 #(.AW(AW)) u_ram (
      .wr_clk(clk), .wr_en(wen), .wr_addr(waddr_r), .wr_data(wdata),
      .rd_clk(tx_clk), .rd_addr(rdaddr), .rd_data(rddata));

   wire wr = psel && penable && pwrite;
   wire [4:0] widx = paddr[6:2];
   always @(posedge clk) begin
      wen <= 1'b0;
      if (wr && widx == 5'd27) begin wdata <= pwdata; wen <= 1'b1; waddr_r <= wptr; wptr <= wptr + 1'b1; end
      if (wr && widx == 5'd28) txlen <= pwdata[15:0];
      if (wr && widx == 5'd29) go_level <= pwdata[0];
      if (wr && widx == 5'd29 && pwdata[1]) wptr <= 0;
   end
   always @(*) begin
      case (widx)
         5'd29: prdata = {pkt_cnt[15:0], 14'd0, busy_s, done_s};   /* 高 16 位=已发包数 */
         5'd30: prdata = {16'd0, pkt_cnt};
         default: prdata = 32'd0;
      endcase
   end

   // ---- tx side ----
   reg  [1:0]  go_s;
   reg         busy, done_l;
   reg  [15:0] pkt_cnt;
   reg         busy_s, done_s;
   always @(posedge clk) begin busy_s <= busy; done_s <= done_l; end
   always @(posedge tx_clk) go_s <= {go_s[0], go_level};

   localparam S_IDLE = 3'd0, S_PRE = 3'd1, S_DATA = 3'd2, S_CRC = 3'd3, S_GAP = 3'd4;
   reg  [2:0]  st;
   reg  [2:0]  pre_cnt;
   reg  [15:0] idx;
   reg  [1:0]  bsel;
   reg  [31:0] cur;
   reg  [1:0]  crc_cnt;
   reg  [7:0]  crc_byte;
   reg  [15:0] gap;
   reg         crc_en;
   reg  [7:0]  crc_din;
   wire [31:0] crc_val;
   wire [31:0] crc_nxt;
   crc u_crc (.Clk(tx_clk), .Reset(1'b0), .Data_in(crc_din), .Enable(crc_en),
              .Crc(crc_val), .CrcNext(crc_nxt));

   wire [7:0] cur_byte =
      (bsel == 2'd0) ? cur[7:0] : (bsel == 2'd1) ? cur[15:8] :
      (bsel == 2'd2) ? cur[23:16] : cur[31:24];

   always @(posedge tx_clk) begin
      crc_en  <= 1'b0;
      crc_din <= 8'd0;
      tx_done <= 1'b0;
      case (st)
         S_IDLE: begin
            gmii_tx_en <= 1'b0;
            busy <= 1'b0;
            if (go_s == 2'b01 && txlen != 0) begin
               busy <= 1'b1; done_l <= 1'b0;
               st <= S_PRE; pre_cnt <= 3'd0; idx <= 16'd0; bsel <= 2'd0;
               rdaddr <= 0; gap <= 16'd0;
            end
         end
         S_PRE: begin
            gmii_tx_en <= 1'b1;
            gmii_txd   <= (pre_cnt == 3'd7) ? 8'hD5 : 8'h55;
            pre_cnt    <= pre_cnt + 1'b1;
            /* rd_data 是一拍延迟：pre_cnt==1 这一拍 rd_data 才是 mem[0]。
               之前每拍都写 cur<=rddata，导致首字被跳过、整帧前移 4 字节。 */
            if (pre_cnt == 3'd1) begin cur <= rddata; rdaddr <= 1'b1; end
            if (pre_cnt == 3'd7) st <= S_DATA;
         end
         S_DATA: begin
            gmii_tx_en <= 1'b1;
            gmii_txd   <= cur_byte;
            crc_en     <= 1'b1;
            crc_din    <= cur_byte;
            idx <= idx + 1'b1;
            if (idx + 1'b1 >= txlen) begin
               st <= S_GAP; gap <= 16'd0;      /* FCS 由固件算好放在帧尾 */
            end else if (bsel == 2'd3) begin
               bsel <= 2'd0; rdaddr <= rdaddr + 1'b1; cur <= rddata;
            end else begin
               bsel <= bsel + 1'b1;
            end
         end
         S_CRC: begin
            gmii_tx_en <= 1'b1;
            case (crc_cnt)
               2'd0: gmii_txd <= ~crc_val[7:0];
               2'd1: gmii_txd <= ~crc_val[15:8];
               2'd2: gmii_txd <= ~crc_val[23:16];
               default: gmii_txd <= ~crc_val[31:24];
            endcase
            crc_cnt <= crc_cnt + 1'b1;
            if (crc_cnt == 2'd3) st <= S_GAP;
         end
         S_GAP: begin
            gmii_tx_en <= 1'b0;
            gmii_txd   <= 8'd0;
            gap <= gap + 1'b1;
            if (gap >= 16'd12) begin
               pkt_cnt <= pkt_cnt + 1'b1;
               done_l  <= 1'b1;
               tx_done <= 1'b1;
               busy    <= 1'b0;
               st <= S_IDLE;
            end
         end
      endcase
   end
endmodule