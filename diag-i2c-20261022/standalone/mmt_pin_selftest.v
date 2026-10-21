`timescale 1ns / 1ps
//==========================================================================
//  mmt_pin_selftest.v — I2C 引脚自检（独立工程 PERIPH02 用）
//--------------------------------------------------------------------------
//  目的：把「从机不应答」拆成三种互斥可能，串口直出，不需要示波器：
//    PT=0 两条线都释放    RD 应为 11   不是 11 说明总线被外部拉住
//    PT=1 只拉低 SCL      RD 应为 01   SCL 的「输出+输入」回路自洽
//    PT=2 只拉低 SDA      RD 应为 10   SDA 的回路自洽
//    PT=3 两条都拉低      RD 应为 00
//  纯开漏：只拉低(oe=1,o=0)或释放，从不推高。
//  每 REPORT_MS 打一行 "PT=x RD=ab"（ab = 读回 {SCL,SDA}），115200 8N1。
//==========================================================================
module mmt_pin_selftest #(
    parameter CLK_HZ   = 27_000_000,
    parameter PHASE_MS = 3000,      // 每相位时长
    parameter BAUD     = 115200,
    parameter REPORT_MS= 500        // 报文周期（相位内可看多行）
)(
    input  wire       clk, rst_n,
    input  wire       scl_i, sda_i,
    output wire       scl_o, scl_oe, sda_o, sda_oe,
    output wire [1:0] pt,
    output wire [1:0] rd,
    output wire       uart_txd
);
    assign scl_o = 1'b0;
    assign sda_o = 1'b0;
    assign scl_oe = pt[0];          // bit0 = 拉低 SCL
    assign sda_oe = pt[1];          // bit1 = 拉低 SDA
    assign rd     = {scl_i, sda_i};

    //---------------- 相位机 ----------------
    localparam integer PH_CNT = (CLK_HZ / 1000) * PHASE_MS;
    reg [1:0]  ph;
    reg [31:0] phc;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin ph <= 2'd0; phc <= 32'd0; end
        else if (phc == PH_CNT - 1) begin phc <= 32'd0; ph <= ph + 2'd1; end
        else phc <= phc + 32'd1;
    end
    assign pt = ph;

    //---------------- 报文 ----------------
    // 报文格式：PT=x RD=ab + CRLF，共 12 字节
    localparam N = 12;
    reg [8*N-1:0] rec;
    reg [31:0]    rtc;
    reg [3:0]     idx;
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
                    rec <= {"PT=", (8'd48 + {6'd0, ph}), " RD=",
                            (sda_i ? 8'd49 : 8'd48), (scl_i ? 8'd49 : 8'd48), 8'h0d, 8'h0a};
                    idx <= 4'd0; active <= 1'b1;
                end
            end else rtc <= rtc + 32'd1;
            if (start) begin
                if (idx == N-1) active <= 1'b0;
                else idx <= idx + 4'd1;
            end else if (active && !busy) start <= 1'b1;
        end
    end
endmodule