/*==========================================================================
 *  mmt_regs.h  —  FPGA 硬件寄存器映射（软核侧视角）
 *--------------------------------------------------------------------------
 *  与 RTL 的 rtl\mmt\soc\mmt_soc_regs.v 严格一一对应。
 *  改动任何一边都必须同步改另一边 —— 这是软硬件接口，最容易出错的地方。
 *
 *  ★★ 基址 = 0xF8100000，**不是** 0x00100000 ★★
 *
 *  原来写的 0x00100000 来自 ip/sapphire_soc/settings.json 的
 *  APBSlave0_M_Addr=1048576。但那是 **APB 桥内部的偏移**，不是绝对地址；
 *  而且 settings.json 的地址字段本身自相矛盾（它把 UART 写在 4096，
 *  而 soc_config 和 demo 固件都用 0x10000），本来就不可信。
 *
 *  绝对地址 = APB 桥基址 + 从设备偏移。两条独立证据：
 *    1) ip/sapphire_soc/source/soc_config（生成 IP 的原始命令行）：
 *         --apbBridgeAddress 0xf8000000
 *         --uart name=system_uart_0_io,address=0x010000
 *         --i2c  name=system_i2c_0_io, address=0x016000
 *         --apbSlave name=io_apbSlave_0, address=0x100000, size=65536
 *    2) 反汇编板卡包里 demo 固件，它真的在用这些地址：
 *         LUI 立即数 0xF8010000 (=UART) 、0xF8016000 (=I2C)
 *       与 0xf8000000 + 0x10000 / 0x16000 逐位吻合。
 *
 *  所以我们的寄存器块 = 0xF8000000 + 0x100000 = **0xF8100000**
 *  （窗口大小 65536 = 64 KB，我们只用到最低的 0x00~0x68）
 *==========================================================================*/
#ifndef MMT_REGS_H
#define MMT_REGS_H

#include <stdint.h>

#define MMT_BASE            0xF8100000u

/* ---- 只读：身份 ---- */
#define MMT_ID              (MMT_BASE + 0x00)   /* 固定 0x4D4D5401 */

/* ---- 只读：SHT30 温湿度 ---- */
#define MMT_SHT30_A         (MMT_BASE + 0x04)   /* [31:16]=温度×100(有符号) [15:0]=湿度×100 */
#define MMT_SHT30_B         (MMT_BASE + 0x08)   /* [31:16]=温度原始 [15:0]=湿度原始 */
#define MMT_SHT30_ST        (MMT_BASE + 0x0C)   /* bit0=data_valid(读清) bit1=crc_err bit2=bus_err */

/* ---- 只读：MLX90640 ---- */
#define MMT_IR_ST           (MMT_BASE + 0x10)   /* [31:16]=帧计数 bit0=frame_valid(读清) bit1=bus_err */
#define MMT_IR_TA           (MMT_BASE + 0x14)   /* [15:0]=ta_raw (Ptat) */

/* ---- 只读：帧差法 ---- */
#define MMT_MOTION_AREA     (MMT_BASE + 0x18)   /* Σmask */
#define MMT_MOTION_SUMX     (MMT_BASE + 0x1C)   /* Σx·mask */
#define MMT_MOTION_SUMY     (MMT_BASE + 0x20)   /* Σy·mask */
#define MMT_MOTION_ST       (MMT_BASE + 0x24)   /* bit0=motion_flag bit1=frame_done(读清) */

/* ---- 只读：融合 ---- */
#define MMT_FUSION_SCORE    (MMT_BASE + 0x28)   /* [31:24]=视觉 [23:16]=温度 [15:8]=环境 [8:0]=得分 */
#define MMT_ALARM_ST        (MMT_BASE + 0x2C)   /* bit0=alarm(读清) bit1=in_auth_window [4:2]=事件类型 */

/* ---- 可写：配置 ---- */
#define MMT_CFG_DIFF        (MMT_BASE + 0x30)   /* [15:8]=帧差阈值 */
#define MMT_CFG_MINAREA     (MMT_BASE + 0x34)   /* [15:0]=最小面积 */
#define MMT_CFG_FUSION      (MMT_BASE + 0x38)   /* [15:8]=得分阈值(Q8) [4:0]=授权结束小时 */
#define MMT_CFG_AUTH        (MMT_BASE + 0x3C)   /* [4:0]=授权开始小时 [12:8]=当前小时 */
#define MMT_VISION          (MMT_BASE + 0x40)   /* [7:0]=视觉概率 [8]=有效 */
#define MMT_BODY_TEMP       (MMT_BASE + 0x44)   /* [15:0]=最高体温×10(有符号) [16]=有效 */
#define MMT_CTRL            (MMT_BASE + 0x48)   /* bit0=帧差使能 bit1=冻结背景 bit2=清背景 bit3=静音 */
#define MMT_IR_FRAME_RD     (MMT_BASE + 0x4C)   /* [15:0]=红外帧 RAM 在 MMT_IR_FRAME_ADDR 的数据 */
#define MMT_IR_FRAME_ADDR   (MMT_BASE + 0x50)   /* [9:0]=要读的红外帧地址 0..831 */
#define MMT_AMBIENT         (MMT_BASE + 0x54)   /* [15:0]=环境温度×10(有符号) [16]=有效 */
#define MMT_RH_FWD          (MMT_BASE + 0x58)   /* [15:0]=转发给融合的湿度×100 */
#define MMT_OSD_TXT_ADDR    (MMT_BASE + 0x5C)   /* OSD 文字缓冲写地址 0..255 */
#define MMT_OSD_TXT_DATA    (MMT_BASE + 0x60)   /* 写这个地址即把字符写入缓冲 */
#define MMT_OSD_TH_ADDR     (MMT_BASE + 0x64)   /* OSD 热力图缓冲写地址 0..767 */
#define MMT_OSD_TH_DATA     (MMT_BASE + 0x68)   /* 写这个地址即把色阶写入缓冲 */

#define MMT_REG32(a)        (*(volatile uint32_t *)(a))
#define MMT_REG16(a)        (*(volatile uint16_t *)(a))
#define MMT_REG8(a)         (*(volatile uint8_t  *)(a))

/* ---- 兼容性检查用的魔数 ---- */
#define MMT_ID_VALUE        0x4D4D5401u

/* ---- OSD 缓冲尺寸（与 mmt_osd_overlay.v 的参数一致）---- */
#define OSD_TXT_COLS        48
#define OSD_TXT_LINES       3
#define OSD_TXT_SIZE        (OSD_TXT_COLS * OSD_TXT_LINES)   /* 144 字节 */
#define OSD_TH_W            32
#define OSD_TH_H            24
#define OSD_TH_SIZE         (OSD_TH_W * OSD_TH_H)            /* 768 字节 */

#endif /* MMT_REGS_H */
