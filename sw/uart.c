/*==========================================================================
 *  uart.c  —  Sapphire UART0 驱动
 *--------------------------------------------------------------------------
 *  ★★ 本文件的寄存器映射是**从生成的 SoC 网表里读出来的**，不是猜的 ★★
 *
 *  之前这里写着"偏移待核实，按常见布局猜"，而且基址用了 settings.json 的
 *  UART0_M_Addr=4096 → 0xF8001000。**基址和偏移全是错的**。现在的依据：
 *
 *  1) APB 地址表：source/hardware/netlist/EfxSapphireSoc.v 里
 *     BmbToApb3Bridge 的解码器（约 7400 行）：
 *         hitsS0_2 = ((addr & ~24'h00003f) == 24'h010000)   ← UART，64 字节窗口
 *         hitsS0_6 = ((addr & ~24'h00ffff) == 24'h100000)   ← 我们的自定义寄存器
 *     加上顶层总线把 APB 桥放在 0xF8000000：
 *         UART   = 0xF8000000 + 0x010000 = **0xF8010000**
 *         自定义 = 0xF8000000 + 0x100000 = 0xF8100000（见 mmt_regs.h）
 *  2) 反汇编板卡包里的 demo 固件，它真的在用 0xF8010000 和 0xF8016000(I2C)。
 *  3) 寄存器语义读 BmbUartCtrl 模块（约 6405~6899 行）：
 *         +0x00 写 = 把 data[7:0] 推进 TX FIFO
 *         +0x00 读 = [7:0] 收到的字节, [16] = 收到数据有效
 *         +0x04 读 = [23:16] = TX FIFO **剩余空间**(8'h80 - 占用, FIFO 深 128)
 *                    [31:24] = RX FIFO 占用
 *                    [0]=写中断使能 [1]=读中断使能 [8]=写中断挂起 [9]=读中断挂起
 *         +0x04 写 = [0] 写中断使能, [1] 读中断使能
 *         +0x08 写 = [19:0] 波特率分频
 *         +0x0C 写 = [2:0] 数据位 [9:8] 校验 [16] 停止位
 *         +0x10 读 = [0] 读错误 [1] 接收溢出 [8] break [9] 检测到 break
 *     其中 TX 可写判据 "((*(base+4)) >> 16) & 0xFF != 0" 和 demo 固件里的
 *     辅助函数（0xF9000128 处的 lw/srli 16/andi 0xFF）**逐位吻合**，
 *     这是交叉验证，不是单一来源。
 *
 *  ★ 波特率：UartCtrl 里的分频器是"减法计数 + 到 0 重装"，
 *        tick 周期 = clockDivider + 1 个系统时钟；
 *        而 UartCtrlTx 内部还有一个 3 位计数器，每 8 个 tick 走一个数据位。
 *    复位默认 clockDivider = 20'h0006B = 107（见网表 6815 行；注意 6814 行那句
 *    20'h00000 会被紧随其后的 6815 覆盖 —— 同一分支里最后一个非阻塞赋值生效）。
 *        采样 tick = 100MHz / (107+1) = 925.9kHz
 *        波特率    = 925.9kHz / 8      = 115.7kHz  ≈ **115200**（误差 +0.47%）
 *    所以**不需要写 0x08 去配波特率**，复位默认就是 115200 8N1；
 *    demo 固件也从不配置它。uart_init() 只需使能中断（本驱动用轮询，不使能）。
 *==========================================================================*/

#include <stdint.h>
#include "uart.h"

/* ---- 板级常量（依据见文件头）---- */
#define UART0_BASE      0xF8010000u

#define UART_TXDATA     (UART0_BASE + 0x00)   /* 写: 发送字节; 读: [7:0]收到 [16]有效 */
#define UART_STAT       (UART0_BASE + 0x04)   /* 读: [23:16]=TX 剩余空间 [31:24]=RX 占用 */
#define UART_INTEN      (UART0_BASE + 0x04)   /* 写: [0]写中断 [1]读中断 */
#define UART_DIV        (UART0_BASE + 0x08)   /* 写: [19:0] 波特率分频 */
#define UART_FRAME      (UART0_BASE + 0x0C)   /* 写: [2:0]数据位 [9:8]校验 [16]停止位 */
#define UART_MISC       (UART0_BASE + 0x10)   /* 读: [0]读错 [1]溢出 [8]break [9]检出 */

#define REG32(a)        (*(volatile uint32_t *)(a))

/* 状态字里各位的掩码（见文件头第 3 条）*/
#define STAT_TX_SPACE_SHIFT   16
#define STAT_TX_SPACE_MASK    0xFFu
#define STAT_RX_OCC_SHIFT     24
#define STAT_RX_OCC_MASK      0xFFu
#define TXDATA_RX_VALID_BIT   16u     /* 读 +0x00 时的 bit16 */
#define TXDATA_RX_BYTE_MASK   0xFFu

#define MISC_RX_READY_ERROR   (1u << 0)
#define MISC_RX_OVERFLOW      (1u << 1)
#define MISC_RX_BREAK         (1u << 8)

/* TX FIFO 深度 128（8'h80 - 占用），这里只做非零判定，不用它的数值 */
static int uart_tx_can_write(void)
{
    return (((REG32(UART_STAT) >> STAT_TX_SPACE_SHIFT) & STAT_TX_SPACE_MASK) != 0u);
}

void uart_init(void)
{
    /* 波特率/帧格式都是复位默认值（115200 8N1），不需要配置。
     * 只把中断关掉——本驱动用轮询，中断留着会让挂起位一直涨。
     * 写 +0x04 的 [0]/[1] 就是中断使能位。 */
    REG32(UART_INTEN) = 0x0u;
    /* 清一下可能残留的读错误/溢出/break 标志：这几个是写清除型 */
    REG32(UART_MISC) = 0x0u;
}

void uart_putc(char c)
{
    /* ★ 等待条件是 +0x04 的 [23:16] 非 0（TX FIFO 还有空间），
     *   不是"bit0 == 1"。原来那版判据错了，上板会直接死等。*/
    while (!uart_tx_can_write()) { }
    REG32(UART_TXDATA) = (uint32_t)(uint8_t)c;
}

void uart_puts(const char *s)
{
    while (*s != '\0') uart_putc(*s++);
}

int uart_rx_ready(void)
{
    /* 读 +0x00：bit16 = 收到数据有效（读这个地址同时会把字节从 RX FIFO 弹出，
     * 所以**不能**在 ready 检查里读它——会把数据读掉）。用 RX 占用数判断。 */
    return (((REG32(UART_STAT) >> STAT_RX_OCC_SHIFT) & STAT_RX_OCC_MASK) != 0u);
}

char uart_getc(void)
{
    uint32_t v;
    while (!uart_rx_ready()) { }
    v = REG32(UART_TXDATA);              /* 读即弹出 */
    return (char)(v & TXDATA_RX_BYTE_MASK);
}

int uart_rx_error(void)
{
    return (REG32(UART_MISC) & (MISC_RX_READY_ERROR | MISC_RX_OVERFLOW)) ? 1 : 0;
}
