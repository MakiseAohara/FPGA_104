//==========================================================================
//  mmt_dpram.v  —  简单双口 RAM（独立写口 + 独立读口），由 Efinity 推断为 BRAM
//--------------------------------------------------------------------------
//  ★ 这个模板是【实测验证能正确推断 BRAM】的写法，原因（踩过的坑，别改）：
//     - **读和写必须放在两个独立的 always 块**里。
//       如果把读写塞进同一个 always 块、再套上各种条件使能，Efinity 会报
//       `EFX-0657 Mapping into logic memory block ... because write and read address
//        port is not compatible for dual-ported ram`，把整块 RAM 映射成 LUT/触发器
//       —— 后果是 19200×8 的 RAM 变成十几万个触发器，综合直接爆炸
//       （efx_map 报 "Clock Network 'clk' with 153909 loads"，一步跑几百秒不结束）。
//     - 读口不做条件判断（无条件寄存读），需要时上层忽略数据即可。
//     - **绝对不要**用 for 循环给 mem 赋初值（同样会退化成触发器）。
//       要清零就通过写口逐拍写。
//
//  用途：MLX90640 原始帧缓存、帧差法背景帧等。
//==========================================================================
`timescale 1ns / 1ps

module mmt_dpram #(
    parameter DW    = 16,
    parameter AW    = 10,
    parameter DEPTH = 0            // 0 = 用满 2^AW；否则用指定深度（省 BRAM）
)(
    input  wire             clk,
    // 写口
    input  wire             we,
    input  wire [AW-1:0]    waddr,
    input  wire [DW-1:0]    wdata,
    // 读口
    input  wire [AW-1:0]    raddr,
    output reg  [DW-1:0]    rdata
);

    localparam integer MEM_DEPTH = (DEPTH == 0) ? (1 << AW) : DEPTH;

    reg [DW-1:0] mem [0:MEM_DEPTH-1];

    // 写口（独立 always 块 —— 这是能推断 BRAM 的关键）
    always @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
    end

    // 读口（独立 always 块，无条件寄存读）
    always @(posedge clk) begin
        rdata <= mem[raddr];
    end

endmodule
