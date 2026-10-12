/*==========================================================================
 *  ddr_app.c  —  阶段 2：**跑在 DDR** 里的应用（演示/自检用）
 *--------------------------------------------------------------------------
 *  链接：sw\ddr\link_ddr.ld（ORIGIN = 0x00001000）→ 它的每一条指令、每一个变量
 *        都在 DDR 里，这就是"固件放 DDR 运行"。
 *
 *  它上板要证明三件事（每一件都打印出来，UART 上直接看得见）：
 *    1) 我确实在 DDR 里执行：打印 main / 一个函数的地址，应该在 0x00001xxx，
 *       而不是 0xF9000xxx（片内 RAM）。
 *    2) 模型权重确实被搬进了 DDR：打印 mmt_weights_base 的头 8 个字。
 *    3) 整条链路没搬错：自己从 flash 重读镜像头，对 DDR 里的 app+权重再算一遍
 *       CRC32，和头里的值比对（loader 已经验过一次，这里是从"被搬运方"的角度再验）。
 *
 *  ⚠️ 说明：这是**演示/自检**用的应用。真正的业务固件是 sw\main.c，
 *     将来把 sw\main.c 换进来即可（它只用 uart.c，本脚本的构建方式不变）。
 *     本文件之所以单独写一份，是因为 sw\main.c 属于别人的写权限，不能改；
 *     而且把"证明自己在 DDR"的代码和业务代码混在一起会互相干扰。
 *==========================================================================*/

#include "mmt_ddr.h"
#include "spi_flash.h"
#include "uart.h"

/* link_ddr.ld 用 PROVIDE 导出的地址符号（不要在这里写死地址！）*/
extern const unsigned char mmt_weights_base[];
extern const unsigned char mmt_weights_limit[];
extern const unsigned char mmt_tensor_base[];
extern const unsigned char mmt_tensor_limit[];

#ifndef MMT_APP_FLASH_VERIFY
#define MMT_APP_FLASH_VERIFY 1
#endif

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

/* 一个普通函数，用来打印"代码段在哪"*/
static u32 where_am_i(void)
{
    return (u32)(void *)&where_am_i;
}

int main(void)
{
    uart_init();
    uart_puts("\r\n");
    uart_puts("================================================\r\n");
    uart_puts(" MMT stage-2 app  (running from DDR)\r\n");
    uart_puts("================================================\r\n");

    /* ---- 1. 自证在 DDR ---- */
    uart_puts("[1] execution address check\r\n");
    uart_puts("    &main        = "); put_hex32((u32)(void *)&main);           uart_puts("\r\n");
    uart_puts("    &where_am_i  = "); put_hex32(where_am_i());                  uart_puts("\r\n");
    uart_puts("    (expect 0x00001000..0x000FFFFF = DDR app window; 0xF9000xxx would mean we are still in on-chip RAM)\r\n");

    /* ---- 2. 权重区在不在 ---- */
    uart_puts("[2] weights region\r\n");
    uart_puts("    mmt_weights_base  = "); put_hex32((u32)mmt_weights_base); uart_puts("\r\n");
    uart_puts("    mmt_weights_limit = "); put_hex32((u32)mmt_weights_limit); uart_puts("\r\n");
    uart_puts("    first 8 words at weights base:\r\n");
    {
        int i;
        for (i = 0; i < 8; i++) {
            uart_puts("      [+"); put_dec((u32)(i * 4)); uart_puts("] ");
            put_hex32(((volatile u32 *)mmt_weights_base)[i]);
            uart_puts("\r\n");
        }
    }
    uart_puts("    tensor region      = "); put_hex32((u32)mmt_tensor_base);
    uart_puts(" .. "); put_hex32((u32)mmt_tensor_limit - 1u); uart_puts("\r\n");

    /* ---- 3. 自己重读 flash 头 + 复核 CRC（证明搬运没错）---- */
#if MMT_APP_FLASH_VERIFY
    {
        mmt_img_hdr_t h;
        uart_puts("[3] re-verify against the image header in SPI flash\r\n");
        spi_flash_init();
        if (!spi_flash_wake() || !spi_flash_exit4b()) {
            uart_puts("    !! SPI init failed (is the SoC SPI wired to the flash pins?)\r\n");
        } else if (!spi_flash_read(MMT_FLASH_IMG_BASE, (u8 *)&h, MMT_IMG_HDR_SIZE)) {
            uart_puts("    !! cannot read header from flash\r\n");
        } else if (h.magic != MMT_IMG_MAGIC) {
            uart_puts("    !! header magic wrong: "); put_hex32(h.magic); uart_puts("\r\n");
        } else {
            u32 crc = 0xFFFFFFFFu;
            u32 done = 0;
            uart_puts("    header OK. app_len = "); put_dec(h.app_len);
            uart_puts(", w_len = "); put_dec(h.w_len); uart_puts("\r\n");
            if (h.app_flash_off == 0u) {
                crc = mmt_crc32_update(crc, (const u8 *)h.app_ddr_addr, h.app_len);
                done = h.app_len;
            }
            if (h.w_len != 0u && done == h.w_flash_off) {
                crc = mmt_crc32_update(crc, (const u8 *)h.w_ddr_addr, h.w_len);
                done += h.w_len;
            }
            crc ^= 0xFFFFFFFFu;
            uart_puts("    expect crc = "); put_hex32(h.payload_crc); uart_puts("\r\n");
            uart_puts("    actual crc = "); put_hex32(crc);           uart_puts("\r\n");
            if (done == h.payload_len && crc == h.payload_crc) {
                uart_puts("    ==> CRC32 MATCH: loader copied app+weights correctly\r\n");
            } else {
                uart_puts("    ==> !! CRC32 MISMATCH (payload_len="); put_dec(done);
                uart_puts(") -- 搬运/缓存/flash 读有问题\r\n");
            }
        }
    }
#else
    uart_puts("[3] flash re-verify disabled at compile time\r\n");
#endif

    /* ---- 4. DDR 读写的回环测试（在张量区里做，不碰 app/权重）---- */
    uart_puts("[4] DDR write/read test @ tensor base\r\n");
    {
        volatile u32 *p = (volatile u32 *)mmt_tensor_base;
        u32 pat = 0xC0DE1234u;
        unsigned k;
        int ok = 1;
        for (k = 0; k < 64u; k++) {
            p[k] = pat + k;
        }
        __asm__ volatile (".word(0x500F)" ::: "memory");   /* 失效 D-cache 再回读 */
        for (k = 0; k < 64u; k++) {
            if (p[k] != pat + k) { ok = 0; break; }
        }
        uart_puts("    64 words: "); uart_puts(ok ? "OK" : "FAILED"); uart_puts("\r\n");
    }

    uart_puts("[5] entering main loop (heartbeat every ~1s)\r\n");

    for (;;) {
        volatile u32 spin;
        for (spin = 0; spin < 8000000u; spin++) { }
        uart_puts(".");
    }
}
