/*==========================================================================
 *  startup.S  —  Sapphire RISC-V 裸机启动代码（最小版）
 *--------------------------------------------------------------------------
 *  复位后 CPU 从 RAM 起始处开始执行，所以这段必须被链接到最前面
 *  （link.ld 里的 KEEP(*(.text.start))）。
 *
 *  做三件事：
 *    1. 设置栈指针（栈顶在链接脚本里算出来）
 *    2. 清零 .bss（C 标准要求未初始化全局变量为 0）
 *    3. 调 main()
 *  main() 正常不会返回（主循环是 for(;;)），万一返回就死循环。
 *
 *  ⚠️ 官方 SDK 的启动代码还做了：拷贝 .data 段、初始化中断向量、
 *     设置 mtvec/mstatus 等。这些等真正上板需要中断时再补。
 *==========================================================================*/

    .section .text.start, "ax", @progbits
    .globl _start
    .type  _start, @function

_start:
    /* 1. 栈指针 */
    la      sp, _stack_top

    /* 2. 清零 .bss */
    la      t0, _bss_start
    la      t1, _bss_end
1:
    bgeu    t0, t1, 2f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       1b
2:

    /* 3. 进 C 世界 */
    call    main

    /* main 返回了就停在这里 */
3:
    j       3b

    .size _start, . - _start
