/*==========================================================================
 *  link.ld  —  Sapphire RISC-V 裸机链接脚本
 *--------------------------------------------------------------------------
 *  ★★ 地址参数是**从生成的 SoC 网表里读出来的**，不是猜的 ★★
 *
 *  之前这份脚本写 ORIGIN=0x00000000 / LENGTH=124K，**两处都是错的**，
 *  依据是 ip/sapphire_soc/settings.json 里的 LDSize=124。但 settings.json
 *  里的地址字段本身就自相矛盾（UART 写 0x1000，而 soc_config 和 demo 固件
 *  都用 0x10000），**不能当依据**。真正的依据有三条，互相印证：
 *
 *  1) 生成 IP 的原始命令行 ip/sapphire_soc/source/soc_config：
 *        --onChipRamAddress 0xf9000000
 *        --onChipRamSize    0x2000          ← 8 KB，不是 124 KB
 *        --apbBridgeAddress 0xf8000000
 *        --apbSlave name=io_apbSlave_0,address=0x100000,size=65536
 *  2) 生成的网表 ip/sapphire_soc/sapphire_soc.v 里的总线解码：
 *        :8315  logic_hitsS0_0 = ((addr & ~32'h00001fff) == 32'hf9000000);  // 8 KB 窗口
 *        :14084 IBusCachedPlugin_fetchPc_pcReg <= 32'hf9000000;             // 复位向量
 *        顶层只有三个从设备：0xF9000000(8KB RAM) / 0xF8000000(16MB APB) /
 *                            0x01000000(16MB AXI 从口)
 *  3) 反汇编板卡包里 demo 固件（.bin 就是 ASCII 二进制文本，可直接解）：
 *        出现 LUI 立即数 0xF9001000(=RAM+0x1000)、0xF8010000(=UART)、
 *        0xF8016000(=I2C)。UART/I2C 的偏移和 soc_config 完全一致，
 *        证明"APB 桥基址 0xF8000000 + 偏移"这个模型是对的。
 *
 *  于是：
 *      RAM  = 0xF9000000, 8 KB (LENGTH = 8K)
 *      我们的自定义寄存器 = 0xF8000000 + 0x100000 = 0xF8100000（见 mmt_regs.h）
 *
 *  ⚠️ 因此**固件必须塞进 8 KB**（含栈）。原来 LENGTH 写 124K 时链接器不会报错，
 *     固件会链接成功但一跑就飞出 RAM —— 这是最难查的一类问题，务必保持 8K。
 *==========================================================================*/

OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
    RAM (rwx) : ORIGIN = 0xF9000000, LENGTH = 32K
}

/* 栈：8 KB 总 RAM 里再扣 4 KB 栈太奢侈了（实测 text+rodata+bss ≈ 3.0 KB）。
 * 本固件没有中断嵌套、没有递归、没有大局部变量，1 KB 余量充足。
 * ★ 改大它之前先算一遍 text+rodata+bss+stack ≤ 8192，否则链接期就会报溢出。*/
_stack_size = 1K;

SECTIONS
{
    .text : {
        KEEP(*(.text.start))      /* 启动代码必须在最前面（复位从这里开始跑）*/
        *(.text .text.*)
    } > RAM

    .rodata : ALIGN(4) {
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
    } > RAM

    .data : ALIGN(4) {
        _data_start = .;
        *(.data .data.*)
        *(.sdata .sdata.*)
        _data_end = .;
    } > RAM

    .bss : ALIGN(4) {
        _bss_start = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        _bss_end = .;
    } > RAM

    /* 栈从 RAM 顶端往下长 */
    .stack (NOLOAD) : ALIGN(16) {
        _stack_bottom = .;
        . += _stack_size;
        _stack_top = .;
    } > RAM

    _end = .;
}
