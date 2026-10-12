/*==========================================================================
 *  link_loader.ld  —  阶段 1 搬运器（loader.c）的链接脚本
 *--------------------------------------------------------------------------
 *  目标：**片内 RAM 0xF9000000 / 32KB**（不是 DDR！）
 *
 *  地址依据（全部实测）：
 *    ip\sapphire_soc\source\soc_config:31   --onChipRamAddress 0xf9000000
 *    ip\sapphire_soc\source\soc_config:26   --onChipRamSize    0x8000   (32KB)
 *    ip\sapphire_soc\sapphire_soc.v:14084   IBusCachedPlugin_fetchPc_pcReg <= 32'hf9000000
 *                                           （复位向量 = 这里，所以 .text.start 必须最前）
 *    ip\sapphire_soc\sapphire_soc.v:8315 同族解码行：片内 RAM 窗口
 *    sw\hex2soc.ps1 会把 mmt_fw.bin/loader.bin 按 4 个 ram_symbol 文件灌进这 32KB，
 *    所以 .data 初值不需要 startup.S 自己搬（RAM 初值就是镜像本身）。
 *
 *  为什么 loader 必须留够栈：它在搬 4.5MB 期间要调 spi/uart 函数，栈深很浅，
 *  但**不能**把栈放到 DDR（这时 DDR 还没验证过，而且 loader 的整个意义就是
 *  "在 DDR 可用之前把东西搬进去"）。4KB 栈 + ~6KB 代码余量充足。
 *==========================================================================*/

OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
    /* 名字/地址/长度来自 soc_config:26,31（详见文件头）*/
    OCRAM (rwx) : ORIGIN = 0xF9000000, LENGTH = 32K
}

_stack_size = 4K;      /* 32KB 里扣 4KB 栈；改大前先算 代码+bss+栈 ≤ 32K */

SECTIONS
{
    .text : ALIGN(4) {
        KEEP(*(.text.start))     /* startup.S：复位后 CPU 就从 0xF9000000 取指 */
        *(.text .text.*)
    } > OCRAM

    .rodata : ALIGN(4) {
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
        *(.rdata)
    } > OCRAM

    .data : ALIGN(4) {
        _data_start = .;
        *(.data .data.*)
        *(.sdata .sdata.*)
        *(.gnu.linkonce.d.*)
        _data_end = .;
    } > OCRAM

    .bss : ALIGN(4) {
        _bss_start = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        . = ALIGN(4);
        _bss_end = .;
    } > OCRAM

    .stack (NOLOAD) : ALIGN(16) {
        _stack_bottom = .;
        . += _stack_size;
        _stack_top = .;
    } > OCRAM

    _end = .;

    /* ---- 硬性守卫 ---- */
    ASSERT(_start == 0xF9000000,
           "loader: _start 必须是 0xF9000000（SoC 复位向量），否则上电跑的不是这段代码")
    ASSERT(_end <= 0xF9008000,
           "loader: 超过片内 RAM 32KB（0xF9000000+0x8000），hex2soc 会拒绝、上板会飞")
    ASSERT(_stack_top <= 0xF9008000,
           "loader: 栈顶越过片内 RAM 末尾")
}
