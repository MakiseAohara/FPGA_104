`timescale 1ns / 1ps
// Ti60F225-V4 独立 I2C 地址扫描：无摄像头、无 DDR、无软核。
module mmt_peripheral_board_top (
    input  wire       clk_27m,
    input  wire       reset_n,
    input  wire       i_sensor_scl,
    input  wire       i_sensor_sda,
    output wire       o_sensor_scl,
    output wire       o_sensor_scl_oe,
    output wire       o_sensor_sda,
    output wire       o_sensor_sda_oe,
    output wire       o_uart_txd,
    output wire       o_buzzer,
    output wire [1:0] led
);
    reg [15:0] poweron = 16'd0;
    always @(posedge clk_27m or negedge reset_n) begin
        if (!reset_n) poweron <= 16'd0;
        else if (!(&poweron)) poweron <= poweron + 1'b1;
    end
    wire ready = &poweron;

    wire act, scl_o, scl_oe, sda_o, sda_oe;
    mmt_scan_report #(.CLK_HZ(27_000_000), .BAUD(115200), .SCL_HZ(50_000)) u_scan (
        .clk(clk_27m), .rst_n(ready),
        .scl_i(i_sensor_scl), .sda_i(i_sensor_sda),
        .scl_o(o_sensor_scl), .scl_oe(o_sensor_scl_oe),
        .sda_o(o_sensor_sda), .sda_oe(o_sensor_sda_oe),
        .uart_txd(o_uart_txd));

    assign led = {1'b1, 1'b1};
    assign o_buzzer = 1'b0;
endmodule