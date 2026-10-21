`timescale 1ns / 1ps
// Ti60F225-V4 独立引脚自检：无摄像头、无 DDR、无软核。
// 27 MHz 与 UART 引脚沿用板载厂商 UART 例程（同 2026-10-20 独立诊断工程）。
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
    // 上电复位：约 65k 拍（27MHz 下 ~2.4 ms），与独立诊断工程一致
    reg [15:0] poweron = 16'd0;
    always @(posedge clk_27m or negedge reset_n) begin
        if (!reset_n) poweron <= 16'd0;
        else if (!(&poweron)) poweron <= poweron + 1'b1;
    end
    wire ready = &poweron;

    wire [1:0] pt, rd;
    mmt_pin_selftest #(.CLK_HZ(27_000_000), .PHASE_MS(3000), .BAUD(115200)) u_pt (
        .clk(clk_27m), .rst_n(ready),
        .scl_i(i_sensor_scl), .sda_i(i_sensor_sda),
        .scl_o(o_sensor_scl), .scl_oe(o_sensor_scl_oe),
        .sda_o(o_sensor_sda), .sda_oe(o_sensor_sda_oe),
        .pt(pt), .rd(rd), .uart_txd(o_uart_txd));

    // LED 低有效：LED0 在 PT bit0 的相位点亮，方便肉眼确认相位切换
    assign led = {1'b1, ~pt[0]};
    assign o_buzzer = 1'b0;
endmodule