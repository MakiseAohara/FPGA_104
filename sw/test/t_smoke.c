/*==========================================================================
 *  t_smoke.c -- 最小 RV32 自检程序，用来验证 rv32sim.py 本身
 *--------------------------------------------------------------------------
 *  不依赖任何库（-nostdlib）：直接往 MMIO 写字符。
 *  MMIO 约定见 rv32sim.py 的 install_console()：
 *      0xF0000000 写字节 -> 控制台
 *      0xF0000004 写字   -> 退出，值为退出码
 *==========================================================================*/
typedef unsigned int   u32;
typedef unsigned char  u8;

#define MMIO_PUTC  ((volatile u8  *)0xF0000000u)
#define MMIO_EXIT  ((volatile u32 *)0xF0000004u)

static void putc_(char c) { *MMIO_PUTC = (u8)c; }
static void puts_(const char *s) { while (*s) putc_(*s++); }

static void putu(u32 v)
{
    char buf[12];
    int  i = 0;
    if (v == 0) { putc_('0'); return; }
    while (v) { buf[i++] = (char)('0' + (v % 10u)); v /= 10u; }
    while (i) putc_(buf[--i]);
}

/* 顺便验一下乘除法（M 扩展）和移位，模拟器这几条最容易写错 */
static u32 xorshift(u32 x) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; return x; }

void _start(void)
{
    u32 acc = 12345u;
    int i;
    signed int s;

    puts_("rv32sim smoke test\n");

    /* 纯算术 */
    if (7 * 6 != 42)        { puts_("FAIL mul\n");  *MMIO_EXIT = 1; for(;;); }
    if (100 / 7 != 14)      { puts_("FAIL div\n");  *MMIO_EXIT = 2; for(;;); }
    if (100 % 7 != 2)       { puts_("FAIL rem\n");  *MMIO_EXIT = 3; for(;;); }
    s = -100;
    if (s / 7 != -14)       { puts_("FAIL sdiv\n"); *MMIO_EXIT = 4; for(;;); }
    if (s % 7 != -2)        { puts_("FAIL srem\n"); *MMIO_EXIT = 5; for(;;); }
    if ((1u << 31) >> 31 != 1) { puts_("FAIL srl\n"); *MMIO_EXIT = 6; for(;;); }

    /* 循环 + 移位链，结果写死成期望值 */
    for (i = 0; i < 1000; i++) acc = xorshift(acc);
    puts_("xorshift(12345) x1000 = ");
    putu(acc);
    putc_('\n');
    if (acc != 0x72C39BE8u) { puts_("FAIL xorshift value\n"); *MMIO_EXIT = 7; for(;;); }

    puts_("OK\n");
    *MMIO_EXIT = 0;
    for (;;) { }
}
