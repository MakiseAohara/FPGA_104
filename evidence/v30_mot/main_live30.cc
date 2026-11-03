//////////////////////////////////////////////////////////////////////////////
// main_live30.cc — 固件 v30（基线：v29.2 DAY 定版 main_live292.cc）
//   v30 新增（任务「多目标跟踪 + 行为预测」）：
//     A) 多目标跟踪（IOU Tracker）：96x96 背景差分 → 膨胀 → 连通域 → IOU 贪心关联
//        稳定 ID + 每个目标的轨迹点（MMT_TRK / MMT_MOT）
//     B) 行为预测：Q4 速度向量 EMA → 2 帧前视预测位置（pred）+ 方向（dir）
//        + 到 ROI 边界的剩余帧数（eta）
//     C) 提前响应：预测"即将进入 ROI"时立刻 MMT_PREWARN，并跳出低功耗提前恢复全速推理；
//        真报警到来时输出 MMT_PREDLEAD（预警提前量 ms）
//   全部为固件改动，不动 RTL / 寄存器布局；MOT_ON=0 可整体关闭回到 v29.2 行为
////////////////////////////////////////////////////////////////////////////////
// main_live17.cc — 固件 v17（基线 main_live16.cc）
//   v17：默认 crop1_stretch；AI 阈值 p>=-86 + 4 帧 3 真投票；conf 口径修正；
//        EVT 分类与报警解除修正；%0Nx 打印 bug 修复；自动曝光/相机降帧默认关闭。
//   相机安全访问 / 自动曝光 / 相机降帧 / AI 输入预处理（基线功能）
//
// 基线：main_live15.cc（② RISC-V 历史决策 + ⑤ 低功耗；本文件保留其全部逻辑）
//
// 新增（全部默认关闭，宏值见下；默认全关时功能行为与 main_live15 一致）：
//  功能 1 相机寄存器安全访问层
//      cam_reg_read / cam_reg_write：等待 ready → 写命令 → 轮询 done（超时 10 ms）
//      写白名单：0x320e/0x320f(VTS)、0x3e00..0x3e03(曝光/模式)、0x3e08/0x3e09(增益)
//      写后读回确认，不一致回滚旧值并报错；启动时读初始值并打印 MMT_CAM
//  功能 2 自动曝光 AUTOEXP_ON（默认 0）
//      b0m(或 RAW 均值) 超出 [TARGET_LO,TARGET_HI] 时按 ±12% 先调曝光再用增益，
//      连续 2 次确认、动作后等待 3 次评估；上下限由启动读值决定；低功耗期间冻结
//  功能 3 相机降帧 LP_CAMFPS_ON（默认 0）
//      low_pwr 进入时 VTS×LP_VTS_MULT(默认 3，限 2..4)，退出恢复初始值；
//      仅当启动 VTS 在 [0x0400,0x0a00] 时启用；写失败/读回不一致 → 恢复并永久关闭
//  功能 4 AI 输入预处理（CROP_MODE / NORM_ON / STRETCH_ON，默认 0）
//      见 preprocess_core.h；行距固定 1920 B
//
// 宏开关（全部默认值 = 与 main_live15 一致的行为）：
//   CROP_MODE=0 NORM_ON=0 STRETCH_ON=0 AUTOEXP_ON=0 LP_CAMFPS_ON=0
//   FW_DECISION_ON=1 LOWPOWER_ON=1（沿用 v15 默认，不加新功能时保持原行为）
////////////////////////////////////////////////////////////////////////////////

#include <stdlib.h>
#include <stdint.h>
#include "riscv.h"
#include "soc.h"
#include "bsp.h"
#include <math.h>
#include "clint.h"
#include "print.h"
#include "intc.h"
#include "tinyml.h"
#include "ops/ops_api.h"

#include "tensorflow/lite/micro/micro_error_reporter.h"
#include "tensorflow/lite/micro/micro_interpreter.h"
#include "tensorflow/lite/micro/micro_mutable_op_resolver.h"
#include "tensorflow/lite/schema/schema_generated.h"
#include "tensorflow/lite/c/common.h"
#include "tensorflow/lite/micro/debug_log.h"
#include "tensorflow/lite/micro/micro_time.h"
#include "platform/tinyml/profiler.h"

#include "generator/v29_person_96_int8_model_data.h"
#include "model/model_settings.h"

#include "preprocess_core.h"
#include "ae_core.h"
#include "cam_ctrl_core.h"
#include "input_contract.h"
#include "mot_core.h"

// ======================= 编译期开关（默认 = 不开新功能） =======================
#ifndef CROP_MODE
#define CROP_MODE        0       /* v3.0: 1->0 整幅。原来只喂中间 1080x1080，
                                    人站两侧完全不在输入里 -> nt 恒为 0（现场实测） */
#endif
#ifndef NORM_ON
#define NORM_ON          0
#endif
#ifndef STRETCH_ON
#define STRETCH_ON       1       /* v17 默认 1%/99% 分位拉伸 */
#endif
#ifndef AUTOEXP_ON
#define AUTOEXP_ON       0       /* v29.2 本轮：旧 AE 关闭 */
#endif
#ifndef LP_CAMFPS_ON
#define LP_CAMFPS_ON     0       /* v3.3: 关闭相机降帧。
                                       低功耗进出很频繁，每次进出都写 VTS+读回（多次 I2C 事务），
                                       实测 113 次进出后 I2C 总线锁死：相机停输出（画面冻结）、
                                       红外热力图变噪点、温湿度读数全 0。
                                       低功耗仍保留"暂停推理"，只是不再动相机寄存器。 */
#endif
#ifndef HOTSRC_EXCL
#define HOTSRC_EXCL      1       /* v29.2: 热源排除——AI 连续判"无人"时，不让红外单模态直通触发报警 */
#endif
#ifndef FW_DECISION_ON
#define FW_DECISION_ON   1       /* v15 默认 */
#endif
#ifndef LOWPOWER_ON
#define LOWPOWER_ON      1       /* v15 默认 */
#endif
#ifndef INPUT_SUB128
#define INPUT_SUB128     1
#endif
#ifndef MOT_ON
#define MOT_ON           1       /* v30：多目标跟踪 + 行为预测（0=回到 v29.2 行为） */
#endif
#ifndef MOT_EXTRA_POLLS
#define MOT_EXTRA_POLLS  2      /* v1.7：每次推理后额外插 2 次采样+MOT，跟踪率 ≈ 5-6 Hz */
#endif
#ifndef MOT_EXTRA_MS
#define MOT_EXTRA_MS     120    /* 每次额外轮询之间的间隔（ms） */
#endif
#ifndef MOT_PRE_ON
#define MOT_PRE_ON       1       /* v30：预测触发的提前响应（预警 + 提前退出低功耗） */
#endif
#ifndef FUSION_AREA_MAX
#define FUSION_AREA_MAX  4000    /* v1.4 B：融合报警的面积上限（去掉整幅假运动） */
#endif
#ifndef FUSION_NEED_TRK
#define FUSION_NEED_TRK  1       /* v1.4 C：融合报警需要至少 N 条已确认 MOT 航迹 */
#endif

// 功能 2 参数
#ifndef AE_EVAL_FRAMES
#define AE_EVAL_FRAMES   8       /* 每 N 帧评估一次 */
#endif
#ifndef LP_VTS_MULT
#define LP_VTS_MULT      3       /* 降帧倍数，限制 2..4 */
#endif
#ifndef AE_DIM_ENABLE
#define AE_DIM_ENABLE    0       /* 0=下限=初始值（任务书）；1=下限=初始值/4 */
#endif
#ifndef AE_SET_MANUAL
#define AE_SET_MANUAL    0       /* 1=写 0x3e03 手动模式位（候选值，需上板确认） */
#endif

// ======================= v18 参数（A 回放结论） =======================
#define AI_P_TH          (0)
#define AI_VOTE_N        3
#define AI_VOTE_K        2
#define IR_WIN           10
#define IR_NEED          1       /* v2.9: 2->1 —— 起报延迟主项之一（红外每循环采一次，2 样本≈0.8s） */
#define IR_OFF_WIN       8      /* v2.3: 15->8 —— 红外窗口是结束缓冲最长的一段（约 11.5s -> 6s） */
#define IR_SOLO_ON       1       /* v29.1: 红外单模态直通（不要求运动候选） */
#define IR_SOLO_N        6       /* 最近 IR_SOLO_N 个样本 ir_hot 全为 1 即触发 */
#define AI_P_STRONG      60
#define AI_P_OFF         (-40)
#define AI_OFF_N         2      /* v2.3: 判"无人"只需最近 2 帧 <= AI_P_OFF（原要求整个 3 帧窗口全否） */
#define REL_QUIET_FRAMES 3      /* v2.3: 6->3 —— 结束缓冲主项之一（1.3Hz 下约 4.6s -> 2.3s） */
#define AI_AREA_MIN      200     /* 运动面积门限：压制全局亮变/AGC 型大 motion */
#define LP_AREA_MIN      800     /* v3.1：低功耗"活跃"判定的面积门（比报警门高，避免噪声把系统钉在活跃态） */
#define AI_AREA_MAX      20000
#define DEC_CAND_FRAMES  4
#define REL_IDLE_MS      3000
#define ALARM_START_FRAMES 1     /* v2.9: 2->1 —— 起报不再多等一个循环；防抖改由 ALARM_COOLDOWN_MS 兜底 */
#define ALARM_COOLDOWN_MS  3000  /* v2.6：上次解除后 N 毫秒内不起报 */
#define DEC_RELEASE_FRAMES 3     /* 连续无运动且无 AI 的解除计数（≈1.6s） */
#define DEC_WARMUP       2
#define LP_ENTER_MS      30000   /* v3.4: 10s->30s，避免"安静10秒就进、一有尖峰就出"的反复震荡 */
#define LP_EXIT_AREA_MIN 1500    /* v3.4: 退出低功耗要求的面积（远高于进入门的 800，形成迟滞） */
#define LP_POLL_MS       500

// ======================= 帧缓冲几何（v14/v15 原样） =======================
#define FB_BASE      0x01000000u
#define FB_FRAME_LEN (960u * 1080u * 4u + 0x200u)
#define LIVE_BANK    2
#define FB_ROW_BYTES 1920u

// ======================= APB map（MERGE10/11） =======================
#define APB_BASE      0xF8100000u
#define R32(n)        (*(volatile uint32_t*)(APB_BASE + 4u * (n)))

#define APB_OSD       R32(9)
#define APB_SCORE     R32(10)
#define APB_EVT       R32(11)
#define APB_ENV       R32(12)
#define APB_ST        R32(13)
#define APB_DEC       R32(14)
#define APB_CTRL      R32(15)
#define APB_I2C_CMD   R32(16)
#define APB_I2C_ST    R32(17)
#define APB_I2C_RD    R32(18)
/* MERGE16 白平衡：19/20/21 增益（Q8.8 可读写），22..26 中心区统计（只读） */
#define APB_WB_R      R32(19)
#define APB_WB_G      R32(20)
#define APB_WB_B      R32(21)
#define APB_WB_SR     R32(22)
#define APB_WB_SG     R32(23)
#define APB_WB_SB     R32(24)
#define APB_WB_PIX    R32(25)
#define APB_WB_SAT    R32(26)

/* ---- v4.1 板内 HTTP：极简协议栈 + 页面/JSON/PNG ---- */
#define HTTP_APP_IMPL
#define HTTP_APP_IMPL
#include "http_app.h"
#include "net_core.h"
#include "net_core_impl.h"

/* ---- v3.9 千兆网口（GE）：27..31 ---- */
#define GE_TXDATA     R32(27)
#define GE_TXLEN      R32(28)
#define GE_CTRL       R32(29)   /* W: bit0=GO bit1=CLR   R: bit3=rx_valid bit2=done bit1=busy bit0=arp */
#define GE_STATUS     R32(30)   /* {pkt_cnt[31:16], rx_len[15:0]} */
#define GE_RXDATA     R32(31)
#define GE_BUSY()     ((GE_CTRL >> 1) & 1u)
#define GE_ARP()      (GE_CTRL & 1u)

static const unsigned char ge_test_frame[110] = {
   0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x0A, 0x35, 0x01, 0xFE, 0xC0,
   0x08, 0x00, 0x45, 0x00, 0x00, 0x5C, 0x00, 0x00, 0x00, 0x00, 0x40, 0x11,
   0xC8, 0x19, 0xA9, 0xFE, 0x2F, 0x3E, 0xA9, 0xFE, 0x2F, 0x3D, 0x1F, 0x90,
   0x1F, 0x90, 0x00, 0x48, 0x00, 0x00, 0x4D, 0x4D, 0x54, 0x2D, 0x52, 0x41,
   0x57, 0x2D, 0x54, 0x45, 0x53, 0x54, 0x2D, 0x30, 0x31, 0x32, 0x33, 0x34,
   0x35, 0x36, 0x37, 0x38, 0x39, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x30,
   0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x61, 0x62, 0x63,
   0x64, 0x65, 0x66, 0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38,
   0x39, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x45, 0x4E, 0x44, 0x9E, 0x33,
   0xD1, 0x7E,
};

/* 只把现成的整帧推进发送器（不做任何组帧），用来分清"RTL 通道"和"C 组帧"哪个有问题 */
static int ge_send_raw(const unsigned char* f, int n)
{
   int i, k, guard = 200000;
   while (GE_BUSY() && --guard > 0) { }
   if (guard <= 0) return -2;
   GE_CTRL = 2u;
   for (i = 0; i < n; i += 4) {
      uint32_t w = 0;
      for (k = 0; k < 4; ++k) w |= (uint32_t)(i + k < n ? f[i + k] : 0) << (8 * k);
      GE_TXDATA = w;
   }
   GE_TXLEN = (uint32_t)n;
   GE_CTRL = 0u;      /* 电平触发：先清零再拉高 */
   GE_CTRL = 1u;
   return 0;
}

static unsigned short ge_ip_csum(const unsigned char* p, int n)
{
   unsigned long s = 0;
   int i;
   for (i = 0; i + 1 < n; i += 2) s += ((unsigned long)p[i] << 8) | (unsigned long)p[i + 1];
   if (n & 1) s += (unsigned long)p[n - 1] << 8;
   while (s >> 16) s = (s & 0xFFFFu) + (s >> 16);
   return (unsigned short)(~s & 0xFFFFu);
}

/* 组一整帧以太网（广播 MAC + IPv4 + UDP），把 payload 发出去。
   帧结构：14B eth + 20B ip + 8B udp + payload（4 字节对齐） */
static int ge_send(const char* s, int len)
{
   static unsigned char f[1200];
   int i, k, n, len4, guard = 200000;
   int ip_len, udp_len, lenp;
   unsigned short c;
   if (len < 0 || len > 1100) return -1;
   lenp = len;
   if (lenp < 18) lenp = 18;
   for (i = 0; i < 6; ++i) f[i] = 0xFF;
   f[6] = 0x00; f[7] = 0x0a; f[8] = 0x35; f[9] = 0x01; f[10] = 0xfe; f[11] = 0xc0;
   f[12] = 0x08; f[13] = 0x00;
   ip_len = 20 + 8 + lenp;
   f[14] = 0x45; f[15] = 0x00;
   f[16] = (unsigned char)(ip_len >> 8); f[17] = (unsigned char)ip_len;
   f[18] = 0; f[19] = 0; f[20] = 0; f[21] = 0;
   f[22] = 64; f[23] = 17;
   f[24] = 0; f[25] = 0;
   f[26] = 169; f[27] = 254; f[28] = 47; f[29] = 62;
   f[30] = 169; f[31] = 254; f[32] = 47; f[33] = 61;
   c = ge_ip_csum(f + 14, 20);
   f[24] = (unsigned char)(c >> 8); f[25] = (unsigned char)c;
   udp_len = 8 + lenp;
   f[34] = (unsigned char)(8080 >> 8); f[35] = (unsigned char)8080;
   f[36] = (unsigned char)(8080 >> 8); f[37] = (unsigned char)8080;
   f[38] = (unsigned char)(udp_len >> 8); f[39] = (unsigned char)udp_len;
   f[40] = 0; f[41] = 0;
   for (i = 0; i < len; ++i) f[42 + i] = (unsigned char)s[i];
   for (i = len; i < lenp; ++i) f[42 + i] = 0;
   n = 42 + lenp;
   {
      uint32_t crc = 0xFFFFFFFFu;
      int b, bit;
      for (b = 0; b < n; ++b) {
         crc ^= (uint32_t)f[b];
         for (bit = 0; bit < 8; ++bit)
            crc = (crc & 1u) ? ((crc >> 1) ^ 0xEDB88320u) : (crc >> 1);
      }
      crc = ~crc;
      f[n]     = (unsigned char)(crc & 0xFF);
      f[n + 1] = (unsigned char)((crc >> 8) & 0xFF);
      f[n + 2] = (unsigned char)((crc >> 16) & 0xFF);
      f[n + 3] = (unsigned char)((crc >> 24) & 0xFF);
      n += 4;
   }
   len4 = (n + 3) & ~3;
   for (i = n; i < len4; ++i) f[i] = 0;
   while (GE_BUSY() && --guard > 0) { }
   if (guard <= 0) return -2;
   GE_CTRL = 2u;
   for (i = 0; i < len4; i += 4) {
      uint32_t w = 0;
      for (k = 0; k < 4; ++k) w |= (uint32_t)f[i + k] << (8 * k);
      GE_TXDATA = w;
   }
   GE_TXLEN = (uint32_t)n;
   GE_CTRL = 0u;
   GE_CTRL = 1u;
   return 0;
}

/* ---------------- v5.0 事件上报（只用发送方向） ---------------- */
#define EV_MAGIC0   0x4Du
#define EV_MAGIC1   0x54u
#define EV_VER      1u
#define EV_T_EVENT  1u
#define EV_T_HB     2u
#define EV_T_THUMB  3u
#define EV_THUMB_CHUNK 1000
#ifndef GE_RAW_TEST_FRAME
#define GE_RAW_TEST_FRAME 0
#endif

static uint32_t g_ev_id = 0;
static unsigned char g_thumb[96 * 96];   /* 96x96 灰度，报警时编 PNG 上报 */
static unsigned char g_evpng[10000];
static int g_evpng_len = 0, g_evpng_off = 0;
static unsigned short g_evpng_seq = 0, g_evpng_total = 0;
static uint32_t g_th_eid = 0;
#define EV_LIVE_ID 0xFFFF0001u     /* 低功耗/空场时的"实时画面"帧，PC 只刷新预览，不进事件列表 */

/* 组 16 字节包头 + body，交给 ge_send 组帧（以太/IP/UDP/FCS） */
static int ge_udp_pkt(unsigned char type, uint32_t evid, unsigned short seq,
                      unsigned short total, uint32_t ms,
                      const unsigned char* body, int blen)
{
   char pkt[1120];
   int n = 0, i;
   if (blen < 0 || blen > 1100) return -1;
   pkt[n++] = (char)EV_MAGIC0; pkt[n++] = (char)EV_MAGIC1;
   pkt[n++] = (char)EV_VER;    pkt[n++] = (char)type;
   pkt[n++] = (char)(evid >> 24); pkt[n++] = (char)(evid >> 16);
   pkt[n++] = (char)(evid >> 8);  pkt[n++] = (char)evid;
   pkt[n++] = (char)(seq >> 8);   pkt[n++] = (char)seq;
   pkt[n++] = (char)(total >> 8); pkt[n++] = (char)total;
   pkt[n++] = (char)(ms >> 24); pkt[n++] = (char)(ms >> 16);
   pkt[n++] = (char)(ms >> 8);  pkt[n++] = (char)ms;
   for (i = 0; i < blen; ++i) pkt[n++] = (char)body[i];
   return ge_send(pkt, n);
}

/* 报警事件：ev=1 开始 / 2 结束；body = ev,x,y,conf,obs,nd */
static void ge_ev_alarm(int ev, int x, int y, int conf, int obs, int nd, uint32_t ms)
{
   unsigned char b[5];
   (void)nd;
   b[0] = (unsigned char)ev;                     /* 0=NORMAL 1=INTRUDE 2=TREND 3=PERSON 4=LOWPWR */
   b[1] = (unsigned char)(x & 0xFF);
   b[2] = (unsigned char)(y & 0xFF);
   b[3] = (unsigned char)(conf & 0xFF);
   b[4] = (unsigned char)(obs & 0xFF);
   (void)ge_udp_pkt(EV_T_EVENT, g_ev_id, 0, 1, ms, b, 5);
}

/* 心跳：obs,person,alarm,fps,area_lo,area_hi */
static void ge_ev_hb(int obs, int person, int alarm, int fps, int area, uint32_t ms)
{
   (void)obs; (void)person; (void)alarm; (void)fps; (void)area;
   (void)ge_udp_pkt(EV_T_HB, 0u, 0, 1, ms, (const unsigned char*)0, 0);
}

/* 报警开始时准备缩略图（不在这里发，避免阻塞） */
static void ge_thumb_prepare_id(uint32_t eid)
{
   g_th_eid = eid;
   g_evpng_len = 96 * 96;            /* 原始灰度像素，不编码 PNG（PC 端负责） */
   g_evpng_off = 0;
   g_evpng_seq  = 1;                 /* 序号从 1 开始 */
   g_evpng_total = (unsigned short)((g_evpng_len + EV_THUMB_CHUNK - 1) / EV_THUMB_CHUNK);
}
static void ge_thumb_prepare(void) { ge_thumb_prepare_id(g_ev_id); }
static int  ge_thumb_idle(void) { return (g_evpng_len <= 0) || (g_evpng_off >= g_evpng_len); }

/* 每轮最多发一片，片间自然有主循环间隔 */
static void ge_thumb_pump(uint32_t ms)
{
   int n;
   if (g_evpng_len <= 0 || g_evpng_off >= g_evpng_len) return;
   n = g_evpng_len - g_evpng_off;
   if (n > EV_THUMB_CHUNK) n = EV_THUMB_CHUNK;
   if (ge_udp_pkt(EV_T_THUMB, g_th_eid, g_evpng_seq, g_evpng_total,
                  ms, g_thumb + g_evpng_off, n) == 0) {
      g_evpng_off += n;
      g_evpng_seq++;
   } else {
      g_evpng_off = g_evpng_len;   /* 失败直接丢，不重试 */
   }
}

/* ---- v4.0 网口收包（保留但默认不用） ---- */
static unsigned char ge_rx[1600];

#define EPOCH_BASE  1793664000u   /* 烧录时刻（秒），仅用于页面显示"数据延迟" */

static net_t   g_net;
static unsigned char g_net_out[1600];
static char    g_status_json[512];
static http_state_t g_hstate;

static int ge_http_init(void)
{
   net_cfg_t cfg;
   int i;
   for (i = 0; i < 6; ++i) cfg.mac[i] = 0;
   cfg.mac[0] = 0x00; cfg.mac[1] = 0x0a; cfg.mac[2] = 0x35;
   cfg.mac[3] = 0x01; cfg.mac[4] = 0xfe; cfg.mac[5] = 0xc0;
   cfg.ip[0] = 169; cfg.ip[1] = 254; cfg.ip[2] = 47; cfg.ip[3] = 62;
   cfg.port = 80;
   {
      static net_cb_t cb;
      cb.get = http_get; cb.user = (void*)&g_hstate;
      cfg.cb = &cb;
   }
   net_init(&g_net, &cfg);
   g_hstate.status_json = g_status_json;
   g_hstate.events_json = "[]";
   g_hstate.thumb = g_thumb;
   g_hstate.thumb_w = 96; g_hstate.thumb_h = 96;
   http_set_state(&g_hstate);
   return 0;
}

/* 返回帧字节数；0 = 没有新帧。帧内容在 ge_rx[] 里（以太网原始帧，不含 FCS） */
static int ge_rx_poll(void)
{
   uint32_t st;
   int words, i, n;
   st = R32(30);
   if ((st & 0x7FFu) == 0) return 0;          /* 低 11 位=字数，非 0 表示有新帧 */
   words = (int)(st & 0x7FFu);
   if (words <= 0) return 0;
   if (words > 400) words = 400;
   R32(29) = 4u;                          /* bit2：清读指针 */
   for (i = 0; i < words; ++i) {
      uint32_t w = R32(31);
      n = i * 4;
      ge_rx[n]     = (unsigned char)(w & 0xFF);
      ge_rx[n + 1] = (unsigned char)((w >> 8) & 0xFF);
      ge_rx[n + 2] = (unsigned char)((w >> 16) & 0xFF);
      ge_rx[n + 3] = (unsigned char)((w >> 24) & 0xFF);
   }
   return words * 4;
}

static unsigned short ge_rd16(const unsigned char* p)
{
   return (unsigned short)(((unsigned)p[0] << 8) | p[1]);
}

static void ge_wr16(unsigned char* p, unsigned short v)
{
   p[0] = (unsigned char)(v >> 8); p[1] = (unsigned char)(v & 0xFF);
}

/* 收到发往 8080 的 UDP 就原样回一个 "MMT-ECHO" 包，用来验证收+发闭环 */
static void ge_rx_service(void)
{
   int n = ge_rx_poll();
   int i, pay, plen;
   if (n < 42) return;
   if (ge_rd16(ge_rx + 12) != 0x0800) return;         /* IPv4 */
   if (ge_rx[23] != 17) return;                       /* UDP */
   if (ge_rd16(ge_rx + 36) != 8080) return;           /* dst port */
   pay = n - 42;
   if (pay > 64) pay = 64;
   plen = 7 + pay;
   {
      char rsp[96];
      int k;
      for (k = 0; k < 7; ++k) rsp[k] = "MMT-ECH"[k];
      for (k = 0; k < pay; ++k) rsp[7 + k] = (char)ge_rx[42 + k];
      ge_send(rsp, plen);
   }
}


static int  ge_rx_poll(void);
static int  ge_send_raw(const unsigned char* f, int n);
static char* ge_num(char* d, unsigned v);
static char* ge_str(char* d, const char* s);

/* 板内 HTTP 服务：收帧 -> net_input -> 回包；顺便处理重传 */
static void ge_http_service(int now)
{
   int fn = ge_rx_poll();
   if (fn > 0) {
      int rn = net_input(&g_net, ge_rx, fn, g_net_out, (int)sizeof(g_net_out), (uint32_t)now);
      if (rn > 0) ge_send_raw(g_net_out, rn);
   }
   {
      int tn = net_tick(&g_net, g_net_out, (int)sizeof(g_net_out), (uint32_t)now);
      if (tn > 0) ge_send_raw(g_net_out, tn);
   }
}


/* 极简 JSON 拼装：只用到十进制整数，避开 printf 依赖 */
static char* ge_num(char* d, unsigned v)
{
   char t[12];
   int n = 0;
   if (v == 0) { *d++ = '0'; return d; }
   while (v && n < 12) { t[n++] = (char)('0' + (v % 10u)); v /= 10u; }
   while (n > 0) *d++ = t[--n];
   return d;
}

static char* ge_str(char* d, const char* s)
{
   while (*s) *d++ = *s++;
   return d;
}

/* ev: "hb" 心跳 / "as" 报警开始 / "ae" 报警结束 */
static void ge_ev(const char* ev, int ms, int px, int py, int conf, int nd, int ob, int alarm)
{
   char b[160];
   char* d = b;
   d = ge_str(d, "{\"ev\":\"");
   d = ge_str(d, ev);
   d = ge_str(d, "\",\"t\":");
   d = ge_num(d, (unsigned)ms);
   d = ge_str(d, ",\"x\":");
   d = ge_num(d, (unsigned)(px & 0xFF));
   d = ge_str(d, ",\"y\":");
   d = ge_num(d, (unsigned)(py & 0xFF));
   d = ge_str(d, ",\"c\":");
   d = ge_num(d, (unsigned)conf);
   d = ge_str(d, ",\"nd\":");
   d = ge_num(d, (unsigned)nd);
   d = ge_str(d, ",\"ob\":");
   d = ge_num(d, (unsigned)ob);
   d = ge_str(d, ",\"al\":");
   d = ge_num(d, (unsigned)alarm);
   d = ge_str(d, "}\n");
   (void)ge_send(b, (int)(d - b));
}

#define EVT_MOTION    (1u << 0)
#define EVT_IR_HOT    (1u << 1)
#define EVT_IR_VALID  (1u << 2)
#define EVT_SHT_SEEN  (1u << 3)
#define EVT_BODY_X10(w)  (((w) >> 4) & 0xFFFu)
#define EVT_AREA(w)      (((w) >> 16) & 0xFFFFu)

#define ST_SCORE(w)   ((int32_t)((w) & 0x1FFu))
#define ST_CONF(w)    ((int32_t)(((w) >> 9) & 0xFFu))
#define ST_LOWPWR(w)  (((w) >> 17) & 1u)
#define ST_ALARM(w)   (((w) >> 18) & 1u)
#define ST_FWEN(w)    (((w) >> 19) & 1u)
#define ST_AIEN(w)    (((w) >> 20) & 1u)
#define ST_VSCNT(w)   (((w) >> 24) & 0xFFu)

#define IMG_N        (96 * 96)
#define IMG_DUMP_EVERY 20   /* v30e2：全幅帧更密，便于事后核对现场 */
#define THUMB_DUMP_EVERY 1   /* v3.0: 2->1，画面延迟 ~1.5s -> ~0.7s（串口预算仍够） */
#define THUMB_W 48
#define THUMB_H 27          /* 2026-11-02：整幅 16:9 出图（原 48x48 是方阵，页面里被纵向拉伸） */

namespace {
   tflite::ErrorReporter* error_reporter = nullptr;
   const tflite::Model* model = nullptr;
   tflite::MicroInterpreter* interpreter = nullptr;
   TfLiteTensor* model_input = nullptr;
   constexpr int kTensorArenaSize = 136 * 1024;
   uint8_t tensor_arena[kTensorArenaSize];
   int8_t input_snapshot[IMG_N];
   int8_t mot_img[IMG_N];              /* v30：MOT 专用输入（不拉伸/不归一化，见 mot_sample_raw） */
}

static const char HEXD[] = "0123456789abcdef";

// ===========================================================================
// 时间 / 延时
// ===========================================================================
static uint64_t now_ms(void)
{
   return clint_getTime(BSP_CLINT) / (SYSTEM_CLINT_HZ / 1000u);
}

static void delay_ms(uint32_t ms)
{
   const uint64_t t0 = now_ms();
   while ((now_ms() - t0) < (uint64_t)ms) { }
}

// ===========================================================================
// 功能 1：相机寄存器安全访问层（APB 字 16/17/18）
// ===========================================================================
#define CAM_TIMEOUT_MS 10

static int cam_wait_ready(uint32_t timeout_ms)
{
   const uint64_t t0 = now_ms();
   do {
      const uint32_t st = APB_I2C_ST;
      if (((st & 1u) == 0u) && ((st & 4u) != 0u)) return 0;   /* !busy && ready */
   } while ((now_ms() - t0) < timeout_ms);
   return -1;
}

/* 底层读：等待 ready → 发命令(start=1,rw=1) → 轮询 done(10 ms) → 读数据 */
static int cam_raw_read(unsigned short reg, unsigned char* out)
{
   if (cam_wait_ready(200)) return -1;
   (void)APB_I2C_ST;                                  /* 清可能残留的 done */
   APB_I2C_CMD = (1u << 31) | (1u << 30) | ((uint32_t)reg << 8);
   const uint64_t t0 = now_ms();
   do {
      const uint32_t st = APB_I2C_ST;
      if (st & 2u) {                                   /* done */
         *out = (uint8_t)(APB_I2C_RD & 0xFFu);
         return 0;
      }
   } while ((now_ms() - t0) < CAM_TIMEOUT_MS);
   return -1;
}

/* 底层写：等待 ready → 发命令(start=1,rw=0,data) → 轮询 done(10 ms) */
static int cam_raw_write(unsigned short reg, unsigned char val)
{
   if (cam_wait_ready(200)) return -1;
   (void)APB_I2C_ST;
   APB_I2C_CMD = (1u << 31) | (0u << 30) | ((uint32_t)reg << 8) | (uint32_t)val;
   const uint64_t t0 = now_ms();
   do {
      const uint32_t st = APB_I2C_ST;
      if (st & 2u) return 0;
   } while ((now_ms() - t0) < CAM_TIMEOUT_MS);
   return -1;
}

/* cam_ctrl_core.h 的 I/O 回调 */
static int cam_io_rd(void* ctx, unsigned short reg, unsigned char* out)
{
   (void)ctx;
   return cam_raw_read(reg, out);
}
static int cam_io_wr(void* ctx, unsigned short reg, unsigned char val)
{
   (void)ctx;
   return cam_raw_write(reg, val);
}

static cam_io_t g_cam_io = { cam_io_rd, cam_io_wr, 0 };

/* v15 兼容的 VTS 读（保留 MMT_CAM_VTS 行，行为与 v15 相同） */
static uint32_t cam_read_vts_compat(int* ok)
{
   unsigned char hi = 0, lo = 0;
   if (cam_raw_read(CAM_REG_VTS_H, &hi) || cam_raw_read(CAM_REG_VTS_L, &lo)) {
      *ok = 0;
      return 0;
   }
   *ok = 1;
   return ((uint32_t)(hi & 0x7Fu) << 8) | (uint32_t)lo;
}

// 启动读出的相机寄存器（索引见 cam_boot_regs）
static const unsigned short cam_boot_regs[8] = {
   CAM_REG_VTS_H, CAM_REG_VTS_L,
   CAM_REG_EXP_H, CAM_REG_EXP_M, CAM_REG_EXP_L,
   CAM_REG_MODE, CAM_REG_GAIN_C, CAM_REG_GAIN_F
};
static unsigned char cam_boot_val[8];
static int  cam_boot_ok = 0;
static int  cam_exp_init = 0;      /* (0x3e01<<8)|0x3e02 */
static int  cam_gain_init = 0;     /* (0x3e08<<8)|0x3e09 */
static int  cam_mode_init = 0;

static int cam_boot_read_all(void)
{
   int k;
   for (k = 0; k < 8; ++k) cam_boot_val[k] = 0;
   for (k = 0; k < 8; ++k) {
      if (cam_raw_read(cam_boot_regs[k], &cam_boot_val[k]) != 0) return -1;
   }
   cam_exp_init  = ((int)cam_boot_val[3] << 8) | (int)cam_boot_val[4];
   cam_gain_init = ((int)cam_boot_val[6] << 8) | (int)cam_boot_val[7];
   cam_mode_init = (int)cam_boot_val[5];
   cam_boot_ok = 1;
   return 0;
}

static void cam_boot_log(void)
{
   bsp_printf("MMT_CAM 320e=%x 320f=%x 3e00=%x 3e01=%x 3e02=%x "
              "3e03=%x 3e08=%x 3e09=%x exp=0x%x gain=0x%x\n\r",
              cam_boot_val[0], cam_boot_val[1], cam_boot_val[2], cam_boot_val[3],
              cam_boot_val[4], cam_boot_val[5], cam_boot_val[6], cam_boot_val[7],
              (unsigned)cam_exp_init, (unsigned)cam_gain_init);
}

// ===========================================================================
// 功能 4：AI 输入预处理（preprocess_core.h）+ 帧缓冲取像素
// ===========================================================================
static uint32_t g_fb_base;

static unsigned char fb_get(void* ctx, int x, int y)
{
   (void)ctx;
   return *((const volatile unsigned char*)(g_fb_base + (uint32_t)y * FB_ROW_BYTES + (uint32_t)x));
}

static pp_cfg_t g_pp_cfg = { CROP_MODE, NORM_ON, STRETCH_ON };

static uint32_t sample_frame_box(int8_t* out, pp_stats_t* st)
{
   uint32_t sum = pp_run(fb_get, 0, &g_pp_cfg, out, st);

   return sum;
}

// ===========================================================================
// 功能 2：自动曝光（ae_core.h）状态与写寄存器
// ===========================================================================
#if AUTOEXP_ON
static ae_state_t g_ae;
static ae_cfg_t   g_ae_cfg = { AE_TARGET_LO, AE_TARGET_HI };
static int        g_ae_enabled = 0;
static int        g_ae_manual_done = 0;

static int ae_write_exp(int code)
{
   if (code < 0) code = 0;
   if (code > 0xFFFF) code = 0xFFFF;
   if (cam_checked_write(&g_cam_io, CAM_REG_EXP_M, (unsigned char)((code >> 8) & 0xFF), 0) != CAM_OK)
      return -1;
   if (cam_checked_write(&g_cam_io, CAM_REG_EXP_L, (unsigned char)(code & 0xFF), 0) != CAM_OK)
      return -1;
   return 0;
}

static int ae_write_gain(int code)
{
   if (code < 0) code = 0;
   if (code > 0xFFFF) code = 0xFFFF;
   if (cam_checked_write(&g_cam_io, CAM_REG_GAIN_C, (unsigned char)((code >> 8) & 0xFF), 0) != CAM_OK)
      return -1;
   if (cam_checked_write(&g_cam_io, CAM_REG_GAIN_F, (unsigned char)(code & 0xFF), 0) != CAM_OK)
      return -1;
   return 0;
}

static int ae_manual_mode(void)
{
#if AE_SET_MANUAL
   /* 候选：初始值 | 0x01；位定义需上板用 MMT_CAM 的 0x3e03 读数确认 */
   if (!g_ae_manual_done) {
      if (cam_checked_write(&g_cam_io, CAM_REG_MODE,
                            (unsigned char)((cam_mode_init | 0x01) & 0xFF), 0) != CAM_OK)
         return -1;
      g_ae_manual_done = 1;
   }
#else
   (void)g_ae_manual_done;
#endif
   return 0;
}
#endif /* AUTOEXP_ON */

// ===========================================================================
// 功能 3：相机降帧（cam_ctrl_core.h）
// ===========================================================================
static cam_lp_t g_lp;
static int      g_lp_state = 0;      /* 0=未降帧 1=降帧中 */
static int      g_lp_ready = 0;

// ===========================================================================
// v18 决策：运动触发候选 + AI 投票确认；不再使用融合 score 作为报警依据
//   - 运动（200<=area<=4000）打开 8 样本候选窗口
//   - 窗口内 AI 投票（4 帧中 >=1 帧 p>=AI_P_TH）成立 -> 报警锁定
//   - 连续 3 样本"无运动且无 AI" -> 解除（≈1.6s）；低功耗强制解除
//   - MMT_ALARM 记录起止时刻与时长
// ===========================================================================
static int ai_hist[AI_VOTE_N];
static int ai_idx = 0, ai_fill = 0;
static int last_person = 0;
static uint32_t g_frame = 0;
static uint32_t g_dec_ms = 0;
static int alarm_on = 0, alarm_start_ms = 0, alarm_frames = 0;
static int cand_left = 0, rel_cnt = 0, dec_evt = 0, dec_conf = 0;
static int quiet_cnt = 0;   /* v29.3: 当前无运动候选连续帧数（解除判定用） */
static uint64_t g_idle_since_ms = 0; /* v2.5: 空闲起点（0=非空闲）。按毫秒，避开主循环节拍影响 */
static uint64_t alarm_end_ms = 0;    /* v2.6: 上次报警解除时刻（冷却用） */
static int      alarm_cand_cnt = 0;  /* v2.6: 起报条件连续满足的循环数（去抖用） */
static int fw_lp = 0;
static uint64_t lp_last_active_ms = 0, lp_enter_ms = 0;

static int clamp_i32(int32_t v, int32_t lo, int32_t hi)
{
   if (v < lo) return lo;
   if (v > hi) return hi;
   return v;
}

static int ai_p_now = -128, g_person_off = 0;
static uint32_t g_hotsrc_cnt = 0;
static int ir_hist[IR_OFF_WIN];
static int ir_idx = 0, ir_cnt10 = 0, ir_cnt15 = 0, ir_cnt6 = 0;

/* v30：多目标跟踪 / 行为预测状态（dec_update 里也要读 g_pre_on，故先声明） */
static mot_ctx_t  g_mot;
static mot_work_t g_motw;
static int      g_pre_on = 0;        /* 预警窗口是否打开 */
static int      g_pre_id = 0, g_pre_eta = -1;
static uint32_t g_pre_ms = 0, g_pre_lead_ms = 0;
static int      g_track_conf = 0;    /* 本帧确认目标数 */
static int      g_js_person = 0, g_js_p = -128;   /* 给网页查看的 AI 状态 */
static int      g_last_ai_p = -128;  /* v1.3：上一帧 AI 分数（MOT 判定整幅前景用） */
static uint32_t g_pre_cnt = 0, g_lead_cnt = 0;

static int ai_vote_update(int p)
{
   ai_hist[ai_idx] = p;
   ai_idx = (ai_idx + 1) % AI_VOTE_N;
   if (ai_fill < AI_VOTE_N) ai_fill++;
   ai_p_now = p;
   int on = 0, off = 0;
   for (int i = 0; i < ai_fill; ++i) {
      if (ai_hist[i] >= AI_P_TH) on++;
      /* 2026-11-02 修：原来是严格小于，而模型空场时常正好输出 -40，
         于是"无人"永远不成立，报警释放被硬拖 8~10 s。改成 <=。 */
      if (ai_hist[i] <= AI_P_OFF) off++;
   }
   rel_cnt = off;
   /* v2.3：判"无人"只需最近 AI_OFF_N 帧都为否，不再要求整个 AI_VOTE_N 窗口全否，
      否则人走出画面后要等满 3 个推理节拍（约 2.3s）才能开始释放。 */
   g_person_off = (ai_fill >= AI_OFF_N && off >= AI_OFF_N) ? 1 : 0;
   return (on >= AI_VOTE_K) ? 1 : 0;
}

static void ai_reset(void)
{
   ai_idx = 0; ai_fill = 0; ai_p_now = -128; g_person_off = 0; rel_cnt = 0;
   for (int i = 0; i < AI_VOTE_N; ++i) ai_hist[i] = -128;
}

static int dec_update(int32_t score, int motion, int ir_hot, int infer_ran,
                      int person, int low_pwr_now, int32_t area)
{
   /* v28: one IR sample per decision loop; LP clears the complete ring. */
   if (low_pwr_now) {
      for (int i = 0; i < IR_OFF_WIN; ++i) ir_hist[i] = 0;
      ir_idx = 0; ir_cnt10 = 0; ir_cnt15 = 0; ir_cnt6 = 0;
   } else {
      ir_hist[ir_idx] = ir_hot ? 1 : 0;
      ir_idx = (ir_idx + 1) % IR_OFF_WIN;
      ir_cnt10 = 0; ir_cnt15 = 0; ir_cnt6 = 0;
      for (int i = 0; i < IR_OFF_WIN; ++i) {
         const int value = ir_hist[(ir_idx + IR_OFF_WIN - 1 - i) % IR_OFF_WIN];
         ir_cnt15 += value;
         if (i < IR_WIN) ir_cnt10 += value;
         if (i < IR_SOLO_N) ir_cnt6 += value;   /* v29.1: 最近 6 样本 IR 全热 */
      }
   }
   const int cand = motion && (area >= AI_AREA_MIN) && (area <= AI_AREA_MAX);
   if (cand) { cand_left = DEC_CAND_FRAMES; quiet_cnt = 0; }
   else { if (cand_left > 0) cand_left--; if (quiet_cnt < 1000) quiet_cnt++; }

   const uint64_t now = now_ms();
   if (!alarm_on) {
      int fusion = (cand_left > 0) &&
                         ((ir_cnt10 >= IR_NEED) || (ai_p_now >= AI_P_STRONG && ir_cnt10 >= 1));
      int solo   = (IR_SOLO_ON && (ir_cnt6 >= IR_SOLO_N)) ? 1 : 0;
#if HOTSRC_EXCL
      /* v29.2 热源排除：红外持续偏热但 AI 连续 AI_VOTE_N 次都判"无人"（p<AI_P_OFF），
         且没有运动候选 → 判为静态热源（水杯/电脑/暖风），不触发单模态报警。 */
      /* v2.1：融合报警也要求至少一条证据（MOT 检测 或 AI 判人）。
         否则"红外够热 + 旁边有动作"就会报——箱子/暖器这类静态热源正是这么被扫上的。 */
      /* v2.2：只判 nd==0 不够 —— 箱子自己也会产生一条静态检测，那时 nd>=1 就绕过了否决。
         改用"有没有在动的航迹"：mot_moving_confirmed() 本就是为此写的，却从未被调用。 */
      const int mot_moving = mot_moving_confirmed(&g_mot);
      if ((fusion || solo) && g_person_off && mot_moving == 0) {
         fusion = 0; solo = 0;
         g_hotsrc_cnt++;
         if ((g_hotsrc_cnt & 0x0F) == 1)
            bsp_printf("MMT_HOTSRC suppressed ms=%d f=%d cnt=%d ai_p=%d nd=%d mv=0 ir_cnt6=%d reason=no_moving\n\r",
                       (int)now, (int)g_frame, (int)g_hotsrc_cnt, ai_p_now, (int)g_mot.n_det, ir_cnt6);
      }
      if (solo && !fusion && g_person_off) {
         solo = 0;
         g_hotsrc_cnt++;
         if ((g_hotsrc_cnt & 0x0F) == 1)
            bsp_printf("MMT_HOTSRC suppressed ms=%d f=%d cnt=%d ai_p=%d ir_cnt6=%d\n\r",
                       (int)now, (int)g_frame, (int)g_hotsrc_cnt, ai_p_now, ir_cnt6);
      }
#endif
      /* v2.6 去抖 + 冷却：解除变快后，单帧动作会让报警反复起停（实测有 0.6s 的报警） */
      if (fusion || solo) { if (alarm_cand_cnt < 32000) alarm_cand_cnt++; }
      else alarm_cand_cnt = 0;
      const uint64_t since_end = alarm_end_ms ? (now - alarm_end_ms) : 0xFFFFFFFFu;
      if ((fusion || solo) && alarm_cand_cnt >= ALARM_START_FRAMES && since_end >= ALARM_COOLDOWN_MS) {
         alarm_on = 1; alarm_frames = 0; alarm_cand_cnt = 0;
         alarm_start_ms = (int)now;
         g_ev_id++;
         {   int ex = 48, ey = 48, k2;
             for (k2 = 0; k2 < g_mot.n_trk; ++k2)
                if (g_mot.trk[k2].active && g_mot.trk[k2].confirmed) {
                   ex = (int)g_mot.trk[k2].cx; ey = (int)g_mot.trk[k2].cy; break; }
             ge_ev_alarm(1, ex, ey, person ? 100 : 60, (int)g_track_conf, (int)g_mot.n_det, (uint32_t)now);
             ge_thumb_prepare();
         }
         ge_ev("as", (int)now, (int)area, (int)ir_cnt10, (int)(person ? 100 : 60),
               (int)g_mot.n_det, (int)g_track_conf, 1);
         bsp_printf("MMT_ALARM start ms=%d f=%d person=%d motion=%d area=%d cause=%s "
                    "nd=%d nt=%d conf=%d mv=%d\n\r",
                    (int)now, (int)g_frame, person, motion, (int)area,
                    (solo && !fusion) ? "ir_solo" : "fusion",
                    (int)g_mot.n_det, (int)g_mot.n_trk, (int)g_track_conf, mot_moving_confirmed(&g_mot));
      }
   } else {
      alarm_frames++;
      /* v2.4：AI 常对着空场/箱子判"有人"，若只认 AI，报警会一直挂着（实测挂 15s）。
      因此"长时间无动作 + 无在动航迹"也允许解除。 */
   /* v2.7：撤回"空闲兜底"。后排坐着不动的人会让 idle 成立，
      而 AI 判"有人"是正确的 —— 用 idle 解除等于有人在场时误解报警。 */
   const int no_person = g_person_off;
   if (infer_ran && no_person && (ir_cnt15 == 0 || quiet_cnt >= REL_QUIET_FRAMES)) {
           bsp_printf("MMT_ALARM end ms=%d f=%d dur_ms=%d\n\r",
                      (int)now, (int)g_frame, (int)now - alarm_start_ms);
           alarm_on = 0;
           ge_ev_alarm(0, 48, 48, 0, 0, (int)g_mot.n_det, (uint32_t)now);
           alarm_end_ms = now; alarm_cand_cnt = 0;   /* v2.6: 进入冷却 */
          ge_ev("ae", (int)now, (int)area, (int)ir_cnt15, 0, (int)g_mot.n_det, (int)g_track_conf, 0);
        }
   }
   if (low_pwr_now && alarm_on) {
      bsp_printf("MMT_ALARM end ms=%d f=%d dur_ms=%d reason=lowpwr\n\r",
                 (int)now, (int)g_frame, (int)now - alarm_start_ms);
      ge_ev_alarm(0, 48, 48, 0, 0, (int)g_mot.n_det, (uint32_t)now);
      alarm_on = 0; rel_cnt = 0; alarm_end_ms = now; alarm_cand_cnt = 0;
   }

   if (alarm_on) dec_evt = 1;
   else if (person) dec_evt = 3;
   else if (low_pwr_now) dec_evt = 4;
   else dec_evt = 0;

   /* v5.2：空场/低功耗时每 500 ms 推一帧"实时画面"（type=3, eid=0xFFFF0001），
      让纯网口模式下的 PC 页面也能看到画面；报警缩略图优先，未传完时不插入。 */
   if (!alarm_on && ge_thumb_idle()) {
      static uint64_t live_ms = 0;
      if ((now - live_ms) >= 500) { ge_thumb_prepare_id(EV_LIVE_ID); live_ms = now; }
   }
   /* v5.1：缩略图分片（报警时准备，每轮主循环至多一片，失败即丢） */
   ge_thumb_pump((uint32_t)now);

   /* v3.9: 每 2 s 往 PC 发一个心跳 JSON（网口自检 + 链路判活） */
   {
      static uint64_t ge_hb_ms = 0;
      if ((now - ge_hb_ms) >= 2000) {
         int gx = 48, gy = 48, k;
         for (k = 0; k < g_mot.n_trk; ++k)
            if (g_mot.trk[k].active && g_mot.trk[k].confirmed) {
               gx = (int)g_mot.trk[k].cx; gy = (int)g_mot.trk[k].cy; break;
            }
         (void)gx; (void)gy;
#if GE_RAW_TEST_FRAME
         ge_send_raw(ge_test_frame, 110);   /* 仅在排查 TX 通道时打开（会污染事件流） */
#endif
         ge_ev_hb((int)g_track_conf, person ? 1 : 0, alarm_on ? 1 : 0, 0, (int)area, (uint32_t)now);
         bsp_printf("MMT_GE ctrl=%d status=%d rx=%d\n\r",
                    (int)GE_CTRL, (int)GE_STATUS, (int)R32(30));
         ge_hb_ms = now;
      }
   }
#if FW_DECISION_ON
   g_js_person = person ? 1 : 0;
   g_js_p = (int)score;
   APB_DEC = (uint32_t)(alarm_on ? 1u : 0u) |
             ((uint32_t)(alarm_on ? 100 : (person ? 60 : 0)) << 8) |
             ((uint32_t)(dec_evt & 0xFF) << 16);
   {
      const int fw_en = (infer_ran || alarm_on) ? 1 : 0;
      APB_CTRL = (uint32_t)(fw_en ? 1u : 0u) |
                 (uint32_t)((infer_ran ? 1u : 0u) << 1);
   }
#endif
   return alarm_on;
}

// ===========================================================================
// v30：多目标跟踪 + 行为预测（mot_core.h）
//   每帧（含低功耗轮询）跑一次：背景差分 → 连通域 → IOU 关联 → 速度/预测
//   预测"即将进入 ROI"时立刻 PREWARN，并跳出低功耗提前恢复全速推理
// ===========================================================================
/* v30：MOT 必须看"传感器原始值"，不能看 STRETCH 后的画面。
   STRETCH 是逐帧 1%/99% 分位重映射，人一进画面整幅灰度就被重排，
   背景差分会把整幅判成前景（实测 area≈8800/9216、bbox 96x96）。
   所以这里单独再采一遍（不拉伸、不归一化）。 */
static void mot_sample_raw(void)
{
   pp_cfg_t cfg;
   cfg.crop_mode = CROP_MODE;
   cfg.norm_on = 0;
   cfg.stretch_on = 0;
   (void)pp_run(fb_get, 0, &cfg, mot_img, 0);
}

static void mot_track_frame(uint32_t frame)
{
#if MOT_ON
   int k, pre = 0, eta = -1, id = 0, nconf = 0;
   mot_step(&g_mot, &g_motw, (const unsigned char*)mot_img, g_last_ai_p, ir_cnt10);

   for (k = 0; k < g_mot.n_trk; ++k) {
      const mot_trk_t* t = &g_mot.trk[k];
      if (!t->active) continue;         /* 丢失中的航迹保留但不报，等重连 */
      if (!t->confirmed) continue;      /* 从没确认过的噪点航迹不打印 */
      if (!t->supported) continue;      /* v1.8 #2：无支撑（sup>3 / hits<3 / 面积<80）的航迹不输出 */
      if (t->confirmed) nconf++;
      bsp_printf("MMT_TRK f=%d id=%d c=%d,%d b=%d,%d,%d,%d v16=%d,%d dir=%d "
                 "hit=%d miss=%d conf=%d pred=%d,%d eta=%d\n\r",
                 (int)frame, (int)t->id, (int)t->cx, (int)t->cy,
                 (int)t->x0, (int)t->y0, (int)t->x1, (int)t->y1,
                 (int)t->vx, (int)t->vy, (int)t->dir,
                 (int)t->hits, (int)t->misses, (int)t->confirmed,
                 (int)t->px, (int)t->py, (int)t->eta);
      if (t->supported && t->hits >= 1 && t->eta >= 0 && t->eta <= (MOT_HORIZON + 3) && !g_mot.shaking) {
         pre = 1;
         if (eta < 0 || (int)t->eta < eta) { eta = (int)t->eta; id = (int)t->id; }
      }
   }
   {
      /* v3.6：页面上的"几个人"用这个数 —— 本帧真的看到、框够大、非整幅光照突变。
         n_trk 是航迹表大小（含正在丢失的航迹与噪点），拿它当人数会出现
         "一个人显示两个人 / 人走了还显示一个人"。 */
      const int n_fresh = mot_fresh_confirmed(&g_mot);
      g_track_conf = n_fresh;
      bsp_printf("MMT_MOT f=%d nd=%d nt=%d conf=%d area=%d raw=%d pre=%d pre_eta=%d obs=%d\n\r",
                 (int)frame, g_mot.n_det, g_mot.n_trk, nconf, g_mot.last_area,
                 g_mot.raw_area, pre, eta, n_fresh);
   }

#if MOT_PRE_ON
   if (pre && !g_pre_on) {
      g_pre_on = 1; g_pre_id = id; g_pre_eta = eta; g_pre_ms = (uint32_t)now_ms();
      {   /* v17：预警同时上报 UDP 事件 type=2(TREND)，PC 页面能提前看到"正在靠近" */
         int ex = 48, ey = 48, k2;
         for (k2 = 0; k2 < g_mot.n_trk; ++k2)
            if (g_mot.trk[k2].active && g_mot.trk[k2].confirmed) {
               ex = (int)g_mot.trk[k2].cx; ey = (int)g_mot.trk[k2].cy; break; }
         ge_ev_alarm(2, ex, ey, (int)g_pre_eta, (int)g_track_conf, (int)g_mot.n_det, (uint32_t)now_ms());
      }
      g_pre_cnt++;
      bsp_printf("MMT_PREWARN f=%d id=%d eta=%d ms=%d fw_lp=%d\n\r",
                 (int)frame, id, eta, (int)g_pre_ms, fw_lp);
#if LOWPOWER_ON
      if (fw_lp) {                    /* 提前响应：不等 RTL motion，先恢复全速推理 */
         fw_lp = 0;
         lp_last_active_ms = now_ms();
         bsp_printf("MMT_LP_EXIT f=%d reason=prewarn ms=%d\n\r", (int)frame, (int)now_ms());
      }
#endif
   } else if (!pre && g_pre_on) {
      g_pre_on = 0;
   }
#endif
#else
   (void)frame;
#endif
}

/* 预警提前量：预警打开后真报警到来时记录差值 */
static void mot_lead_check(uint32_t frame)
{
#if MOT_PRE_ON
   if (alarm_on && g_pre_on && g_pre_lead_ms == 0) {
      g_pre_lead_ms = (uint32_t)now_ms() - g_pre_ms;
      g_lead_cnt++;
      bsp_printf("MMT_PREDLEAD f=%d lead_ms=%d id=%d eta=%d\n\r",
                 (int)frame, (int)g_pre_lead_ms, g_pre_id, g_pre_eta);
   }
   if (!alarm_on) g_pre_lead_ms = 0;
#else
   (void)frame;
#endif
}

static void dec_log(uint32_t frame, int32_t score, int motion, int ir_hot,
                    uint32_t area, int32_t conf_rtl, int alarm_rtl)
{
   g_dec_ms = (uint32_t)now_ms();
   bsp_printf("MMT_DEC t=%d f=%d score=%d mean=%d slope=0 con=%d trend=0 evt=%d "
              "alarm_req=%d conf=%d motion=%d irhot=%d area=%d rtl_conf=%d "
              "rtl_alarm=%d cand=%d rel=%d person=%d ir_cnt=%d act=%d hotsrc=%d\n\r",
              (int)g_dec_ms, (int)frame, (int)score, (int)score, cand_left, dec_evt,
              alarm_on, (alarm_on ? 100 : (last_person ? 60 : 0)), motion, ir_hot,
              (int)area, (int)conf_rtl, alarm_rtl, cand_left, rel_cnt, last_person, ir_cnt10,
              /* v29.2 行为标签：0=无人 1=静止(STILL) 2=行走/运动(WALK) */
              ((alarm_on || last_person) ? ((motion && (int)area >= AI_AREA_MIN) ? 2 : 1) : 0),
              (int)g_hotsrc_cnt);
}

static void dump_image(const int8_t* img, uint32_t frame, int p)
{
   int mn = 127, mx = -128;
   long sum = 0;
   for (int i = 0; i < IMG_N; ++i) {
      const int v = (int)img[i];
      if (v < mn) mn = v;
      if (v > mx) mx = v;
      sum += v;
   }
   bsp_printf("MMT_IMGSTAT f=%d min=%d max=%d mean=%d p=%d\n\r",
              (int)frame, mn, mx, (int)(sum / IMG_N), p);

   char line[8 + 2 + 1 + 192 + 1];
   for (int y = 0; y < 96; ++y) {
      line[0] = 'M'; line[1] = 'M'; line[2] = 'T'; line[3] = '_';
      line[4] = 'I'; line[5] = 'M'; line[6] = 'G'; line[7] = ' ';
      line[8] = (char)('0' + (y / 10) % 10);
      line[9] = (char)('0' + y % 10);
      line[10] = ' ';
      for (int x = 0; x < 96; ++x) {
         const uint8_t b = (uint8_t)img[y * 96 + x];
         line[11 + x * 2] = HEXD[b >> 4];
         line[12 + x * 2] = HEXD[b & 0x0Fu];
      }
      line[11 + 192] = 0;
      bsp_printf("%s\n\r", line);
   }
}

static void dump_thumb(const int8_t* img, uint32_t frame, int p)
{
   static int8_t full[IMG_N];
   static char pixels[THUMB_W * THUMB_H * 2 + 1];
   static int  geo_done = 0;
   int offset = 0;

   /* 2026-11-02：img==0 表示取"整幅画面"降采样（原先只发 AI 中心裁剪，看着像只有一半）。
      裁剪框单独用 MMT_THUMB_GEO 报给上位机，由 PC 侧画框。 */
   if (img == 0) {
      pp_cfg_t fcfg;
      fcfg.crop_mode = 0; fcfg.norm_on = 0; fcfg.stretch_on = 0;
      (void)pp_run(fb_get, 0, &fcfg, full, 0);
      img = full;
   }
   if (!geo_done || (frame % 20) == 0) {   /* 周期重发：上位机晚接也能拿到 */
      int gx0, gy0, gw, gh;
      geo_done = 1;
      pp_geometry(CROP_MODE, &gx0, &gy0, &gw, &gh);
      bsp_printf("MMT_THUMB_GEO fw=%d fh=%d bx=%d by=%d bw=%d bh=%d full=1\n\r",
                 PP_FRAME_W, PP_FRAME_H, gx0, gy0, gw, gh);
   }
   for (int y = 0; y < THUMB_H; ++y) {
      const int sy = (y * 96) / THUMB_H;
      const int sy2 = (sy + 1 < 96) ? sy + 1 : sy;
      for (int x = 0; x < THUMB_W; ++x) {
         const int i = sy * 96 + x * 2;
         const int j = sy2 * 96 + x * 2;
         const unsigned sum = (uint8_t)img[i] + (uint8_t)img[i + 1]
                            + (uint8_t)img[j] + (uint8_t)img[j + 1];
         const uint8_t value = (uint8_t)(sum / 4u);
         pixels[offset++] = HEXD[value >> 4];
         pixels[offset++] = HEXD[value & 0x0Fu];
      }
   }
   pixels[offset] = 0;
   bsp_printf("MMT_THUMB t=%d f=%d alarm=%d p=%d %s\n\r",
              (int)g_dec_ms, (int)frame, alarm_on, p, pixels);
}


/* SC431HAI V1.1 p23-26. No mode-bit guesses, no VTS/FPS or digital-gain writes. */
#define BRIGHT_CALIBRATION 0
#define BRIGHT_FIXED_EXP20 47824
#define BRIGHT_FIXED_GC 129
#define NIGHT 1
#define DAY 2
#ifndef CAM_PRESET
#define CAM_PRESET NIGHT
#endif
#if CAM_PRESET == NIGHT
#define CAM_PRESET_NAME "NIGHT"
#define BRIGHT_FIXED_GF 63
#elif CAM_PRESET == DAY
#define CAM_PRESET_NAME "DAY"
#define BRIGHT_FIXED_GF 42
#else
#error Unsupported CAM_PRESET
#endif
static int bright_exp20=0, bright_gc=0, bright_gf=0, bright_ready=0;

static int bright_read(int* vts_out,int* exp_out,int* gc_out,int* gf_out)
{
   unsigned char values[7];
   const unsigned short regs[7]={0x320e,0x320f,0x3e00,0x3e01,0x3e02,0x3e08,0x3e09};
   for(int i=0;i<7;i++)if(cam_raw_read(regs[i],&values[i]))return -1;
   *vts_out=((values[0]&0x7f)<<8)|values[1];
   *exp_out=((values[2]&0x0f)<<16)|(values[3]<<8)|(values[4]&0xf0);
   *gc_out=values[5];*gf_out=values[6];return 0;
}

static int bright_apply(int exp20,int gc,int gf)
{
   const unsigned short regs[5]={0x3e00,0x3e01,0x3e02,0x3e08,0x3e09};
   unsigned char old[5],value[5];
   for(int i=0;i<5;i++)if(cam_raw_read(regs[i],&old[i]))return -1;
   value[0]=(unsigned char)((old[0]&0xf0)|((exp20>>16)&0x0f));
   value[1]=(unsigned char)((exp20>>8)&0xff);
   value[2]=(unsigned char)((old[2]&0x0f)|(exp20&0xf0));
   value[3]=(unsigned char)gc;value[4]=(unsigned char)gf;
   for(int i=0;i<5;i++){
      if(cam_checked_write(&g_cam_io,regs[i],value[i],0)!=CAM_OK){
         for(int j=0;j<5;j++)(void)cam_checked_write(&g_cam_io,regs[j],old[j],0);
         return -2;
      }
   }
   int vts=0,exp=0,rc=0,rf=0;
   if(bright_read(&vts,&exp,&rc,&rf)||exp!=exp20||rc!=gc||rf!=gf)return -3;
   bright_exp20=exp;bright_gc=rc;bright_gf=rf;bright_ready=1;return 0;
}

static void bright_log(const char* tag)
{
   int vts=0,exp=0,gc=0,gf=0;
   const int status=bright_read(&vts,&exp,&gc,&gf);
   bsp_printf("%s ms=%d ok=%d vts=%d exp20=%d half_lines=%d gc=%d gf=%d fixed=%d\n\r",
              tag,(int)now_ms(),status==0,vts,exp,exp>>4,gc,gf,bright_ready);
}

/* ---------------------------------------------------------------------------
 * v29.2 亮度闭环（GAIN_AUTO）：不分档位，只有一个目标——画面平均亮度 mean_sensor 逼近 GA_TARGET。
 * 曝光时间固定不动，只调"总增益" G（Q8，256=1x）= 粗增益(1/2/4/8/16x) x 细增益(gf/32，1.0~1.97x)。
 * 每次按 目标/当前 修正，单步限幅 0.7~1.4 倍；偏差在 +-GA_BAND% 内不动；连续 GA_NEED 次才动。
 * 有运动/有人/报警时冻结，只在空场调整，避免白衣服或人体把增益拉偏。
 * ------------------------------------------------------------------------- */
#ifndef GAIN_AUTO_ON
#define GAIN_AUTO_ON 1       /* v29.2 本轮：新亮度闭环（GA_TARGET=100） */
#endif
#define GA_TARGET 100
#define GA_BAND   15       /* 百分比 */
#define GA_NEED   2
#define GA_HOLD   1
#define GA_GMIN   256u     /* 1x */
#define GA_GMAX   8176u    /* 16 x 1.99 */
static const unsigned char ga_gc_code[5] = {0x80, 0x81, 0x83, 0x87, 0x8f};

static unsigned ga_g_from(unsigned gc, unsigned gf)
{
   unsigned k = 0;
   for (unsigned i = 0; i < 5; ++i) if (ga_gc_code[i] == gc) k = i;
   return ((unsigned)(1u << k)) * gf * 8u;     /* gf/32 * 256 = gf*8 */
}

static void ga_map(unsigned g, unsigned* gc, unsigned* gf)
{
   if (g < GA_GMIN) g = GA_GMIN;
   if (g > GA_GMAX) g = GA_GMAX;
   unsigned k = 0;
   while (k < 4 && (g >> (k + 1)) >= 256u) k++;
   unsigned fine = g >> k;                     /* 256..511 */
   unsigned f = fine >> 3;                     /* 32..63 */
   if (f < 0x20u) f = 0x20u;
   if (f > 0x3fu) f = 0x3fu;
   *gc = ga_gc_code[k];
   *gf = f;
}

/* 纯决策：返回新的总增益；便于主机仿真测试 */
static unsigned ga_decide(int mean, int allowed, unsigned g, int* cnt, int* hold)
{
   if (!allowed) { *cnt = 0; return g; }
   if (*hold > 0) { (*hold)--; return g; }
   if (mean < 1) mean = 1;
   const int dev = (mean - GA_TARGET) * 100 / GA_TARGET;
   if (dev <= GA_BAND && dev >= -GA_BAND) { *cnt = 0; return g; }
   if (++(*cnt) < GA_NEED) return g;
   *cnt = 0;
   unsigned ratio = (unsigned)((GA_TARGET * 256) / mean);   /* Q8 */
   if (ratio < 179u) ratio = 179u;                         /* 0.7x */
   if (ratio > 358u) ratio = 358u;                         /* 1.4x */
   unsigned ng = (unsigned)(((unsigned long)g * ratio) >> 8);
   if (ng < GA_GMIN) ng = GA_GMIN;
   if (ng > GA_GMAX) ng = GA_GMAX;
   *hold = GA_HOLD;
   return ng;
}

static unsigned g_ga_g = 0;
static int g_ga_cnt = 0, g_ga_hold = 0, g_ga_off = 0;

static void ga_update(int mean, int allowed)
{
#if GAIN_AUTO_ON
   if (!bright_ready || g_ga_off) return;
   if (g_ga_g == 0) g_ga_g = ga_g_from((unsigned)bright_gc, (unsigned)bright_gf);
   const unsigned ng = ga_decide(mean, allowed, g_ga_g, &g_ga_cnt, &g_ga_hold);
   if (ng != g_ga_g) {
      unsigned gc, gf;
      ga_map(ng, &gc, &gf);
      if (bright_apply(bright_exp20, (int)gc, (int)gf) == 0) {
         bsp_printf("MMT_GAIN g=%d->%d gc=0x%x gf=0x%x mean=%d target=%d\n\r",
                    (int)g_ga_g, (int)ng, gc, gf, mean, GA_TARGET);
         g_ga_g = ng;
      } else {
         g_ga_off = 1;   /* 写失败：保持当前增益，不再自动调整 */
         bsp_printf("MMT_GAIN_ERR g=%d->%d mean=%d (auto disabled)\n\r", (int)g_ga_g, (int)ng, mean);
      }
   }
#else
   (void)mean; (void)allowed;
#endif
}

static void bright_initialize(void)
{
   unsigned char id_h=0,id_l=0;
   if(cam_raw_read(0x3107,&id_h)||cam_raw_read(0x3108,&id_l)){
      bsp_printf("MMT_BRIGHT_ERROR sensor_id_read\n\r");return;
   }
   bsp_printf("MMT_BRIGHT_ID id=%d\n\r",(id_h<<8)|id_l);
   if(id_h!=0xcd||id_l!=0x6b){bsp_printf("MMT_BRIGHT_ERROR unexpected_sensor_id\n\r");return;}
   int vts=0,original_exp=0,original_gc=0,original_gf=0;
   if(bright_read(&vts,&original_exp,&original_gc,&original_gf)||vts<32||vts>0x7ff0){
      bsp_printf("MMT_BRIGHT_ERROR invalid_boot_registers\n\r");return;
   }
   bright_log("MMT_BRIGHT_BEFORE");
#if BRIGHT_CALIBRATION
   const int gains[][2]={{0x80,0x2a},{0x80,0x3f},{0x81,0x2a},{0x81,0x3f},
      {0x83,0x2a},{0x83,0x3f},{0x87,0x2a},{0x87,0x3f},{0x8f,0x2a},{0x8f,0x3f}};
   const int limit=(2*vts-11)<<4;
   const int fixed_exp=(original_exp<limit && original_exp>=64)?original_exp:limit;
   int best_exp=original_exp,best_gc=original_gc,best_gf=original_gf,best_cost=100000;
   for(int idx=-1;idx<(int)(sizeof(gains)/sizeof(gains[0]));idx++){
      const int exp=idx<0?original_exp:fixed_exp;
      const int gc=idx<0?original_gc:gains[idx][0],gf=idx<0?original_gf:gains[idx][1];
      if(idx>=0 && bright_apply(exp,gc,gf)){bsp_printf("MMT_BRIGHT_ERROR apply_idx=%d\n\r",idx);break;}
      delay_ms(300);
      int means[8],sats[8];
      for(int sample=0;sample<12;sample++){
         static int8_t raw[IMG_N];pp_stats_t raw_stats;
         pp_cfg_t raw_cfg={CROP_MODE,0,0};
         (void)pp_run(fb_get,0,&raw_cfg,raw,&raw_stats);
         int saturated=0;for(int i=0;i<IMG_N;i++)if((uint8_t)raw[i]>=250)saturated++;
         const int sat=(saturated*1000)/IMG_N;
         bsp_printf("MMT_BRIGHT_SAMPLE ms=%d idx=%d n=%d mean_sensor=%d sat_permille=%d\n\r",
                    (int)now_ms(),idx,sample,raw_stats.mean_sensor,sat);
         if(sample>=4){means[sample-4]=raw_stats.mean_sensor;sats[sample-4]=sat;}
         delay_ms(120);
      }
      for(int i=0;i<8;i++)for(int j=i+1;j<8;j++){
         if(means[j]<means[i]){int t=means[i];means[i]=means[j];means[j]=t;}
         if(sats[j]<sats[i]){int t=sats[i];sats[i]=sats[j];sats[j]=t;}
      }
      const int median=(means[3]+means[4])/2,sat=(sats[3]+sats[4])/2;
      int distance=median>95?median-95:95-median;
      const int cost=distance+(sat>50?(sat-50)*10:0);
      bsp_printf("MMT_BRIGHT_STEP ms=%d idx=%d vts=%d exp20=%d gc=%d gf=%d mean_sensor=%d sat_permille=%d cost=%d\n\r",
                 (int)now_ms(),idx,vts,exp,gc,gf,median,sat,cost);
      pp_stats_t preview;(void)sample_frame_box(input_snapshot,&preview);
      dump_image(input_snapshot,(uint32_t)(2000000000+idx+1),-128);
      if(idx>=0 && cost<best_cost){best_cost=cost;best_exp=exp;best_gc=gc;best_gf=gf;}
      if(idx>=0 && median>=80 && median<=110 && sat<=50)break;
   }
   if(bright_apply(best_exp,best_gc,best_gf)){bsp_printf("MMT_BRIGHT_ERROR final_apply\n\r");return;}
#else
   const int expected=BRIGHT_FIXED_EXP20;
   if(expected<64 || (expected>>4)>(2*vts-11) || bright_apply(expected,BRIGHT_FIXED_GC,BRIGHT_FIXED_GF)){
      bsp_printf("MMT_BRIGHT_ERROR fixed_apply\n\r");return;
   }
#endif
   bright_log("MMT_BRIGHT_LOCKED");
}

// ===========================================================================
// v29.1 白平衡（MERGE16 word 19..26）
//   19/20/21 = R/G/B 增益（Q8.8）；22..26 = 中心 640x360 每帧统计（只读）
//   WB_CAL=1：开机连续读 32 帧，丢弃 pix==0 或 sat*20 > pix（饱和 >5%）的帧，
//             以 G 为基准求 R/B 新增益并写回，打印 MMT_WB；标定后把结果写进宏、
//             WB_CAL=0 重编。
// ===========================================================================
#ifndef WB_R
#define WB_R             0x158    /* 1.344x，历史收敛值 WBH7 */
#endif
#ifndef WB_G
#define WB_G             0x118    /* 1.094x，G 作为基准不随标定改变 */
#endif
#ifndef WB_B
#define WB_B             0x170    /* 1.640625x（v29.2 本轮默认值） */
#endif
#ifndef WB_CAL
#define WB_CAL           0        /* 1=开机标定一次（上板 a 步），0=使用宏内固定增益 */
#endif

static void wb_initialize(void)
{
   APB_WB_R = (uint32_t)WB_R;
   APB_WB_G = (uint32_t)WB_G;
   APB_WB_B = (uint32_t)WB_B;
   bsp_printf("MMT_WB_INIT r=%d g=%d b=%d cal=%d\n\r", WB_R, WB_G, WB_B, WB_CAL);
}

#if WB_CAL
static void wb_calibrate(void)
{
   uint64_t ar = 0, ag = 0, ab = 0;
   uint32_t used = 0, skipped = 0;
   for (uint32_t i = 0; i < 32; ++i) {
      const uint32_t pix = APB_WB_PIX;
      const uint32_t sat = APB_WB_SAT;
      if (pix == 0 || ((uint64_t)sat * 20u > (uint64_t)pix)) {
         skipped++;
         delay_ms(40);
         continue;
      }
      if (used == 0) {
         bsp_printf("MMT_WB_STAT pix=%d sat=%d r=%d g=%d b=%d\n\r",
                    (int)pix, (int)sat, (int)APB_WB_SR, (int)APB_WB_SG, (int)APB_WB_SB);
      }
      ar += APB_WB_SR; ag += APB_WB_SG; ab += APB_WB_SB;
      used++;
      delay_ms(40);
   }
   if (used < 8) {
      bsp_printf("MMT_WB_FAIL used=%d skipped=%d (stat area not ready)\n\r", used, skipped);
      return;
   }
   const uint32_t rm = (uint32_t)(ar / used);
   const uint32_t gm = (uint32_t)(ag / used);
   const uint32_t bm = (uint32_t)(ab / used);
   uint32_t nr = (uint32_t)WB_G, nb = (uint32_t)WB_B;
   if (rm) nr = (uint32_t)(((uint64_t)WB_G * gm) / rm);
   if (bm) nb = (uint32_t)(((uint64_t)WB_G * gm) / bm);
   if (nr > 0xFFFFu) nr = 0xFFFFu;
   if (nb > 0xFFFFu) nb = 0xFFFFu;
   bsp_printf("MMT_WB r=%d g=%d b=%d Rmean=%d Gmean=%d Bmean=%d used=%d skipped=%d\n\r",
              nr, WB_G, nb, rm, gm, bm, used, skipped);
   APB_WB_R = nr; APB_WB_G = (uint32_t)WB_G; APB_WB_B = nb;
   delay_ms(60);
   bsp_printf("MMT_WB_APPLY r=%d g=%d b=%d\n\r", APB_WB_R, APB_WB_G, APB_WB_B);
}
#endif

void tinyml_init()
{
   static tflite::MicroErrorReporter reporter;
   error_reporter = &reporter;
   model = tflite::GetModel(v29_person_96_int8_model_data);
   if (model->version() != TFLITE_SCHEMA_VERSION) {
      MicroPrintf("MMT_LIVE_FAIL MODEL_VERSION\n\r");
      while (1) {}
   }
   static tflite::MicroMutableOpResolver<4> resolver;
   resolver.AddMean();
   resolver.AddConv2D();
   resolver.AddFullyConnected();

   resolver.AddSoftmax();
   static FullProfiler prof;
   static tflite::MicroInterpreter si(
      model, resolver, tensor_arena, kTensorArenaSize, error_reporter, nullptr);
   interpreter = &si;
   prof.setInterpreter(interpreter);
   prof.setDump(false);
   if (interpreter->AllocateTensors() != kTfLiteOk) {
      MicroPrintf("MMT_LIVE_FAIL ALLOCATE\n\r");
      while (1) {}
   }
   model_input = interpreter->input(0);
   MicroPrintf("MMT_LIVE_MODEL in_bytes=%d in_type=%d\n\r",
               (int)model_input->bytes, (int)model_input->type);
}


static void ge_http_build_json(int now, int motion, int area, int irhot,
                               int camfps, int inf_hz, int paused, int lowpwr,
                               int sht10, int rh10, int body10)
{
   char* d = g_status_json;
   d = ge_str(d, "{\"person\":");
   d = ge_num(d, (unsigned)(g_js_person ? 1 : 0));
   d = ge_str(d, ",\"p\":");
   d = ge_num(d, (unsigned)(g_js_p & 0xFF));
   d = ge_str(d, ",\"motion\":");
   d = ge_num(d, (unsigned)motion);
   d = ge_str(d, ",\"area\":");
   d = ge_num(d, (unsigned)area);
   d = ge_str(d, ",\"irhot\":");
   d = ge_num(d, (unsigned)irhot);
   d = ge_str(d, ",\"alarm\":");
   d = ge_num(d, (unsigned)(alarm_on ? 1 : 0));
   d = ge_str(d, ",\"fw_lp\":");
   d = ge_num(d, (unsigned)(fw_lp ? 1 : 0));
   d = ge_str(d, ",\"lowpwr\":");
   d = ge_num(d, (unsigned)lowpwr);
   d = ge_str(d, ",\"paused\":");
   d = ge_num(d, (unsigned)paused);
   d = ge_str(d, ",\"camfps\":");
   d = ge_num(d, (unsigned)camfps);
   d = ge_str(d, ",\"inf_hz\":");
   d = ge_num(d, (unsigned)inf_hz);
   d = ge_str(d, ",\"sht\":");
   d = ge_num(d, (unsigned)(sht10 / 10));
   d = ge_str(d, ",\"rh\":");
   d = ge_num(d, (unsigned)(rh10 / 10));
   d = ge_str(d, ",\"body\":");
   d = ge_num(d, (unsigned)(body10 / 10));
   d = ge_str(d, ",\"mot_nd\":");
   d = ge_num(d, (unsigned)g_mot.n_det);
   d = ge_str(d, ",\"mot_nt\":");
   d = ge_num(d, (unsigned)g_mot.n_trk);
   d = ge_str(d, ",\"mot_conf\":");
   d = ge_num(d, (unsigned)g_track_conf);
   d = ge_str(d, ",\"mot_obs\":");
   d = ge_num(d, (unsigned)g_track_conf);
   d = ge_str(d, ",\"alarm_nd\":");
   d = ge_num(d, (unsigned)g_mot.n_det);
   d = ge_str(d, ",\"alarm_nt\":");
   d = ge_num(d, (unsigned)g_mot.n_trk);
   d = ge_str(d, ",\"connected\":1,\"thumb_ts\":");
   d = ge_num(d, (unsigned)(now / 1000));
   d = ge_str(d, ",\"last\":");
   d = ge_num(d, (unsigned)(EPOCH_BASE + now / 1000));
   d = ge_str(d, "}");
   *d = 0;
}

// ===========================================================================
// 主函数

// ===========================================================================
extern "C" int main()
{
   MicroPrintf("MMT_LIVE_BOOT v29.2 CROP=%d NORM=%d STRETCH=%d AE=%d LPCAM=%d "
               "FW_DEC=%d LOWPOWER=%d\n\r",
               CROP_MODE, NORM_ON, STRETCH_ON, AUTOEXP_ON, LP_CAMFPS_ON,
               FW_DECISION_ON, LOWPOWER_ON);
   MicroPrintf("MMT_CFG v28 CROP_MODE=%d NORM_ON=%d STRETCH_ON=%d AUTOEXP_ON=%d "
               "LP_CAMFPS_ON=%d LP_VTS_MULT=%d FW_DECISION_ON=%d LOWPOWER_ON=%d "
               "INPUT_SUB128=%d AI_P_TH=%d AI_VOTE=%d/%d AREA=[%d,%d] DEC_CAND=%d\n\r",
               CROP_MODE, NORM_ON, STRETCH_ON, AUTOEXP_ON, LP_CAMFPS_ON,
               LP_VTS_MULT, FW_DECISION_ON, LOWPOWER_ON, INPUT_SUB128,
               AI_P_TH, AI_VOTE_K, AI_VOTE_N, AI_AREA_MIN, AI_AREA_MAX, DEC_CAND_FRAMES);

   MicroPrintf("MMT_MOT_CFG ver=v30.6 on=%d pre=%d diff=%d min_area=%d max_area=%d "
               "iou_pm=%d horizon=%d max_trk=%d roi=[%d,%d,%d,%d]\n\r",
               MOT_ON, MOT_PRE_ON, MOT_DIFF_THR, MOT_MIN_AREA, MOT_MAX_AREA,
               MOT_IOU_THR, MOT_HORIZON, MOT_MAX_TRK,
               MOT_ROI_X0, MOT_ROI_Y0, MOT_ROI_X1, MOT_ROI_Y1);

   bsp_printf("MMT_FUSION IR_WIN=%d IR_NEED=%d IR_OFF_WIN=%d AI_P_STRONG=%d AI_P_OFF=%d THUMB_EVERY=%d "
              "IR_SOLO_ON=%d IR_SOLO_N=%d\n\r",
              IR_WIN, IR_NEED, IR_OFF_WIN, AI_P_STRONG, AI_P_OFF, THUMB_DUMP_EVERY,
              IR_SOLO_ON, IR_SOLO_N);

   const u32 hart = csr_read(mhartid);
   tinyml_init();
   IntcInitialize();
   init_accel(hart);
   print_accel(hart);
   MicroPrintf("MMT_LIVE_HW_READY uuid=%x\n\r", hw_accel_setting[0].uuid);

   APB_OSD = 0;
   APB_SCORE = 0;
   APB_DEC = 0;
   APB_CTRL = 0;

   g_fb_base = FB_BASE + (uint32_t)LIVE_BANK * FB_FRAME_LEN;

   /* v15 兼容：只读一次 VTS（MMT_CAM_VTS 行保持不变） */
   int      vts_ok = 0;
   uint32_t vts = cam_read_vts_compat(&vts_ok);
   MicroPrintf("MMT_CAM_VTS ok=%d vts=0x%x rom_vts=0 fallback=1\n\r", vts_ok, (unsigned)vts);

   /* 功能 1：启动读相机寄存器（只有启用需要它的功能时才读，保证默认行为与 v15 一致） */
   cam_boot_ok = 0;
   if (1) {
      if (cam_boot_read_all() == 0) {
         cam_boot_log();
      } else {
         MicroPrintf("MMT_CAM_ERR boot read failed (AE/LPCAM disabled)\n\r");
      }
   }

   bright_initialize();
   wb_initialize();
   pp_stats_t boot_pst;
   sample_frame_box(input_snapshot,&boot_pst);
   bsp_printf("MMT_CAM_PRESET name=%s vts=1500 exp20=%d gc=%d gf=%d mean_sensor=%d\n\r",
              CAM_PRESET_NAME,BRIGHT_FIXED_EXP20,BRIGHT_FIXED_GC,BRIGHT_FIXED_GF,boot_pst.mean_sensor);
#if WB_CAL
   wb_calibrate();
#endif

   /* 功能 2 初始化 */
#if AUTOEXP_ON
   g_ae_enabled = 0;
   if (cam_boot_ok && cam_exp_init > 0 && cam_gain_init > 0) {
      ae_init(&g_ae, cam_exp_init, cam_gain_init, 4, 2, AE_DIM_ENABLE);
      g_ae_enabled = 1;
      MicroPrintf("MMT_AE init exp0=0x%x gain0=0x%x exp_range=[0x%x,0x%x] "
                  "gain_range=[0x%x,0x%x] target=[%d,%d] step=%d%% eval=%d dim=%d\n\r",
                  (unsigned)g_ae.exp, (unsigned)g_ae.gain,
                  (unsigned)g_ae.exp_min, (unsigned)g_ae.exp_max,
                  (unsigned)g_ae.gain_min, (unsigned)g_ae.gain_max,
                  AE_TARGET_LO, AE_TARGET_HI, AE_STEP_PCT, AE_EVAL_FRAMES,
                  AE_DIM_ENABLE);
      if (ae_manual_mode() != 0) {
         MicroPrintf("MMT_AE_ERR manual mode write failed (AE disabled)\n\r");
         g_ae_enabled = 0;
      }
   } else {
      MicroPrintf("MMT_AE_ERR boot regs invalid (AE disabled)\n\r");
   }
#endif

   /* 功能 3 初始化 */
#if LP_CAMFPS_ON
   g_lp_ready = 0;
   if (cam_boot_ok) {
      const int r = cam_lp_init(&g_cam_io, &g_lp);
      if (r == CAM_OK) {
         g_lp_ready = 1;
         MicroPrintf("MMT_LPCAM init vts0=0x%x mult=%d enabled=1\n\r",
                     g_lp.vts_init, LP_VTS_MULT);
      } else {
         MicroPrintf("MMT_LPCAM init vts=0x%x DISABLED (valid range [0x%x,0x%x])\n\r",
                     g_lp.vts_init, CAM_VTS_MIN_OK, CAM_VTS_MAX_OK);
      }
   } else {
      MicroPrintf("MMT_LPCAM DISABLED (boot regs unavailable)\n\r");
   }
#else
   (void)g_lp_ready;

   uint32_t frame = 0;
   uint32_t infer_total = 0, infer_win = 0;
   int      infer_paused = 0;
   uint32_t sht_last = 0, sht_upd = 0;
   uint32_t ir_last_flags = 0, ir_upd = 0;
   uint32_t ddr_ar_last = 0, tinyml_ar_last = 0, ddr_win = 0, tinyml_win = 0;
   uint32_t vs_last = 0;
   uint64_t t_win = now_ms();
   lp_last_active_ms = now_ms();
   uint32_t lp_entry_cnt = 0, lp_exit_cnt = 0;

   ge_http_init();
   bsp_printf("MMT_APB27 %d %d %d %d %d\n\r",
              (int)R32(27), (int)R32(28), (int)R32(29), (int)R32(30), (int)R32(31));

   while (1) {
      if ((frame % 30) == 0 && bright_ready) bright_log("MMT_FIXED");
      /* ---------------- 读 RTL 证据（每轮都读） ---------------- */
      const uint32_t evt = APB_EVT;
      const uint32_t env = APB_ENV;
      const uint32_t st  = APB_ST;
      const int      motion  = (evt & EVT_MOTION) ? 1 : 0;
      const int      ir_hot  = (evt & EVT_IR_HOT) ? 1 : 0;
      const uint32_t body10  = EVT_BODY_X10(evt);
      const uint32_t area    = EVT_AREA(evt);
      const int32_t  amb10   = (int32_t)(int16_t)(env & 0xFFFFu);
      const uint32_t rh10    = (env >> 16) & 0xFFFFu;
      const int32_t  score   = ST_SCORE(st);
      const int32_t  conf_rtl= ST_CONF(st);
      const int      low_pwr = (int)ST_LOWPWR(st);
      const int      alarm_rtl = (int)ST_ALARM(st);
      const uint32_t vs_cnt  = ST_VSCNT(st);

      {
         const uint32_t sht_sig = (env & 0xFFFFu) ^ ((env >> 16) << 16);
         if (sht_last != 0 && sht_sig != sht_last) sht_upd++;
         sht_last = sht_sig;
         const uint32_t ir_sig = (evt & 0xFu) ^ (body10 << 8);
         if (ir_last_flags != 0 && ir_sig != ir_last_flags) ir_upd++;
         ir_last_flags = ir_sig;
      }

      /* ---------------- 每秒统计窗口 ---------------- */
      const uint64_t t_now = now_ms();
      uint32_t cam_fps = 0, ddr_ar_ps = 0, tinyml_ar_ps = 0, infer_hz = 0;
      if ((t_now - t_win) >= 1000u) {
         const uint32_t dt = (uint32_t)(t_now - t_win);
         const uint32_t dvs = (vs_cnt - vs_last) & 0xFFu;
         cam_fps       = (uint32_t)((uint64_t)dvs * 1000u / dt);
         ddr_ar_ps     = (uint32_t)((uint64_t)ddr_win * 1000u / dt);
         tinyml_ar_ps  = (uint32_t)((uint64_t)tinyml_win * 1000u / dt);
         infer_hz      = (uint32_t)((uint64_t)infer_win * 1000u / dt);
         vs_last = vs_cnt;
         ddr_win = 0; tinyml_win = 0; infer_win = 0;
         t_win = t_now;

         /* v4.1: 每秒刷一次给网页的状态 + 缩略图，并处理 HTTP */
         ge_http_build_json((int)t_now, motion, (int)area, ir_hot, (int)cam_fps,
                            (int)infer_hz, infer_paused, low_pwr,
                            (int)amb10, (int)rh10, (int)body10);
         {
            int q;
            for (q = 0; q < IMG_N; ++q)
               g_thumb[q] = (unsigned char)((int)input_snapshot[q] + 128);
         }
      }
   ge_http_service((int)t_now);
#endif
      {
         const uint32_t ar = R32(2);
         ddr_win += (ar - ddr_ar_last);
         ddr_ar_last = ar;
         const uint32_t tar = R32(4);
         tinyml_win += (tar - tinyml_ar_last);
         tinyml_ar_last = tar;
      }

      /* ---------------- 功能 3：低功耗相机降帧（进入/退出） ---------------- */
#if LP_CAMFPS_ON
      if (g_lp_ready) {
         if (low_pwr && !g_lp_state) {
            const int r = cam_lp_enter(&g_cam_io, &g_lp, LP_VTS_MULT);
            g_lp_state = (r == CAM_OK) ? 1 : 0;
            if (r == CAM_OK) {
               MicroPrintf("MMT_LPCAM enter vts=0x%x->0x%x mult=%d\n\r",
                           g_lp.vts_init, g_lp.vts_init * (unsigned)LP_VTS_MULT, LP_VTS_MULT);
            } else {
               g_lp_ready = 0;
               MicroPrintf("MMT_LPCAM enter FAILED code=%d (disabled)\n\r", r);
            }
         } else if (!low_pwr && g_lp_state) {
            const int r = cam_lp_exit(&g_cam_io, &g_lp);
            g_lp_state = 0;
            if (r == CAM_OK) {
               MicroPrintf("MMT_LPCAM exit vts restored=0x%x\n\r", g_lp.vts_init);
            } else {
               g_lp_ready = 0;
               MicroPrintf("MMT_LPCAM exit FAILED code=%d (disabled)\n\r", r);
            }
         }
      }
#endif

      /* ---------------- ⑤ 低功耗：暂停推理，低频轮询（v15 原样） ---------------- */
#if LOWPOWER_ON
      /* v3.1：活跃判定要和报警同一口径 —— 只有"面积达标"的运动才算有人活动。
         原来用原始 motion，124px 的噪声/AE 抖动就能把系统永久钉在活跃态，
         导致"长时间显示无人却永不进低功耗"（现场实测）。 */
      {
         const int sig_motion = motion && (area >= LP_AREA_MIN) && (area <= AI_AREA_MAX);
         /* v3.4 迟滞：进低功耗门 800，退出门 1500 —— 否则噪声尖峰会让它来回震荡 */
         const int wake_motion = motion && (area >= LP_EXIT_AREA_MIN) && (area <= AI_AREA_MAX);
         /* v3.7：MOT 本帧真的看到人（够大的框）也算"有人在" —— 站着不动的人没有
            area 运动、AI 也可能判无人，原来会被直接降功耗、推理一暂停人就从页面上消失。 */
         const int human_seen = (g_track_conf > 0);
         if (human_seen || sig_motion || last_person) {
            lp_last_active_ms = now_ms();
            if (wake_motion || human_seen) fw_lp = 0;
         } else if ((!fw_lp) && ((now_ms() - lp_last_active_ms) >= LP_ENTER_MS)) {
            fw_lp = 1;
         }
      }
      if (fw_lp || low_pwr) {
         if (!infer_paused) {
            infer_paused = 1;
            ai_reset(); last_person = 0;   /* 进入低功耗清空 AI 历史 */
            lp_entry_cnt++;
            /* v3.4: 不再清 APB_SCORE / APB_OSD —— 每次进出都把屏幕清空再恢复，
               现场看到的是 OSD 一明一灭（"还在闪"）。屏幕保持不动。 */
            lp_enter_ms = now_ms();
            MicroPrintf("MMT_LP_ENTER f=%d cnt=%d ms=%d fw_lp=%d rtl_lp=%d\n\r",
                        (int)frame, lp_entry_cnt, (int)lp_enter_ms, fw_lp, low_pwr);
         }
         dec_update(score, motion, ir_hot, 0, 0, 1, (int32_t)area);   /* v18: LP 中 person=0 */
         APB_OSD = (uint32_t)(alarm_on ? 1u : 0u);                    /* v3.5: 低功耗分支也同步红框 */

         bsp_printf("MMT_LP f=%d lowpwr=%d fw_lp=%d paused=%d camfps=%d inf_hz=%d "
                    "ddr_ar_s=%d tml_ar_s=%d infer=%d sht_upd=%d ir_upd=%d "
                    "sht=%d rh=%d body=%d vts=0x%x vts_ok=%d fallback=%d\n\r",
                    (int)frame, low_pwr, fw_lp, infer_paused, (int)cam_fps, (int)infer_hz,
                    (int)ddr_ar_ps, (int)tinyml_ar_ps, (int)infer_total,
                    (int)sht_upd, (int)ir_upd,
                    (int)amb10, (int)rh10, (int)body10, (unsigned)vts, vts_ok,
                    1 - LP_CAMFPS_ON);
#if LP_CAMFPS_ON
         bsp_printf("MMT_LPCAM state=%d vts=%d mult=%d camfps=%d lowpwr=%d\n\r",
                    g_lp_state, (int)(g_lp_state ? (g_lp.vts_init * (unsigned)LP_VTS_MULT)
                                                 : g_lp.vts_init),
                    g_lp.mult, (int)cam_fps, low_pwr);
#endif
         dec_log(frame, score, motion, ir_hot, area, conf_rtl, alarm_rtl);
         {
            /* Fresh visual evidence while inference remains paused. */
            pp_stats_t thumb_pst;
            sample_frame_box(input_snapshot, &thumb_pst);
            mot_sample_raw();
            mot_track_frame(frame);      /* v30：低功耗下也跟踪，预测到人靠近就提前唤醒 */
            if ((frame % THUMB_DUMP_EVERY) == 0) {
               ga_update(thumb_pst.mean_sensor, 1);
               dump_thumb(0, frame, ai_p_now);
            }
         }
         ++frame;
         delay_ms(LP_POLL_MS);
         continue;
      }
      if (infer_paused) {
         infer_paused = 0;
         lp_exit_cnt++;
         MicroPrintf("MMT_LP_EXIT f=%d cnt=%d ms=%d\n\r", (int)frame, lp_exit_cnt, (int)now_ms());
      }
#endif

      /* ---------------- 正常模式：采样（功能 4 可选）+ 推理 ---------------- */
      pp_stats_t pst;
      const uint32_t chk = sample_frame_box(model_input->data.int8, &pst);
      ga_update(pst.mean_sensor, !(motion || alarm_on || last_person));

      for (int i = 0; i < IMG_N; ++i) input_snapshot[i] = model_input->data.int8[i];
      mot_sample_raw();
      mot_track_frame(frame);            /* v30：多目标跟踪 + 预测（原始传感器值） */
      prepare_model_input(model_input->data.int8, input_snapshot);
      uint32_t bsum = 0;
      for (int i = 0; i < IMG_N; ++i) bsum += (uint8_t)input_snapshot[i];
      const uint32_t b0m = bsum / IMG_N;

      const uint32_t ci0 = R32(6);
      const uint64_t t0 = clint_getTime(BSP_CLINT);
      interpreter->Invoke();
      const uint64_t t1 = clint_getTime(BSP_CLINT);
      const int p = interpreter->output(0)->data.int8[kPersonIndex];
      const int a = interpreter->output(0)->data.int8[kNotAPersonIndex];
      infer_total++;
      infer_win++;

      g_last_ai_p = p;                           /* v1.3：给下一帧 MOT 用 */
      const int person = ai_vote_update(p);      /* v17：p>=-86 且 4 帧 3 真 */
      const int alarm_ai = person;
      /* v3.5: APB_OSD(reg9 bit0) 驱动屏幕红框，改由"报警状态"决定，挪到 dec_update 之后写，
         与网页的 alarm 完全同步。原来这里写的是 person，导致"网页报警中但红框不亮"。 */
      APB_SCORE = 0u;                            /* v17：ai_alive=0，RTL 改用 reg9 的 ai_person */
      bsp_printf("MMT_AI f=%d p=%d th=%d vote=%d/%d person=%d\n\r",
                 (int)frame, p, AI_P_TH, AI_VOTE_K, AI_VOTE_N, person);

      /* ---------------- 功能 2：自动曝光（超范围才动作） ---------------- */
#if AUTOEXP_ON
      if (g_ae_enabled && ((frame % AE_EVAL_FRAMES) == 0)) {
         const int ae_mean = (pst.mean_sensor > 0) ? pst.mean_sensor : (int)b0m;
         const int exp_before = g_ae.exp;
         const int gain_before = g_ae.gain;
         int new_exp = exp_before, new_gain = gain_before;
         const int act = ae_step(&g_ae, ae_mean, &g_ae_cfg, &new_exp, &new_gain);
         if (act > 0) {
            int wr_ok = 1;
            if (new_exp != exp_before && ae_write_exp(new_exp) != 0) wr_ok = 0;
            if (wr_ok && new_gain != gain_before && ae_write_gain(new_gain) != 0) wr_ok = 0;
            if (!wr_ok) {
               g_ae_enabled = 0;
               MicroPrintf("MMT_AE_ERR write/verify failed (AE disabled) mean=%d\n\r", ae_mean);
            } else {
               bsp_printf("MMT_AE mean=%d act=%d exp 0x%x->0x%x gain 0x%x->0x%x\n\r",
                          ae_mean, act, (unsigned)exp_before, (unsigned)new_exp,
                          (unsigned)gain_before, (unsigned)new_gain);
            }
         } else if (act < 0) {
            bsp_printf("MMT_AE mean=%d act=%d saturated exp=0x%x gain=0x%x\n\r",
                       ae_mean, act, (unsigned)g_ae.exp, (unsigned)g_ae.gain);
         }
      }
#endif

      /* ---------------- ② v18 决策：运动触发 + AI 确认 ---------------- */
      g_frame = frame;
      last_person = person;
      dec_update(score, motion, ir_hot, 1, person, 0, (int32_t)area);
      APB_OSD = (uint32_t)(alarm_on ? 1u : 0u);   /* v3.5: 红框 = 报警状态（与网页同步） */
      mot_lead_check(frame);

      char raw[3];
      const uint8_t pb = (uint8_t)p;
      raw[0] = HEXD[pb >> 4];
      raw[1] = HEXD[pb & 0x0Fu];
      raw[2] = 0;

      bsp_printf("MMT_OSD f=%d chk=%x p=%d a=%d v=%d osd=%d ci=%d ms=%d b0m=%d raw=%s\n\r",
                 (int)frame, chk, p, a, alarm_ai, alarm_ai,
                 (int)(R32(6) - ci0),
                 (int)((t1 - t0) / (SYSTEM_CLINT_HZ / 1000)),
                 (int)b0m, raw);
#if (CROP_MODE || NORM_ON || STRETCH_ON)
      bsp_printf("MMT_PP crop=%d norm=%d stretch=%d gain_x100=%d mean_sensor=%d "
                 "mean_in=%d mean_out=%d lo=%d hi=%d\n\r",
                 pst.crop_mode, pst.norm_applied, pst.stretch_applied,
                 pst.gain_x100, pst.mean_sensor, pst.mean_in, pst.mean_out,
                 pst.stretch_lo, pst.stretch_hi);
#endif
      dec_log(frame, score, motion, ir_hot, area, conf_rtl, alarm_rtl);
      bsp_printf("MMT_LP f=%d lowpwr=%d fw_lp=%d paused=%d camfps=%d inf_hz=%d "
                 "ddr_ar_s=%d tml_ar_s=%d infer=%d sht_upd=%d ir_upd=%d "
                 "sht=%d rh=%d body=%d vts=0x%x vts_ok=%d fallback=%d\n\r",
                 (int)frame, low_pwr, fw_lp, infer_paused, (int)cam_fps, (int)infer_hz,
                 (int)ddr_ar_ps, (int)tinyml_ar_ps, (int)infer_total,
                 (int)sht_upd, (int)ir_upd,
                 (int)amb10, (int)rh10, (int)body10, (unsigned)vts, vts_ok,
                 1 - LP_CAMFPS_ON);

#if MOT_EXTRA_POLLS > 0
      /* v1.7 提高跟踪频率：AI 推理约 2 Hz，人走快时两帧位移太大容易换 ID。
         推理结束后再插几次"采样 + MOT"，用同一帧缓冲拿到更新的画面（不重复推理）。 */
      for (int mp = 0; mp < MOT_EXTRA_POLLS; ++mp) {
         delay_ms(MOT_EXTRA_MS);
         mot_sample_raw();
         mot_track_frame(frame);
      }
#endif
      if ((frame % IMG_DUMP_EVERY) == 0) {
         dump_image(input_snapshot, frame, p);
      }
      if ((frame % THUMB_DUMP_EVERY) == 0) {
         dump_thumb(0, frame, p);
      }
      ++frame;
   }
}
