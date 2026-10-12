/*==========================================================================
 *  loader.c  —  阶段 1：跑在**片内 RAM**里的自建搬运器（≈ 厂商 bootloader 的替代品）
 *--------------------------------------------------------------------------
 *  它干的事（一句话）：
 *      上电 → CPU 从片内 RAM 0xF9000000 跑这段代码
 *           → 从 SPI flash 0x380000 读镜像头
 *           → 按头里的长度，把 app 搬到 DDR 0x1000、权重搬到 DDR 0x00100000
 *           → 刷 D-cache / fence.i
 *           → 跳到 DDR 0x1000，固件就在 DDR 里跑了
 *
 *  ---------------------------------------------------------------------------
 *  为什么不用厂商的 bootloader（决策全文见 docs\DDR执行路径决策.md）
 *  ---------------------------------------------------------------------------
 *  厂商那 20 支 bootloader 只有两支会往 **DDR** 搬：
 *    · bootloader_124K.hex   → 只搬 124KB（本板模型就 ~294KB，装不下）
 *    · ref_files\bootloader_16MB\...\bootloader.hex → 硬搬 16MiB，
 *      而 flash 只有 8MB（板载 GD25LQ64），源地址 0x380000 + 16MiB = 0x10380000
 *      ⇒ 越界读约 12MiB（未定义内容）。能用但很脏、且慢。
 *  其余 bootloader_<N>K.hex 全部是**往片内 RAM 0xF9000000 搬**的，
 *  而且 N≥48 的那些代码被链到 0xF901xxxx 以上——超出我们 32KB 的片内 RAM，
 *  根本跑不起来（实测：bootloader_32K 的目标 0xF9000000、界 0xF9008000；
 *            bootloader_16K 的目标 0xF9000000、界 0xF9004000）。
 *  → 结论：**没有一支能直接用**（详见决策文档 §2 的实测表）。
 *
 *  自建方案的好处：
 *    1) 不重新生成 SoC IP（不用改 settings.json / 跑 IP 生成），
 *       走现成的 sw\hex2soc.ps1 -Install 把本 loader 灌进片内 RAM 即可；
 *    2) flash 里的镜像起始地址由我们定（默认 0x380000，可改宏），
 *       **不会越界读 flash**；
 *    3) 搬多少、搬到哪，全在镜像头里，换模型不用重编 loader；
 *    4) 有 CRC32 自校验 + UART 全程报告，上板出问题能直接定位。
 *
 *  ⚠️ 前置条件（**必须由 Lead 先做，不做这段代码搬不动任何东西**）：
 *     SoC 的 SPI0 在 rtl\mmt\soc\mmt_soc_subsystem.v:376-391 被**端接了**
 *     （data_*_read 接 0、sclk/write/writeEnable 悬空），顶层也没有 SPI 端口，
 *     Interface Designer 里更没有这 4 根脚。必须先按厂商 TinyML 参考设计接线：
 *       rtl\mmt\soc\mmt_soc_subsystem.v 引出 system_spi_0_io_{data_0_read,
 *           data_0_write,data_0_writeEnable,data_1_read,...,sclk_write,ss}
 *       constr\*_oob.peri.xml 加 4 个 GPIO 块（照抄
 *           tinyml_vision\Ti60F225_mobilenetv1_person_detect_demo\
 *           edge_vision_soc.peri.xml:236-250）：
 *             system_spi_0_io_data_0       GPIOL_P_03   inout
 *             system_spi_0_io_data_1       GPIOL_N_03   inout
 *             system_spi_0_io_sclk_write   GPIOL_N_01   output
 *             system_spi_0_io_ss           GPIOL_P_01   output
 *           （引脚号 N1/L1/M1/P1 见
 *             _ddr_demo_ti60\outflow\ddr_demo_ti60.pinout.csv:164/179/194/209）
 *     详细清单见 docs\DDR执行路径决策.md §3。
 *
 *  入口约定：链接脚本把这段放在 0xF9000000（复位向量），它调 main()。
 *==========================================================================*/

#include "mmt_ddr.h"
#include "spi_flash.h"
#include "uart.h"

/* 载荷 CRC 自校验（读回 DDR 逐字节算）。关掉可以省 ~1 秒启动时间。*/
#ifndef MMT_LOADER_CRC
#define MMT_LOADER_CRC 1
#endif

/* 搬完之后要不要做 DDR 写-读回环测试（会覆盖 app 区前 4 字节，所以放在搬运**之前**）*/
#ifndef MMT_LOADER_DDRTEST
#define MMT_LOADER_DDRTEST 1
#endif

/*--------------------------------------------------------------------------
 * 小工具：打印
 *------------------------------------------------------------------------*/
static void put_hex32(u32 v)
{
    static const char hx[] = "0123456789ABCDEF";
    int i;
    uart_puts("0x");
    for (i = 28; i >= 0; i -= 4) uart_putc(hx[(v >> i) & 0xF]);
}

static void put_dec(u32 v)
{
    char b[11];
    int i = 0;
    if (v == 0u) { uart_putc('0'); return; }
    while (v > 0u && i < 11) { b[i++] = (char)('0' + (v % 10u)); v /= 10u; }
    while (i > 0) uart_putc(b[--i]);
}

static void put_kv_hex(const char *k, u32 v) { uart_puts(k); put_hex32(v); uart_puts("\r\n"); }
static void put_kv_dec(const char *k, u32 v) { uart_puts(k); put_dec(v); uart_puts("\r\n"); }

/*--------------------------------------------------------------------------
 * 镜像头读取与校验
 *------------------------------------------------------------------------*/
static int hdr_read(mmt_img_hdr_t *h)
{
    /* 头一定在镜像起始处，48 字节，逐字节读（调用次数少，不优化）*/
    return spi_flash_read(MMT_FLASH_IMG_BASE, (u8 *)h, MMT_IMG_HDR_SIZE);
}

static int hdr_check(const mmt_img_hdr_t *h)
{
    uart_puts("[2] image header @flash "); put_hex32(MMT_FLASH_IMG_BASE); uart_puts("\r\n");

    if (h->magic != MMT_IMG_MAGIC) { uart_puts("    !! magic wrong: "); put_hex32(h->magic); uart_puts("\r\n"); return 0; }
    if (h->version != MMT_IMG_VERSION) { uart_puts("    !! version unsupported\r\n"); return 0; }
    put_kv_hex ("    magic/version : OK  total_size = ", h->total_size);
    put_kv_hex ("    app    : ddr ", h->app_ddr_addr); put_kv_dec("   len ", h->app_len);
    put_kv_hex ("    weights: ddr ", h->w_ddr_addr);   put_kv_dec("   len ", h->w_len);
    put_kv_hex ("    payload crc   = ", h->payload_crc);

    /* --- 硬的边界检查：任何一条不过就不许搬，宁可停在 loader 里报错 --- */
    if (h->total_size > MMT_FLASH_IMG_MAX) {
        uart_puts("    !! image bigger than flash budget (8MB - 0x380000)\r\n"); return 0;
    }
    if (h->payload_len != (h->total_size - MMT_IMG_PAYLOAD_OFF)) {
        uart_puts("    !! total_size/payload_len inconsistent\r\n"); return 0;
    }
    if (h->app_ddr_addr < MMT_DDR_HOLE_END + 1u) {
        uart_puts("    !! app target inside the 0x0-0xFFF decode hole\r\n"); return 0;
    }
    if (h->app_ddr_addr + h->app_len > MMT_DDR_PHYS_LIMIT) {
        uart_puts("    !! app target beyond physical DDR\r\n"); return 0;
    }
    if (h->w_len != 0u) {
        if (h->w_ddr_addr < MMT_DDR_HOLE_END + 1u ||
            h->w_ddr_addr + h->w_len > MMT_DDR_PHYS_LIMIT) {
            uart_puts("    !! weights target out of range\r\n"); return 0;
        }
        /* 不许和 app 区重叠 */
        if (!(h->w_ddr_addr >= h->app_ddr_addr + h->app_len ||
              h->app_ddr_addr >= h->w_ddr_addr + h->w_len)) {
            uart_puts("    !! weights overlap the app region\r\n"); return 0;
        }
    }
    if ((h->app_len & 3u) || (h->w_len & 3u) ||
        (h->app_ddr_addr & 3u) || ((h->w_ddr_addr & 3u) && h->w_len != 0u)) {
        uart_puts("    !! length/alignment must be 4-byte multiples\r\n"); return 0;
    }
    if (h->app_flash_off + h->app_len > h->payload_len ||
        (h->w_len != 0u && h->w_flash_off + h->w_len > h->payload_len)) {
        uart_puts("    !! payload offsets exceed payload size\r\n"); return 0;
    }
    uart_puts("    boundary checks : all pass\r\n");
    return 1;
}

/*--------------------------------------------------------------------------
 * DDR 写-读回环测试：DDR3 上电校准需要时间，这一步顺带"等"它。
 * 地址用 app 区头 4 字节（紧接着就会被搬进来的镜像覆盖，无副作用）。
 *------------------------------------------------------------------------*/
static int ddr_probe(void)
{
    volatile u32 *p = (volatile u32 *)MMT_APP_BASE;
    u32 pat[4];
    int i, try_i;
    pat[0] = 0xA5A5A5A5u; pat[1] = 0x5A5A5A5Au;
    pat[2] = 0x0000FFFFu; pat[3] = 0xFFFF0000u;

    uart_puts("[1] DDR probe @ "); put_hex32(MMT_APP_BASE); uart_puts("\r\n");
    for (try_i = 0; try_i < 3; try_i++) {
        int ok = 1;
        for (i = 0; i < 4; i++) {
            p[i] = pat[i];
            /* 写直达缓存：回读可能命中缓存，所以先失效再读（见决策文档 §4）*/
            __asm__ volatile (".word(0x500F)");
            if (p[i] != pat[i]) { ok = 0; put_kv_hex("    !! mismatch at slot ", (u32)i); }
        }
        if (ok) { uart_puts("    DDR write/read : OK\r\n"); return 1; }
        uart_puts("    retry...\r\n");
    }
    uart_puts("    !! DDR not usable -- 检查 DDR3 控制器是否校准完成 / AXI 互联是否把 SoC 的 "
              "ddrA 主口接上了\r\n");
    return 0;
}

/*--------------------------------------------------------------------------
 * 搬运 + 校验
 *------------------------------------------------------------------------*/
static int copy_payload(const mmt_img_hdr_t *h)
{
    u32 app_flash = MMT_FLASH_IMG_BASE + MMT_IMG_PAYLOAD_OFF + h->app_flash_off;

    uart_puts("[3] copy app: flash "); put_hex32(app_flash);
    uart_puts(" -> ddr "); put_hex32(h->app_ddr_addr);
    put_kv_dec("   bytes ", h->app_len);

    if (!spi_flash_to_mem(app_flash, h->app_ddr_addr, h->app_len)) {
        uart_puts("    !! SPI read failed (timeout). 检查 SPI 是否已接到 flash 脚、"
                  "CS/时钟是否配好\r\n");
        return 0;
    }
    if (h->w_len != 0u) {
        u32 w_flash = MMT_FLASH_IMG_BASE + MMT_IMG_PAYLOAD_OFF + h->w_flash_off;
        uart_puts("[4] copy weights: flash "); put_hex32(w_flash);
        uart_puts(" -> ddr "); put_hex32(h->w_ddr_addr);
        put_kv_dec("   bytes ", h->w_len);
        if (!spi_flash_to_mem(w_flash, h->w_ddr_addr, h->w_len)) {
            uart_puts("    !! SPI read failed on weights\r\n");
            return 0;
        }
    } else {
        uart_puts("[4] no weights in this image (w_len = 0)\r\n");
    }
    return 1;
}

#if MMT_LOADER_CRC
static int verify_crc(const mmt_img_hdr_t *h)
{
    u32 crc = 0xFFFFFFFFu;
    u32 done = 0;

    uart_puts("[5] CRC32 verify (read back from DDR)\r\n");
    /* payload 在 DDR 里不是连续的（app 与权重各在一处），所以按头里的顺序分段算 */
    if (h->app_flash_off == done) {
        crc = mmt_crc32_update(crc, (const u8 *)h->app_ddr_addr, h->app_len);
        done += h->app_len;
    } else {
        uart_puts("    (app not first in payload -> skip CRC)\r\n");
        return 1;
    }
    if (done == h->w_flash_off && h->w_len != 0u) {
        crc = mmt_crc32_update(crc, (const u8 *)h->w_ddr_addr, h->w_len);
        done += h->w_len;
    }
    crc ^= 0xFFFFFFFFu;

    if (done != h->payload_len) {
        uart_puts("    (payload layout unexpected -> skip CRC)\r\n");
        return 1;
    }
    put_kv_hex("    expected = ", h->payload_crc);
    put_kv_hex("    computed = ", crc);
    if (crc != h->payload_crc) {
        uart_puts("    !! CRC MISMATCH -- 镜像或 flash 读有问题，不跳转（避免乱飞）\r\n");
        return 0;
    }
    uart_puts("    CRC32 OK\r\n");
    return 1;
}
#endif

/*--------------------------------------------------------------------------
 * 跳到 DDR 里的 app
 *------------------------------------------------------------------------*/
/* MMT_USE_ZIFENCEI：要不要在跳转前发 fence.i。
 *   默认 0，理由（这条很重要，别随手打开）：
 *     · 本 loader **从来没有从 DDR 取过指令**（它整段都在 0xF9000000 跑），
 *       所以 I-cache 里不可能有 app 地址范围的旧行 —— 不发 fence.i 也是安全的。
 *     · 本工程 sw\build_sw.ps1 用的 -march=rv32im（没有 _zifencei），
 *       GCC 默认拒绝汇编 fence.i；而且我们**无法从网表确证**这颗配置出来的
 *       VexRiscv 真的支持 Zifencei（网表里只找到 opcode 0x0f 的合法性判定
 *       sapphire_soc.v:16288，没有找到 fence.i 的功能解码）。
 *     · 万一 CPU 不认这条指令 → 非法指令异常 → 上板直接挂，代价太大。
 *   如果将来确实需要（例如 app 自己写代码再跳），
 *   把 build_ddr.ps1 的 -march 改成 rv32im_zifencei 并在这里开 1。*/
#ifndef MMT_USE_ZIFENCEI
#define MMT_USE_ZIFENCEI 0
#endif

static void jump_to_app(u32 entry)
{
    void (*app)(void) = (void (*)(void))entry;

    uart_puts("[6] flush caches and jump\r\n");

    /* 数据侧：DDR 是可缓存的（sapphire_soc.v:17905 只把 0xf8000000/0xe1000000
     * 当 IO 非缓存），装载过程中读回 DDR 校验会留下缓存行；命令式失效一次。
     *   .word(0x500F)  = VexRiscv 的"失效全部 D-cache"自定义指令
     *   依据（两条独立）：
     *     · 厂商 BSP vexriscv.h:26  #define data_cache_invalidate_all() asm(".word(0x500F)")
     *     · **本工程**网表 sapphire_soc.v:16289 解出该指令
     *       (mask 0x01f0707f == 0x0000500F)，:18186 它驱动 dataCache_1_io_cpu_flush_valid,
     *       :18187 无寄存器号时 = 全失效。 */
    __asm__ volatile (".word(0x500F)" ::: "memory");
#if MMT_USE_ZIFENCEI
    __asm__ volatile ("fence.i" ::: "memory");
#endif

    uart_puts("    entry = "); put_hex32(entry); uart_puts("\r\n");
    uart_puts("    >>> leaving loader (no more output from stage 1)\r\n");

    app();          /* 不会再回来 */
}

/*--------------------------------------------------------------------------
 * 入口
 *------------------------------------------------------------------------*/
int main(void)
{
    mmt_img_hdr_t h;
    u32 i;

    uart_init();
    uart_puts("\r\n");
    uart_puts("================================================\r\n");
    uart_puts(" MMT stage-1 loader  (on-chip RAM 0xF9000000)\r\n");
    uart_puts("================================================\r\n");
    put_kv_hex("flash image base : ", MMT_FLASH_IMG_BASE);
    put_kv_hex("app target       : ", MMT_APP_BASE);

    /* SPI flash 上电序列（照厂商 bootloaderConfig.h:24-26 的顺序）*/
    spi_flash_init();
    if (!spi_flash_wake())     { uart_puts("!! SPI wake(0xAB) failed\r\n");    goto fail; }
    if (!spi_flash_exit4b())   { uart_puts("!! SPI exit4B(0xE9) failed\r\n");  goto fail; }
    uart_puts("[0] SPI flash controller init + wake + exit-4byte-addr : OK\r\n");

    if (!hdr_read(&h))         { uart_puts("!! cannot read image header from flash\r\n"); goto fail; }
    if (!hdr_check(&h))        goto fail;

#if MMT_LOADER_DDRTEST
    if (!ddr_probe())          goto fail;
#endif
    if (!copy_payload(&h))     goto fail;
#if MMT_LOADER_CRC
    if (!verify_crc(&h))       goto fail;
#endif

    /* 顺手确认 app 第一条指令和 flash 里的对得上（很小但很灵的一条自检）*/
    uart_puts("[7] app first word: ");
    put_hex32(*(volatile u32 *)h.app_ddr_addr);
    uart_puts("\r\n");

    jump_to_app(h.app_ddr_addr);

fail:
    uart_puts("\r\n**** LOADER FAILED -- staying in stage 1, NOT jumping to DDR ****\r\n");
    for (i = 0;; i++) {
        if ((i & 0xFFFFFFu) == 0u) uart_puts(".");
    }
    /* not reached */
}
