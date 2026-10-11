/*==========================================================================
 *  link_ddr.ld  —  mmt RISC-V 固件「跑在 DDR 里」的链接脚本【草案 v1】
 *--------------------------------------------------------------------------
 *  ⚠️ 这是**草案**，不是替换品。现有 sw\link.ld（链接到片内 RAM 0xF9000000）
 *     保持不动，两条路并存：
 *       sw\link.ld       → 固件固化进片内 RAM（现状，仿真/上板都在用）
 *       sw\ddr\link_ddr.ld → 固件由 bootloader 从 flash 搬进 DDR 0x1000 后运行
 *
 *  ---------------------------------------------------------------------------
 *  地址是从哪里来的（每一条都有文件:行，别改之前先读一遍）
 *  ---------------------------------------------------------------------------
 *  1) DDR 给 CPU 的基址 = 0x00001000，大小 = 0xE0000000（3.5GB 窗口）
 *       ip\sapphire_soc\sapphire_soc.v:11628
 *         logic_hitsS0_2 = ((32'h00001000 <= addr) && (addr < 32'he0001000));
 *       该从口是唯一接到 DDR 的：
 *         :3634-3668  system_bridge_bmb_decoder.io_outputs_2
 *         :3671-3708  → system_bridge_bmb_upSizer（BMB→128bit）
 *         :3690       → system_ddr_bmb_slaveModel_arbiterGen_oneToOne_arbiter
 *       官方同款 SoC 的 BSP 头文件把同一个值写成了宏：
 *         07_官方demo工程\_ddr_demo_ti60\embedded_sw\soc\bsp\efinix\
 *             EfxSapphireSoc\include\soc.h:68   #define SYSTEM_DDR_BMB 0x1000
 *                                          :69   ~_SIZE        0xe0000000
 *       ⇒ **基址是 0x1000，不是 0**。0x00000000–0x00000FFF 是解码空洞，
 *         落进去会走 no-hit 分支（sapphire_soc.v:11673 / 11677 / 11693），
 *         拿到的是一笔错误响应。所以任何东西都不许放到 0x0。
 *
 *  2) 应用区上限 = 1 MB（0x1000 … 0x100000）
 *       - 官方 TinyML 参考设计 LDSize=16380(16MB)，其 ip\SapphireSoc\settings.json:16-17
 *         显式指定了 16MB 的 bootloader；我们用同样的 DDR 启动方式，
 *         但**板载 flash 只有 8 MB（GD25LQ64）**，见
 *         参考资料\_zip_extract\TI60F225I3-V4 DEMO板软硬件设计说明-260813-1.pdf.txt:124
 *         而 bootloader 固定从 flash 0x00380000 开始搬
 *         （readme.txt:84「Software Bitstream for spi flash programming at Address 0x380000」），
 *         所以「app + 权重」总共只有  0x800000 - 0x380000 = 0x480000 = 4.5 MB 可放。
 *       - 本脚本把 app 限死在 1 MB（1020K），剩下的 3.5 MB 留给模型权重
 *         （权重基址 0x00100000，见下面的 mmt_weights_base）。
 *         这个 1MB / 3.5MB 的切分**可以改**，改的时候必须同时改 sw\ddr\pack_image.ps1
 *         的 -AppRegion 参数，并且 app+weights ≤ 4.5 MB。
 *
 *  3) 为什么 .bss/.stack 能直接放 DDR
 *       bootloader 先把整个镜像（含 .data 初值）拷进 DDR 才跳过来，所以 .data
 *       不需要再做 ROM→RAM 拷贝；startup.S 只需要清 .bss、设 sp（现状即如此，
 *       sw\startup.S:23/26/27 用的 _stack_top/_bss_start/_bss_end 本脚本全部提供）。
 *
 *  ---------------------------------------------------------------------------
 *  链接完怎么自查（三条，缺一不可）
 *  ---------------------------------------------------------------------------
 *    a) 链接器必须没有 "region APP overflowed" 报错，且下面两条 ASSERT 都过；
 *    b) riscv-none-elf-nm -n mmt_ddr.elf | Select-String "_start|_stack_top|_end"
 *       ⇒ 三个符号都必须落在 0x00001000 … 0x00100000 之间；
 *    c) riscv-none-elf-objdump -h mmt_ddr.elf
 *       ⇒ 所有 PROGBITS/NOBITS 段的 VMA 都 ≥ 0x00001000 且 < 0x00100000，
 *         没有任何一段落在 0x0（那里是解码空洞）。
 *==========================================================================*/

OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
    /* 名字/地址/长度必须与 docs\DDR固件与模型放置方案.md 的内存图一致 */
    APP (rwx) : ORIGIN = 0x00001000, LENGTH = 1020K   /* 0x00001000 … 0x000FFFFF */
}

/* 固件要用的 DDR 绝对地址：写成符号，C 代码直接 extern 引用，
 * 免得地址散落在各处的 #define 里（一改就漏）。 */
PROVIDE(mmt_fb_base       = 0x02000000);   /* 视频帧缓存 3 bank 起始（rtl\mmt\mmt_top.v:661）*/
PROVIDE(mmt_fb_end        = 0x02BDDDFF);   /* 实测用到这里（协作日志.md:1927）*/
PROVIDE(mmt_weights_base  = 0x00100000);   /* TinyML 模型权重区起始 = app 区之后 */
PROVIDE(mmt_weights_limit = 0x00480000);   /* 权重区上限（不含）：4.5MB 预算的末尾 */
PROVIDE(mmt_tensor_base   = 0x03000000);   /* 张量/激活区起始 */
PROVIDE(mmt_tensor_limit  = 0x04000000);   /* 张量/激活区上限（不含）*/

/* 栈：DDR 里不必再抠 1KB。8KB 足够裸机主循环 + UART 打印，
 * 但如果以后开中断嵌套/递归，先算一遍再放大。 */
_stack_size = 8K;

SECTIONS
{
    .text : ALIGN(4) {
        KEEP(*(.text.start))      /* 复位/bootloader 跳过来就是 0x1000，必须最前 */
        *(.text .text.*)
    } > APP

    .rodata : ALIGN(4) {
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
        *(.rdata)
    } > APP

    .data : ALIGN(4) {
        _data_start = .;
        *(.data .data.*)
        *(.sdata .sdata.*)
        *(.gnu.linkonce.d.*)
        _data_end = .;
    } > APP

    .bss : ALIGN(4) {
        _bss_start = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        . = ALIGN(4);
        _bss_end = .;
    } > APP

    .stack (NOLOAD) : ALIGN(16) {
        _stack_bottom = .;
        . += _stack_size;
        _stack_top = .;
    } > APP

    _end = .;

    /* ---- 硬性守卫：任何一条不过就说明这份链接脚本的假设被破坏了 ---- */
    ASSERT(_start >= 0x00001000,
           "mmt: _start 落在 DDR 解码空洞 (0x0-0xFFF)，bootloader 跳到 0x1000 必挂")
    ASSERT(_bss_end <= 0x00100000,
           "mmt: 固件越过了 1MB app 区上界 0x00100000，会和模型权重区重叠")
    ASSERT(_stack_top <= 0x00100000,
           "mmt: 栈顶越过了 1MB app 区上界 0x00100000")
    ASSERT(_end <= 0x00100000,
           "mmt: 固件总大小超过 1MB，请缩小固件或同步修改内存图/打包脚本")
}
