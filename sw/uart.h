/*==========================================================================
 *  uart.h  —  Sapphire UART0 驱动接口
 *--------------------------------------------------------------------------
 *  寄存器映射已从生成的 SoC 网表核实（见 uart.c 文件头），
 *  不再是"待核实"状态：
 *      基址 0xF8010000（= APB 桥 0xF8000000 + UART 偏移 0x010000）
 *      +0x00 写=发送；读=[7:0]数据 [16]有效
 *      +0x04 读=[23:16]TX 剩余空间 [31:24]RX 占用；写=[0]/[1]中断使能
 *      +0x08 写=波特率分频     +0x0C 写=帧格式     +0x10 读=错误标志
 *  默认 115200 8N1（复位 clockDivider=107，无需配置）。
 *==========================================================================*/
#ifndef MMT_UART_H
#define MMT_UART_H

void uart_init(void);
void uart_putc(char c);
void uart_puts(const char *s);
int  uart_rx_ready(void);
char uart_getc(void);
int  uart_rx_error(void);

#endif /* MMT_UART_H */
