/*==========================================================================
 *  t_alu.c -- RV32M 逐条自检（给 rv32sim.py 用）
 *--------------------------------------------------------------------------
 *  ★ 为什么非要单独写这个：
 *    第一版 t_smoke.c 里的 "100 % 7 == 2" 这类检查是**空测试** ——
 *    操作数全是常量，编译器直接常量折叠成结果，**模拟器的 M 扩展
 *    根本没被执行**。于是模拟器里一个真实的 REM 符号 bug 被"全部通过"
 *    掩盖了，直到 printf 风格的取位循环打出九个 0x00 才暴露。
 *
 *    所以这里：
 *      - 操作数来自 const 数组，通过指针读入（编译器不能折叠）
 *      - 期望值由 Python 独立算出后生成到 _alu_vectors.inc
 *      - 每项逐条比对，任何一项不符就报出序号并退出
 *==========================================================================*/
typedef unsigned int  u32;
typedef signed   int  s32;
typedef unsigned char u8;

#define MMIO_PUTC  ((volatile u8  *)0xF0000000u)
#define MMIO_EXIT  ((volatile u32 *)0xF0000004u)

static void putc_(char c) { *MMIO_PUTC = (u8)c; }
static void puts_(const char *s) { while (*s) putc_(*s++); }

static void puthex(u32 v)
{
    int i;
    for (i = 28; i >= 0; i -= 4) {
        u32 d = (v >> i) & 0xFu;
        putc_(d < 10u ? (char)('0' + d) : (char)('a' + (d - 10u)));
    }
}

/* 期望值由 Python 独立计算生成（见生成脚本），每组 18 项：
 *   { a, b, add, sub, and, or, xor, sll, srl, sra, slt, sltu, mul, mulh, div, divu, rem, remu }
 *
 * ★ 为什么必须包含寄存器-寄存器运算：
 *   模拟器第一版把 OP f3=0 写反了（funct7=0 应是 ADD，写成了 a-b；funct7=0x20
 *   应是 SUB，写成了常数 0xFFFFFFFF）。这个错误躲过了最初两版测试，因为
 *   GCC 绝大多数地址运算用的是 `addi`，**`add a,b,c` 出现得比想象中少得多**。
 *   真正的症状要到 printf 风格的取位循环里才炸（指针算成 a0-a5）。
 * ★ 同样地，第一版 t_smoke.c 里的 "100 % 7 == 2" 是**空测试**：常量被编译器
 *   常量折叠，模拟器的 M 扩展根本没执行。所以这里操作数一律走 const 数组。 */
static const u32 vec[][18] = {
#include "_alu_vectors.inc"
};

#define NVEC ((int)(sizeof(vec)/sizeof(vec[0])))

#define CHK(tag, idx, got, want)                                  \
    do {                                                          \
        u32 _g = (got), _w = (want);                              \
        if (_g != _w) {                                           \
            puts_("  " tag " #"); puthex((u32)(idx));             \
            puts_(" got "); puthex(_g);                           \
            puts_(" want "); puthex(_w); putc_('\n');             \
            bad++;                                                \
        }                                                         \
    } while (0)

void _start(void)
{
    int i, bad = 0;

    puts_("RV32IM ALU self-check\n");

    for (i = 0; i < NVEC; i++) {
        u32 a = vec[i][0], b = vec[i][1];

        /* 基础整数指令 */
        CHK("add ", i, a + b,                      vec[i][2]);
        CHK("sub ", i, a - b,                      vec[i][3]);
        CHK("and ", i, a & b,                      vec[i][4]);
        CHK("or  ", i, a | b,                      vec[i][5]);
        CHK("xor ", i, a ^ b,                      vec[i][6]);
        CHK("sll ", i, a << (b & 31u),             vec[i][7]);
        CHK("srl ", i, a >> (b & 31u),             vec[i][8]);
        CHK("sra ", i, (u32)((s32)a >> (b & 31u)), vec[i][9]);
        CHK("slt ", i, (u32)((s32)a < (s32)b),     vec[i][10]);
        CHK("sltu", i, (u32)(a < b),               vec[i][11]);

        /* M 扩展 */
        CHK("mul ", i, a * b,                      vec[i][12]);
        CHK("mulh", i, (u32)(((unsigned long long)(s32)a *
                              (unsigned long long)(s32)b) >> 32), vec[i][13]);
        CHK("div ", i, (u32)((s32)a / (s32)b),     vec[i][14]);
        CHK("divu", i, a / b,                      vec[i][15]);
        CHK("rem ", i, (u32)((s32)a % (s32)b),     vec[i][16]);
        CHK("remu", i, a % b,                      vec[i][17]);
    }

    if (bad == 0) {
        puts_("all ");
        putc_((char)('0' + NVEC / 10));
        putc_((char)('0' + NVEC % 10));
        puts_(" groups x 16 ops PASS\n");
        puts_("OK\n");
        *MMIO_EXIT = 0;
    } else {
        puts_("FAIL\n");
        *MMIO_EXIT = 1;
    }
    for (;;) { }
}
