//==========================================================================
//  mmt_dpram_2clk.v  —  真双口双时钟 RAM（A 口写、B 口读，两个独立时钟）
//--------------------------------------------------------------------------
//  用途：OSD 的文字缓冲与热力图缓冲。
//        写侧在系统域（core_clk，软核通过 APB 寄存器桥写），
//        读侧在视频域（hdmi_tx_slow_clk，OSD 渲染时连续读）。
//        —— 两个域不同频不同相，所以必须用**真双口双时钟** BRAM。
//
//  ★ 写法与 mmt_dpram 同样的道理（踩过坑）：
//     读写分成两个独立 always 块、读口无条件寄存读、**绝不用 for 循环赋初值**，
//     否则 BRAM 会退化成触发器，综合直接爆炸。
//
//  ⚠️ 本模块不做跨时钟域握手，因为它的用法天然安全：
//     写侧只在软核要改显示内容时偶尔写一次，读侧连续读；
//     最坏情况是某一帧读到"刚写了一半"的内容，下一帧就正确了。
//     这对显示类数据完全可接受。
//==========================================================================
`timescale 1ns / 1ps

module mmt_dpram_2clk #(
    parameter DW    = 8,
    parameter AW    = 8,
    parameter DEPTH = 0            // 0 = 用满 2^AW
)(
    // ---- A 口：写（系统域）----
    input  wire             clk_a,
    input  wire             we_a,
    input  wire [AW-1:0]    addr_a,
    input  wire [DW-1:0]    data_a,

    // ---- B 口：读（视频域）----
    input  wire             clk_b,
    input  wire [AW-1:0]    addr_b,
    output reg  [DW-1:0]    data_b
);

    localparam integer MEM_DEPTH = (DEPTH == 0) ? (1 << AW) : DEPTH;

    reg [DW-1:0] mem [0:MEM_DEPTH-1];

    always @(posedge clk_a) begin
        if (we_a) mem[addr_a] <= data_a;
    end

    always @(posedge clk_b) begin
        data_b <= mem[addr_b];
    end

endmodule
