`timescale 1ns / 1ps
// 独立地址扫描：0x08..0x77 逐地址探测（纯开漏），串口直出 "P=nn A=xx B=xx S=nn"。
// P = 本轮应答地址个数；A/B = 前两个应答地址；S = 已扫轮数。
module mmt_scan_report #(
    parameter CLK_HZ    = 27_000_000,
    parameter BAUD      = 115200,
    parameter SCL_HZ    = 50_000,
    parameter REPORT_MS = 500
)(
    input  wire clk, rst_n,
    input  wire scl_i, sda_i,
    output wire scl_o, scl_oe, sda_o, sda_oe,
    output wire uart_txd
);
    wire [7:0] cnt, scans;
    wire [6:0] a0, a1;
    wire       act;

    v7_i2c_probe #(.CLK_HZ(CLK_HZ), .SCL_HZ(SCL_HZ)) u_probe (
        .clk(clk), .rst_n(rst_n), .en(1'b1),
        .scl_i(scl_i), .sda_i(sda_i),
        .scl_o(scl_o), .scl_oe(scl_oe), .sda_o(sda_o), .sda_oe(sda_oe),
        .active(act), .res_cnt(cnt), .res_a0(a0), .res_a1(a1), .scans(scans));

    function [7:0] hx;
        input [3:0] n;
        begin hx = (n < 4'd10) ? (8'd48 + {4'd0, n}) : (8'd55 + {4'd0, n}); end
    endfunction

    // "P=02 A=44 B=33 S=01" + CRLF = 21 字节
    localparam N = 21;
    reg [8*N-1:0] rec;
    reg [31:0]    rtc;
    reg [4:0]     idx;
    reg           active, start;
    wire          busy;
    wire [7:0]    data = rec[8*(N-1-idx) +: 8];

    mmt_uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_uart (
        .clk(clk), .rst_n(rst_n), .start(start), .data(data), .txd(uart_txd), .busy(busy));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin rec <= 0; rtc <= 0; idx <= 0; active <= 0; start <= 0; end
        else begin
            start <= 1'b0;
            if (rtc == (CLK_HZ/1000)*REPORT_MS - 1) begin
                rtc <= 32'd0;
                if (!active && !busy) begin
                    rec <= {"P=", hx(cnt[7:4]), hx(cnt[3:0]),
                            " A=", hx({1'b0,a0[6:4]}), hx(a0[3:0]),
                            " B=", hx({1'b0,a1[6:4]}), hx(a1[3:0]),
                            " S=", hx(scans[7:4]), hx(scans[3:0]),
                            8'h0d, 8'h0a};
                    idx <= 5'd0; active <= 1'b1;
                end
            end else rtc <= rtc + 32'd1;
            if (start) begin
                if (idx == N-1) active <= 1'b0;
                else idx <= idx + 5'd1;
            end else if (active && !busy) start <= 1'b1;
        end
    end
endmodule