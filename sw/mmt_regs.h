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

/* ---- 只读：上板判据（2026-10-12 新增，见 docs\上板判据-写通路握手计数.md）----
 * 为什么加这四个：原来只能靠"屏幕上画面动不动"猜帧缓冲写通路活没活；
 * 现在串口直接读计数与视觉字节，三个场景一眼可辨。
 * ⚠️ 这四个寄存器要**重新编译位流**才会有数（旧位流读回全 0，不是错）。 */
#define MMT_FB_AW_CNT       (MMT_BASE + 0x6C)   /* [31:0]=写地址通道(fb_awvalid&fb_awready)握手累计数 */
#define MMT_FB_W_CNT        (MMT_BASE + 0x70)   /* [31:0]=写数据通道(fb_wvalid &fb_wready )握手累计数 */
#define MMT_FB_WR_STAT      (MMT_BASE + 0x74)   /* bit0=awvalid bit1=awready bit2=wvalid bit3=wready
                                                 * bit4=aw_seen  bit5=w_seen（"曾经握手过"的粘滞位）*/
#define MMT_VISION_WORD     (MMT_BASE + 0x78)   /* [31:24]=conf_vision(完整 8 位) [23:16]=conf_temp
                                                 * [15:8]=conf_env  [7:0]=0
                                                 * ★ 0x28 的 [31:24] **不能**用来读视觉：
                                                 *   RTL 里的拼接是 46 位被截断，只有 bit31 是
                                                 *   conf_vision[0]。详见判据文档 §3。*/
#define MMT_FRAME_TGL_CNT   (MMT_BASE + 0x7C)   /* [31:0]=视频帧翻转次数（motion_frame_tgl 跳变数）
                                                 * ★ 这个寄存器**不需要额外接线**，重编位流即可用；
                                                 *   串口上它在涨 ⇒ 视频通路在出帧。*/

/* ---- 只读：最大写地址判据（2026-10-13 新增，task-22；判据见 docs\上板判据-最大写地址.md）----
 * 用途：验证"帧步长修复（960 vs 1920）"是否真的进了位流 —— 握手计数只说明"在写"，
 *       不说明"写到哪里"。
 * ⚠️ 两个寄存器**必须联合读**：amax=0 且采样=0 是"没出图"，**不是**"没越界"。
 *    需要重新编译位流（并且要 Lead 把 fb_awaddr 引进 SoC）才有数。 */
/* ★ 2026-10-13 地址修正（task-24 复查查出）：原 0xA8/0xAC 正好插在探针的线性窗口
 *   （0x80..0xBC）里，会把探针 raddr 10/11 挡死。现移到空闲的 **0xD8/0xDC**
 *   （RTL 侧 mmt_soc_regs.v 已同步修改）。 */
#define MMT_FB_AWADDR_MAX   (MMT_BASE + 0xD8)   /* [31:0]=历史最大 fb_awaddr（AW 握手那拍取样，单调不减）*/
#define MMT_FB_AW_STAT      (MMT_BASE + 0xDC)   /* [15:0]=采样次数(饱和) [16]=至少采样过一次
                                                 * [17]=曾采到非 0 地址 */

/* ---- 只读：摄像头上游探针（2026-10-13 新增，task-19；判据见 docs\上板判据-摄像头上游探针.md）----
 * 用途：定位"像素卡在哪一段" —— I2C 没跑 / MIPI 时钟没来 / CSI RX 没解出像素。
 * ⚠️ 这批寄存器要**重新编译位流**（并且要 Lead 应用接线补丁）才有数；
 *    旧位流下读回 0，不是错。 */
#define MMT_CAM_SCL_CNT     (MMT_BASE + 0x80)   /* cam_scl 跳变数 —— I2C 配置活动。
                                                 * ★ 探针接的是 **io_cam_scl_OE**（= ~scl_padoen_o），
                                                 *   不是 scl_o（OpenCores 里 scl_o 恒 0）；
                                                 *   每个 SCL 周期算 2 次跳变。 */
#define MMT_CAM_CK_CNT      (MMT_BASE + 0x84)   /* MIPI 字节时钟探针计数（×1024 = 周期数）*/
#define MMT_CAM_PCLK_CNT    (MMT_BASE + 0x88)   /* MIPI 像素时钟探针计数（×1024 = 周期数）*/
#define MMT_CSI_DE_CNT      (MMT_BASE + 0x8C)   /* ★ w_mipi_rx_de 跳变数 = CSI RX 在吐像素 */
#define MMT_CSI_HS_CNT      (MMT_BASE + 0x90)   /* w_mipi_rx_hs 跳变数 */
#define MMT_CSI_VS_CNT      (MMT_BASE + 0x94)   /* w_mipi_rx_vs 跳变数（≈ 帧数×2）*/
#define MMT_CAM_PROBE_ST    (MMT_BASE + 0x98)   /* [0]scl [1]ck_tg [2]pclk_tg [3]de [4]hs [5]vs 电平
                                                 * [6]scl_seen [7]de_seen [8]hs_seen [9]vs_seen
                                                 * [10]ck_seen [11]pclk_seen [12]wc_seen */
#define MMT_CSI_LINK_ST     (MMT_BASE + 0x9C)   /* [3:0]=pixel_per_clk [7:4]=fifo_rd_empty [8]=irq
                                                 * [10:9]=vc [16:11]=datatype */
#define MMT_CSI_WC_CNT      (MMT_BASE + 0xA0)   /* word_count **值变化次数**（★ 不是包数！
                                                 * 同帧内各行包 word_count 相同 ⇒ 稳态 wc(d=0) 正常。
                                                 * 要看包/行动没动用 0x90/0x94）*/
#define MMT_CSI_WC_NOW      (MMT_BASE + 0xA4)   /* [15:0]=word_count 当前快照 */
/* ---- task-24 加固（判读坑见 docs\上板判据-摄像头上游探针.md）----
 * ★ 2026-10-13 地址修正（task-24 复查查出）：下面 6 个宏原先写成 0xB0..0xC4，
 *   那是**错的** —— RTL 译码是线性连续的（raddr = PADDR[7:2] − 32），
 *   且 FB_AWADDR_MAX/FB_AW_STAT 曾插在 0xA8/0xAC 把 raddr 10/11 挡死。
 *   现已把 fb 两个寄存器移到 0xD8/0xDC、探针上界收到 0xBC（raddr 0..15）
 *   ⇒ 下面这 6 个宏就是**真实地址**，字段名与寄存器一一对应。
 *   （修复前的错误对应关系见 docs\上板判据-摄像头上游探针.md §7） */
#define MMT_PROBE_ID        (MMT_BASE + 0xA8)   /* ★ 位流魔数 = 0x4D4D5450（"MMTP"）
                                                 *   读到它才证明这版位流里有探针；
                                                 *   读不到 ⇒ 位流没重编（与"计数全 0"区分开）*/
#define MMT_CSI_PD_CNT      (MMT_BASE + 0xAC)   /* [31:0]="de && pixel_data!=0" 拍数（÷1024）
                                                 *   数据有效性：DE 在跳 ≠ 数据有效 */
#define MMT_CSI_WC_MAX      (MMT_BASE + 0xB0)   /* [15:0] 历史最大 word_count（包最大词数）*/
#define MMT_I2C_ACK_CNT     (MMT_BASE + 0xB4)   /* [31:0] I2C **ACK 次数**（从器件拉低 SDA）
                                                 *   ★ 只看 SCL 数分不出"传感器响应了没有" */
#define MMT_I2C_NACK_CNT    (MMT_BASE + 0xB8)   /* [31:0] I2C NACK 次数（没人应答）*/
#define MMT_RST_HS_STAT     (MMT_BASE + 0xBC)   /* [0]=core rstn(1=三个 PLL 都锁定) [1]=像素域 rstn
                                                 * [2]=ck_HS_ENA 电平 [6:3]=d0..d3_HS_ENA 电平
                                                 * [7]=ck 曾拉起 [11:8]=d0..d3 曾拉起
                                                 * ★ 自检：core=1 且 像素=0 逻辑上不可能 ⇒ 像素时钟没跑 */

/* ---- ★ task-23 / M0：测试图案注入 + 视频时序计数（0xC8..0xD4）----
 *   ⚠️ 0x80..0xBC 是摄像头上游探针 mmt_cam_probe 的窗口（连续 16 个，raddr 0..15；
 *      见 mmt_soc_regs.v 的 probe_sel: probe_word 32..47），**绝对不能占用**；
 *      0xC0/0xC4 也不映射（越界保护，读到 0）。本组寄存器从 0xC8 起。
 *      0xD8/0xDC 是 MMT_FB_AWADDR_MAX / MMT_FB_AW_STAT（见上）。
 *   复位默认全 0 ⇒ 默认走摄像头，现有行为不变。
 */
#define MMT_TEST_PATTERN    (MMT_BASE + 0xC8)   /* W/R [0]=en  [2:1]=mode
                                                 *   en=0：摄像头（复位默认）
                                                 *   en=1：切到 mmt_test_pattern
                                                 *   mode 0=8色彩条+移动方块 1=红场 2=绿场 3=蓝场 */
#define MMT_LINES_PER_FRAME (MMT_BASE + 0xCC)   /* R [15:0]=一帧内 hs 上升沿个数（1080p 应≈1080）*/
#define MMT_PIXELS_PER_LINE (MMT_BASE + 0xD0)   /* R [15:0]=一行内 de 拍数（4像素/拍、1920宽应≈480）*/
#define MMT_VID_FRAME_CNT   (MMT_BASE + 0xD4)   /* R [15:0]=上电以来 vs 个数（不涨 ⇒ 根本没出帧）*/

#define MMT_REG32(a)        (*(volatile uint32_t *)(a))
#define MMT_REG16(a)        (*(volatile uint16_t *)(a))
#define MMT_REG8(a)         (*(volatile uint8_t  *)(a))

/* 开/关测试图案：en=1 打开；关掉用 MMT_TEST_PATTERN_SET(0,0) */
#define MMT_TEST_PATTERN_SET(en, mode) \
    (MMT_REG32(MMT_TEST_PATTERN) = (((en) ? 1u : 0u) | (((uint32_t)((mode) & 3u)) << 1)))

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
