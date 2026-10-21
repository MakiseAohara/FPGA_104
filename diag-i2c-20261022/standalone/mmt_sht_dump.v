`timescale 1ns / 1ps
// SHT30 原始字节直出：发 0x2C06 -> 等 20ms -> 读 6 字节 -> 串口打 hex。
// 目的：看清 CRC 到底是对着什么字节失败的，不再靠猜。
module mmt_sht_dump #(
    parameter CLK_HZ = 27_000_000,
    parameter BAUD   = 115200
)(
    input  wire clk, rst_n,
    input  wire scl_i, sda_i,
    output wire scl_o, scl_oe, sda_o, sda_oe,
    output wire uart_txd
);
    localparam [6:0] DEV = 7'h44;

    reg  [6:0]  dev;
    reg  [31:0] tx;
    reg  [2:0]  txl;
    reg  [7:0]  rdl;
    reg         req;
    wire        busy, done, err, rdv;
    wire [7:0]  rdd;

    mmt_i2c_master #(.CLK_HZ(CLK_HZ), .SCL_HZ(100_000)) u_m (
        .clk(clk), .rst_n(rst_n), .req(req), .dev_addr(dev),
        .tx_data(tx), .tx_len(txl), .rd_len(rdl),
        .busy(busy), .done(done), .err(err), .rd_data(rdd), .rd_valid(rdv),
        .scl_i(scl_i), .scl_o(scl_o), .scl_oe(scl_oe),
        .sda_i(sda_i), .sda_o(sda_o), .sda_oe(sda_oe));

    function [7:0] hx;
        input [3:0] n;
        begin hx = (n < 4'd10) ? (8'd48 + {4'd0, n}) : (8'd55 + {4'd0, n}); end
    endfunction

    localparam [2:0] S_CMD = 3'd0, S_CMD_W = 3'd1, S_DLY = 3'd2,
                     S_RD = 3'd3, S_RD_W = 3'd4, S_PRT = 3'd5, S_PER = 3'd6;
    reg [2:0]  st;
    reg [31:0] tk;
    reg [2:0]  bi;
    reg [7:0]  rx [0:5];
    reg        er1, er2;

    // 报文 "B=aabb ccdd eeff E=n" + CRLF = 22 字节
    localparam N = 22;
    reg [8*N-1:0] rec;
    reg [4:0]     idx;
    reg           active, start;
    wire          tbusy;
    wire [7:0]    odata = rec[8*(N-1-idx) +: 8];

    mmt_uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_uart (
        .clk(clk), .rst_n(rst_n), .start(start), .data(odata), .txd(uart_txd), .busy(tbusy));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_CMD; tk <= 0; bi <= 0; req <= 0; dev <= DEV; tx <= 0; txl <= 0; rdl <= 0;
            er1 <= 0; er2 <= 0; idx <= 0; active <= 0; start <= 0; rec <= 0;
        end else begin
            start <= 1'b0;
            case (st)
              S_CMD: begin
                  dev <= DEV; tx <= 32'h0000_2C06; txl <= 3'd2; rdl <= 8'd0;
                  req <= 1'b1; st <= S_CMD_W;
              end
              S_CMD_W: begin
                  if (done) begin req <= 1'b0; er1 <= err; tk <= 0; st <= S_DLY; end
              end
              S_DLY: begin
                  if (tk >= (CLK_HZ/1000)*20 - 1) st <= S_RD; else tk <= tk + 1'b1;
              end
              S_RD: begin
                  dev <= DEV; txl <= 3'd0; rdl <= 8'd6; bi <= 3'd0;
                  req <= 1'b1; st <= S_RD_W;
              end
              S_RD_W: begin
                  if (rdv && bi < 3'd6) begin rx[bi] <= rdd; bi <= bi + 3'd1; end
                  if (done) begin req <= 1'b0; er2 <= err; st <= S_PRT; end
              end
              S_PRT: begin
                  if (!active && !tbusy) begin
                      rec <= {"B=", hx(rx[0][7:4]), hx(rx[0][3:0]), hx(rx[1][7:4]), hx(rx[1][3:0]),
                              " ",  hx(rx[2][7:4]), hx(rx[2][3:0]), hx(rx[3][7:4]), hx(rx[3][3:0]),
                              " ",  hx(rx[4][7:4]), hx(rx[4][3:0]), hx(rx[5][7:4]), hx(rx[5][3:0]),
                              " E=", (er1|er2) ? 8'd49 : 8'd48, 8'h0d, 8'h0a};
                      idx <= 5'd0; active <= 1'b1;
                  end
                  if (start) begin
                      if (idx == N-1) begin active <= 1'b0; tk <= 0; st <= S_PER; end
                      else idx <= idx + 5'd1;
                  end else if (active && !tbusy) start <= 1'b1;
              end
              S_PER: begin
                  if (tk >= (CLK_HZ/1000)*1000 - 1) begin tk <= 0; st <= S_CMD; end
                  else tk <= tk + 1'b1;
              end
              default: st <= S_CMD;
            endcase
        end
    end
endmodule