/*=========================================================================
 *  ci_encode_test.c —— task-27 的"命令编码"自测（**不烧板**，只验证编码）
 *-------------------------------------------------------------------------
 *  为什么需要：`mmt_tinyml.h` 里的自定义指令宏在默认配置下
 *  （MMT_TINYML_PROBE_EN=0）**不会被汇编**，所以"固件编译通过"并不能说明
 *  宏写对了。这个文件把三条指令**无条件**展开，编译后反汇编逐字段核对。
 *
 *  关键设计：**用固定寄存器（a0=rd, a1=rs1, a2=rs2）**发射。
 *  因为指令只认"寄存器里的值"，用自由分配（%0/%1/%2）时反汇编看不出 rs1 的
 *  运行值；固定寄存器后，反汇编里紧挨着指令前会有一条 `li a1, <索引>`，
 *  于是"发出去的索引对不对"也能静态核对 ✓
 *
 *  期望（与厂商库 tinyml_lib.a 反汇编对照，见 docs §6）：
 *    · opcode 必须 = 0x0B（CUSTOM-0）
 *    · CFG_READ(0)  → func3=1, func7=0, 且 a1 被装 0
 *    · CFG_READ(1)  → func3=1, func7=0, 且 a1 被装 1
 *    · PARAM(2,3)   → func3=3, func7=2
 *  厂商原始证据：`tinyml_accel_get_uuid()` = `.insn 4, 0x00a5150b`
 *                （opcode=0x0B, func3=1, func7=0, rd=a0, rs1=a0, rs2=a0）
 *
 *  运行：powershell -File D:\FPGA\mmt\sw\test\run_ci_encode_test.ps1
 *=========================================================================*/
#include "mmt_tinyml.h"

volatile unsigned long g_ci0;
volatile unsigned long g_ci1;
volatile unsigned long g_ci2;

/* 固定寄存器版本：a0=rd、a1=rs1、a2=rs2（只为可静态核对，生产宏仍用 MMT_CI_R）*/
#define CI_FIXED(func3, func7, rs1_val, rs2_val, out)                     \
    do {                                                                  \
        register unsigned long __rd asm("a0");                            \
        register unsigned long __r1 asm("a1") = (unsigned long)(rs1_val); \
        register unsigned long __r2 asm("a2") = (unsigned long)(rs2_val); \
        asm volatile(".insn r 0x0B, " #func3 ", " #func7 ", a0, a1, a2"   \
                     : "=r"(__rd) : "r"(__r1), "r"(__r2));                \
        (out) = __rd;                                                     \
    } while (0)

__attribute__((noinline)) void ci_case_cfg0(void) { CI_FIXED(1, 0, 0, 0, g_ci0); }
__attribute__((noinline)) void ci_case_cfg1(void) { CI_FIXED(1, 0, 1, 0, g_ci1); }
__attribute__((noinline)) void ci_case_param(void)
{
    /* 参数 bank：f7=2、f3=3（厂商 conv.o 里出现过 f7=2/f3=0..7 这一族）*/
    CI_FIXED(3, 2, 0x11223344UL, 0x55667788UL, g_ci2);
}

/* 顺带验证生产宏（MMT_CI_R，自由寄存器分配）也能编出来 */
__attribute__((noinline)) unsigned long ci_case_prod(void)
{
    return MMT_CI_CFG_READ(0);
}

int main(void)
{
    ci_case_cfg0();
    ci_case_cfg1();
    ci_case_param();
    g_ci0 += ci_case_prod();
    return (int)(g_ci0 + g_ci1 + g_ci2);
}
