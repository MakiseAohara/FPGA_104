/*==========================================================================
 *  spi_flash.h  —  最小 SPI flash 读驱动（只读，够用就好）
 *--------------------------------------------------------------------------
 *  ★★ 寄存器映射是**在本工程的网表里核实过的**，不是抄参考设计猜的 ★★
 *
 *  控制器：system_spi_0_io（SoC 参数 --spi name=system_spi_0_io,address=0x014000,
 *          width=8,ssCount=1,fifoDepth=256，见 ip\sapphire_soc\source\soc_config:34）
 *  基址  ：0xF8000000 + 0x014000 = 0xF8014000
 *          （apbBridgeAddress 见 soc_config:21；厂商 bootloader 反汇编里也是 0xF8014xxx）
 *
 *  地址解码（本工程网表 ip\sapphire_soc\sapphire_soc.v 模块
 *            BmbSpiXdrMasterCtrl_... 的 case(io_ctrl_cmd_payload_fragment_address)）：
 *      :9433  12'h000  读：bit31 = 响应队列空，[7:0] = 数据（读这个地址会把数据弹出）
 *      :9437  12'h004  读：[8:0] 命令 FIFO 可用量，[24:16] 响应 FIFO 占用量
 *      :9441  12'h00C  读/写：中断使能与标志
 *      :9626  12'h008  写：CONFIG      [0]=CPOL [1]=CPHA [4]=mode
 *      :9633  12'h020  写：CLK_DIVIDER
 *      :9638  12'h024  写：SS_SETUP
 *      :9643  12'h028  写：SS_HOLD
 *      :9648  12'h02C  写：SS_DISABLE
 *      :9473  12'h050  写：WRITE_LARGE
 *      :9486  12'h054  写：READ_WRITE_LARGE
 *      :9448  12'h058  读：READ_LARGE
 *      :9497  payload_write = writeData[8]      ← 写 0x00 时 bit8 = 1 表示"发一个字节"
 *      :9498  payload_read  = writeData[9]      ← bit9 = 1 表示"要收一个字节"
 *      :9499  payload_kind  = writeData[11]     ← bit11 = 1 表示"这是片选命令"
 *      :9500  payload_data  = writeData[7:0]
 *
 *  与厂商 BSP 头文件逐条对上（同一套 IP，仅版本 3.4.0 vs 3.3.0）：
 *      _ddr_demo_ti60\embedded_sw\soc\software\standalone\driver\spi.h:29-58
 *          SPI_DATA 0x00 / SPI_BUFFER 0x04 / SPI_CONFIG 0x08 / SPI_CLK_DIVIDER 0x20
 *          SPI_SS_SETUP 0x24 / SPI_SS_HOLD 0x28 / SPI_SS_DISABLE 0x2C
 *          SPI_CMD_WRITE (1<<8) / SPI_CMD_READ (1<<9) / SPI_CMD_SS (1<<11)
 *      driver\spi.h:222-238  spi_select = 写 (slaveId|0x80|0x800)，spi_diselect = 写 (slaveId|0x800)
 *          → 片选 0 时：选中 0x880，释放 0x800。
 *            厂商 bootloader_124K.hex 反汇编里就是 0x880/0x800 这两个常量，互相印证。
 *
 *  flash 读时序（厂商 bootloader 源码 _ddr_demo_ti60\...\bootloader\src\
 *                    bootloaderConfig.h:20-33，以及 driver\spiFlash.h:496-531/710-721）：
 *      spiFlash_init(SPI,0)         → 配置 CPOL=0/CPHA=0/mode=0/div=2/setup=5/hold=2/disable=7
 *      spiFlash_wake(SPI,0)         → 0xAB 释放掉电
 *      spiFlash_exit4ByteAddr(SPI,0)→ 0xE9 退出 4 字节地址模式（GD25LQ64 是 3 字节地址）
 *      spiFlash_f2m (SPI,0,0x380000,0x1000,N) → 0x0B + 3 地址字节 + 1 dummy，逐字节读
 *
 *  ⚠️ 已知限制（不是 bug，是本实现的选择，改的时候注意）：
 *    1) 只实现单线 Fast Read(0x0B)。厂商还有 dual(0x3B)/quad(0x6B)，需要把
 *       data_1/data_2/data_3 也接成输出，本工程目前只打算接 2 根数据线。
 *    2) 所有轮询都有超时上限。SPI 没接对、flash 不在、或 SoC 时钟没跑时，
 *       函数会返回 0 而不是把 CPU 卡死 —— 这样才能用 UART 把错误报出来。
 *    3) 写 flash / 擦除**没有实现**（本方案不需要；镜像用 Efinity Programmer 烧）。
 *==========================================================================*/
#ifndef MMT_SPI_FLASH_H
#define MMT_SPI_FLASH_H

#include "mmt_ddr.h"

#define MMT_SPI_BASE        0xF8014000u

#define SPI_DATA            (MMT_SPI_BASE + 0x00u)
#define SPI_BUFFER          (MMT_SPI_BASE + 0x04u)
#define SPI_CONFIG          (MMT_SPI_BASE + 0x08u)
#define SPI_CLK_DIVIDER     (MMT_SPI_BASE + 0x20u)
#define SPI_SS_SETUP        (MMT_SPI_BASE + 0x24u)
#define SPI_SS_HOLD         (MMT_SPI_BASE + 0x28u)
#define SPI_SS_DISABLE      (MMT_SPI_BASE + 0x2Cu)

#define SPI_CMD_WRITE       (1u << 8)
#define SPI_CMD_READ        (1u << 9)
#define SPI_CMD_SS          (1u << 11)
#define SPI_CS_ASSERT_BIT   (1u << 7)

#define MMT_SPI_CS          0u        /* ssCount=1 → 片选 0 */

/* 超时：纯自旋计数。100MHz 下一次自旋 ~几 ns，0x00200000 ≈ 数十 ms 量级。
 * 只是"防止死等"，不是精确计时。*/
#define MMT_SPI_TIMEOUT     0x00200000u

static inline void mmt_wr32(u32 addr, u32 v) { *(volatile u32 *)addr = v; }
static inline u32  mmt_rd32(u32 addr)        { return *(volatile u32 *)addr; }

/*---- 底层：命令 FIFO 空间 / 响应 FIFO 占用 ----*/
static inline u32 spi_cmd_avail(void) { return mmt_rd32(SPI_BUFFER) & 0xFFFFu; }
static inline u32 spi_rsp_occ(void)   { return (mmt_rd32(SPI_BUFFER) >> 16) & 0x1FFu; }

/* 等命令 FIFO 有空位；超时返回 0 */
static inline int spi_wait_cmd(void)
{
    u32 t = MMT_SPI_TIMEOUT;
    while (spi_cmd_avail() == 0u) { if (--t == 0u) return 0; }
    return 1;
}

/* 发一个字节（bit8=1）*/
static inline int spi_tx(u8 d)
{
    if (!spi_wait_cmd()) return 0;
    mmt_wr32(SPI_DATA, (u32)d | SPI_CMD_WRITE);
    return 1;
}

/* 收一个字节（bit9=1）：先要一个字节，再等响应，最后读 0x00 把数据弹出 */
static inline int spi_rx(u8 *out)
{
    u32 t = MMT_SPI_TIMEOUT;
    if (!spi_wait_cmd()) return 0;
    mmt_wr32(SPI_DATA, SPI_CMD_READ);
    while (spi_rsp_occ() == 0u) { if (--t == 0u) return 0; }
    *out = (u8)(mmt_rd32(SPI_DATA) & 0xFFu);
    return 1;
}

/* 片选：选中 = slaveId|0x80|bit11；释放 = slaveId|bit11（见文件头 :9499 与厂商 spi.h:222-238）*/
static inline void spi_cs_assert(void) { mmt_wr32(SPI_DATA, (MMT_SPI_CS | SPI_CS_ASSERT_BIT | SPI_CMD_SS)); }
static inline void spi_cs_release(void){ mmt_wr32(SPI_DATA, (MMT_SPI_CS | SPI_CMD_SS)); }

/*---- 事务收尾：等命令 FIFO 排空再释放 CS ----
 * BmbSpiXdrMasterCtrl 是"命令 FIFO + 它自己去推 SPI 时序"，所以要保证
 * 最后一个数据字节真的移出去了，再让 CS 撤掉（厂商 BSP 里对应函数叫
 * spi_waitXferBusy，spi.h:264-281：等 availability 回到 FIFO 深度）。
 * 这里用一个**自校准**的空闲值，避免把 fifoDepth=256 写死：
 * 空闲时读一次 availability 就是深度上限。带超时，读不到就放弃（不卡死）。*/
static u32  g_spi_idle_avail = 0u;
static inline void spi_note_idle(void)
{
    u32 a = spi_cmd_avail();
    if (a > g_spi_idle_avail) g_spi_idle_avail = a;
}
static inline void spi_wait_idle(void)
{
    u32 t = MMT_SPI_TIMEOUT;
    if (g_spi_idle_avail == 0u) return;
    while (spi_cmd_avail() < g_spi_idle_avail) { if (--t == 0u) return; }
}

/* 配置（厂商 spiFlash_init_ 的同一组值，spiFlash.h:385-396）
 * SPI 时钟 = FCLK / ((clkDivider+1) * 2) = 100MHz/6 ≈ 16.7MHz
 * 想提速：div=1 → 25MHz，div=0 → 50MHz。GD25LQ64 本身支持 104MHz，
 * 但配置脚是复用脚、走线未验证，**改之前先上板试**。*/
#ifndef MMT_SPI_CLK_DIV
#define MMT_SPI_CLK_DIV     2u
#endif

static inline void spi_flash_init(void)
{
    mmt_wr32(SPI_CONFIG,     (0u << 0) | (0u << 1) | (0u << 4));  /* CPOL=0 CPHA=0 mode=0 */
    mmt_wr32(SPI_CLK_DIVIDER, MMT_SPI_CLK_DIV);
    mmt_wr32(SPI_SS_SETUP,    5u);
    mmt_wr32(SPI_SS_HOLD,     2u);
    mmt_wr32(SPI_SS_DISABLE,  7u);
    spi_wait_idle();          /* 空转一下，顺便让 self-calibrated 空闲值有意义 */
    spi_note_idle();
}

/* 0xAB 释放掉电 */
static inline int spi_flash_wake(void)
{
    spi_cs_assert();
    if (!spi_tx(0xABu)) { spi_cs_release(); return 0; }
    spi_wait_idle();
    spi_cs_release();
    return 1;
}

/* 0xE9 退出 4 字节地址模式 */
static inline int spi_flash_exit4b(void)
{
    spi_cs_assert();
    if (!spi_tx(0xE9u)) { spi_cs_release(); return 0; }
    spi_wait_idle();
    spi_cs_release();
    return 1;
}

/* 发起一次 Fast Read（0x0B）：0x0B + 24 位地址 + 1 dummy。之后可以连续 spi_rx 取数。*/
static inline int spi_flash_read_begin(u32 flash_addr)
{
    if (!spi_tx(0x0Bu))                          return 0;
    if (!spi_tx((u8)(flash_addr >> 16)))          return 0;
    if (!spi_tx((u8)(flash_addr >>  8)))          return 0;
    if (!spi_tx((u8)(flash_addr >>  0)))          return 0;
    if (!spi_tx(0x00u))                           return 0;   /* dummy */
    return 1;
}

/* 读 n 个字节到内存（逐字节）。n 小时用它（例如读 48 字节镜像头）。*/
static inline int spi_flash_read(u32 flash_addr, u8 *dst, u32 n)
{
    u32 i;
    spi_cs_assert();
    if (!spi_flash_read_begin(flash_addr)) { spi_cs_release(); return 0; }
    for (i = 0; i < n; i++) {
        if (!spi_rx(&dst[i])) { spi_cs_release(); return 0; }
    }
    spi_wait_idle();
    spi_cs_release();
    return 1;
}

/* 读 n 个字节直接写进 RAM/DDR（n 必须是 4 的倍数，dst 必须 4 字节对齐）。
 *
 * 为什么按 32 位写而不是逐字节：DDR 侧是写直达缓存（write-through、无写缓冲，
 * 见 docs\DDR执行路径决策.md §4），逐字节写会变成 4 倍的 AXI 事务数。
 * 这里每凑齐 4 个字节做一次 32 位存储。*/
static inline int spi_flash_to_mem(u32 flash_addr, u32 dst_addr, u32 n)
{
    u32 i;
    if ((n & 3u) != 0u)          return 0;      /* 调用方保证 */
    if ((dst_addr & 3u) != 0u)   return 0;
    spi_cs_assert();
    if (!spi_flash_read_begin(flash_addr)) { spi_cs_release(); return 0; }
    for (i = 0; i < n; i += 4u) {
        u8 b0, b1, b2, b3;
        if (!spi_rx(&b0)) { spi_cs_release(); return 0; }
        if (!spi_rx(&b1)) { spi_cs_release(); return 0; }
        if (!spi_rx(&b2)) { spi_cs_release(); return 0; }
        if (!spi_rx(&b3)) { spi_cs_release(); return 0; }
        *(volatile u32 *)(dst_addr + i) =
            ((u32)b0) | ((u32)b1 << 8) | ((u32)b2 << 16) | ((u32)b3 << 24);
    }
    spi_wait_idle();
    spi_cs_release();
    return 1;
}

/* CRC32（反射，多项式 0xEDB88320）—— 与 mkimage.ps1 里那份必须完全一致。
 *
 * 算法参数：poly=0xEDB88320，init=0xFFFFFFFF，refin=true，refout=true，xorout=0xFFFFFFFF
 *          （即标准 "CRC-32/ISO-HDLC"，和 zlib crc32、PNG 用的同一个）*/
static inline u32 mmt_crc32_update(u32 crc, const u8 *p, u32 n)
{
    u32 i, k;
    for (i = 0; i < n; i++) {
        crc ^= (u32)p[i];
        for (k = 0; k < 8; k++) {
            if (crc & 1u) crc = (crc >> 1) ^ 0xEDB88320u;
            else          crc = (crc >> 1);
        }
    }
    return crc;
}

static inline u32 mmt_crc32(const u8 *p, u32 n)
{
    return mmt_crc32_update(0xFFFFFFFFu, p, n) ^ 0xFFFFFFFFu;
}

#endif /* MMT_SPI_FLASH_H */
