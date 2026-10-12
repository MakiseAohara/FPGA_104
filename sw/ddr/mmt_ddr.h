/*==========================================================================
 *  mmt_ddr.h  —  「固件 + 模型跑在 DDR 里」路线乙′ 的共享定义
 *--------------------------------------------------------------------------
 *  谁用这个头文件：
 *    · loader.c   （阶段 1：跑在片内 RAM 0xF9000000 的自建搬运器）
 *    · ddr_app.c  （阶段 2：跑在 DDR 0x1000 的应用）
 *    · mkimage.ps1（打包脚本，字段偏移必须与本文件一致）
 *
 *  ---------------------------------------------------------------------------
 *  地址全部是**实测**得到的，证据逐条列在下面（详见
 *  docs\DDR执行路径决策.md 与 docs\DDR固件与模型放置方案.md）
 *  ---------------------------------------------------------------------------
 *  DDR 给 CPU 的基址 0x00001000：
 *      ip\sapphire_soc\sapphire_soc.v:11628
 *        logic_hitsS0_2 = ((32'h00001000 <= addr) && (addr < 32'he0001000));
 *      0x0-0xFFF 是解码空洞（:11673/11677/11693 走 no-hit 错误响应）。
 *  片内 RAM 0xF9000000 / 0x8000(32KB)：
 *      ip\sapphire_soc\source\soc_config:26,31（--onChipRamSize 0x8000）
 *      ip\sapphire_soc\sapphire_soc.v:8315（8KB 掩码窗口那行同族，本工程为 0x8000）
 *  SPI 控制器基址 0xF8014000：
 *      ip\sapphire_soc\source\soc_config:21（--apbBridgeAddress 0xf8000000）
 *      ip\sapphire_soc\source\soc_config:34（--spi ... address=0x014000）
 *  帧缓存 0x02000000（硬件写）：
 *      rtl\mmt\mmt_top.v:661
 *  物理 DDR 256MB（0x0-0x0FFFFFFF）：
 *      rtl\ddr3_controller\ddr3_parameter.vh:6-15（推断，但规划必须遵守）
 *==========================================================================*/
#ifndef MMT_DDR_H
#define MMT_DDR_H

typedef unsigned char      u8;
typedef unsigned short     u16;
typedef unsigned int       u32;
typedef signed   int       s32;

/*--------------------------------------------------------------------------
 * 内存图（DDR 侧）
 *------------------------------------------------------------------------*/
#define MMT_DDR_HOLE_START   0x00000000u   /* 0x0-0xFFF 解码空洞，禁止使用 */
#define MMT_DDR_HOLE_END     0x00000FFFu

#define MMT_APP_BASE         0x00001000u   /* 阶段 1 搬完跳到这儿 */
#define MMT_APP_LIMIT        0x00100000u   /* app 区上界（不含）→ 1020KB */

#define MMT_WEIGHTS_BASE     0x00100000u   /* 模型权重区起始 */
#define MMT_WEIGHTS_LIMIT    0x00480000u   /* 权重区上界（不含）= 4.5MB 预算末尾 */

#define MMT_TENSOR_BASE      0x03000000u   /* TinyML 张量/激活区（8 字节对齐）*/
#define MMT_TENSOR_LIMIT     0x04000000u

#define MMT_FB_BASE          0x02000000u   /* 视频帧缓存（frame_buffer 硬件写）*/
#define MMT_FB_END           0x02BDDDFFu

#define MMT_DDR_PHYS_LIMIT   0x10000000u   /* 物理 DDR 256MB（推断，见上）*/

/*--------------------------------------------------------------------------
 * flash 侧布局
 *--------------------------------------------------------------------------
 * 板载 SPI flash 8MB（GD25LQ64）。位流放 0x0，用户镜像放 0x380000。
 *
 *  ★ 与路线甲（厂商 bootloader）的关键差别：**镜像起始地址是我们自己定的**，
 *    因为读 flash 的代码是我们自己写的（loader.c）。所以这里 0x380000 只是
 *    "沿用厂商习惯、给位流留 3.5MB"的选择，不是硬件约束。
 *    改地址只需改这个宏 + 打包脚本的 -FlashBase，两处一致即可。
 *------------------------------------------------------------------------*/
#ifndef MMT_FLASH_IMG_BASE
#define MMT_FLASH_IMG_BASE   0x00380000u
#endif
#define MMT_FLASH_SIZE       0x00800000u   /* 8MB */
#define MMT_FLASH_IMG_MAX    (MMT_FLASH_SIZE - MMT_FLASH_IMG_BASE)  /* 4.5MB */

/*--------------------------------------------------------------------------
 * 镜像头（放在 flash 镜像的最前面，48 字节；载荷从 64 字节处开始）
 *--------------------------------------------------------------------------
 * 为什么要有头：loader 不该把"搬多少"写死。头里带着长度和落点，
 * 以后换模型/换内存图只要重新打包，**不用重新编译 loader**。
 * 字段全是小端 u32；magic 是 'M','M','T','1' → 0x31544D4D（小端读出来是 0x31544D4D）。
 *------------------------------------------------------------------------*/
#define MMT_IMG_MAGIC        0x31544D4Du   /* "MMT1"（内存里字节序 M M T 1）*/
#define MMT_IMG_VERSION      1u
#define MMT_IMG_HDR_SIZE     48u
#define MMT_IMG_PAYLOAD_OFF  64u           /* 载荷起点：64 字节对齐 */

typedef struct {
    u32 magic;          /* +0  MMT_IMG_MAGIC */
    u32 version;        /* +4  MMT_IMG_VERSION */
    u32 total_size;     /* +8  整个镜像长度（头 + 载荷），用于越界自检 */
    u32 app_flash_off;  /* +12 app 在载荷内的偏移（0 起算）*/
    u32 app_ddr_addr;   /* +16 app 搬到 DDR 哪里（应为 MMT_APP_BASE）*/
    u32 app_len;        /* +20 app 字节数（4 的倍数）*/
    u32 w_flash_off;    /* +24 权重在载荷内的偏移 */
    u32 w_ddr_addr;     /* +28 权重搬到 DDR 哪里（应为 MMT_WEIGHTS_BASE）*/
    u32 w_len;          /* +32 权重字节数（4 的倍数）*/
    u32 payload_crc;    /* +36 载荷的 CRC32（多项式 0xEDB88320，初值/末异或 0xFFFFFFFF）*/
    u32 payload_len;    /* +40 载荷字节数 */
    u32 reserved0;      /* +44 保留，写 0 */
} mmt_img_hdr_t;

/*==========================================================================*/
#endif /* MMT_DDR_H */
