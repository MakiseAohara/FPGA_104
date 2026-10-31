////////////////////////////////////////////////////////////////////////////////
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
#define CROP_MODE        1       /* v17 默认 crop1：0=整幅 1=中间正方形 2=中间 1.5 倍宽 */
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
#define LP_CAMFPS_ON     1       /* v29.2: 低功耗降帧默认开启（任务书 ⑤）；写失败自动关闭并恢复 */
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
#define IR_NEED          2
#define IR_OFF_WIN       15
#define IR_SOLO_ON       1       /* v29.1: 红外单模态直通（不要求运动候选） */
#define IR_SOLO_N        6       /* 最近 IR_SOLO_N 个样本 ir_hot 全为 1 即触发 */
#define AI_P_STRONG      60
#define AI_P_OFF         (-40)
#define REL_QUIET_FRAMES 6      /* v29.3: 连续无候选帧数达到此值即可解除报警 */
#define AI_AREA_MIN      200     /* 运动面积门限：压制全局亮变/AGC 型大 motion */
#define AI_AREA_MAX      20000
#define DEC_CAND_FRAMES  6
#define DEC_RELEASE_FRAMES 3     /* 连续无运动且无 AI 的解除计数（≈1.6s） */
#define DEC_WARMUP       2
#define LP_ENTER_MS      10000   /* ⑤：连续 10s 无运动/无 AI 进入低功耗 */
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
#define THUMB_DUMP_EVERY 2   /* v30e2：缩略图每 2 帧一张，采集容错 */
#define THUMB_W 48

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
      if (ai_hist[i] <  AI_P_OFF) off++;
   }
   rel_cnt = off;
   g_person_off = (ai_fill >= AI_VOTE_N && off == AI_VOTE_N) ? 1 : 0;
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
      const int fusion = (cand_left > 0) &&
                         ((ir_cnt10 >= IR_NEED) || (ai_p_now >= AI_P_STRONG && ir_cnt10 >= 1));
      int solo   = (IR_SOLO_ON && (ir_cnt6 >= IR_SOLO_N)) ? 1 : 0;
#if HOTSRC_EXCL
      /* v29.2 热源排除：红外持续偏热但 AI 连续 AI_VOTE_N 次都判"无人"（p<AI_P_OFF），
         且没有运动候选 → 判为静态热源（水杯/电脑/暖风），不触发单模态报警。 */
      if (solo && !fusion && g_person_off) {
         solo = 0;
         g_hotsrc_cnt++;
         if ((g_hotsrc_cnt & 0x0F) == 1)
            bsp_printf("MMT_HOTSRC suppressed ms=%d f=%d cnt=%d ai_p=%d ir_cnt6=%d\n\r",
                       (int)now, (int)g_frame, (int)g_hotsrc_cnt, ai_p_now, ir_cnt6);
      }
#endif
      if (fusion || solo) {
         alarm_on = 1; alarm_frames = 0;
         alarm_start_ms = (int)now;
         bsp_printf("MMT_ALARM start ms=%d f=%d person=%d motion=%d area=%d cause=%s\n\r",
                    (int)now, (int)g_frame, person, motion, (int)area,
                    (solo && !fusion) ? "ir_solo" : "fusion");
      }
   } else {
      alarm_frames++;
      if (infer_ran && g_person_off && (ir_cnt15 == 0 || quiet_cnt >= REL_QUIET_FRAMES)) { /* v28: all 15 IR clear and all 3 AI off */
           bsp_printf("MMT_ALARM end ms=%d f=%d dur_ms=%d\n\r",
                      (int)now, (int)g_frame, (int)now - alarm_start_ms);
           alarm_on = 0;
        }
   }
   if (low_pwr_now && alarm_on) {
      bsp_printf("MMT_ALARM end ms=%d f=%d dur_ms=%d reason=lowpwr\n\r",
                 (int)now, (int)g_frame, (int)now - alarm_start_ms);
      alarm_on = 0; rel_cnt = 0;
   }

   if (alarm_on) dec_evt = 1;
   else if (person) dec_evt = 3;
   else if (low_pwr_now) dec_evt = 4;
   else dec_evt = 0;

#if FW_DECISION_ON
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
      if (t->supported && t->hits >= 1 && t->eta >= 0 && t->eta <= (MOT_HORIZON + 3) && !g_mot.shaking
#if MOT_V15_ENTRY
       && (t->confirmed || t->edge_entry) && t->pre_ok >= MOT_PRE_OK_N
#endif
      ) {
         pre = 1;
         if (eta < 0 || (int)t->eta < eta) { eta = (int)t->eta; id = (int)t->id; }
      }
   }
   g_track_conf = mot_active_confirmed(&g_mot);
   bsp_printf("MMT_MOT f=%d nd=%d nt=%d conf=%d area=%d raw=%d pre=%d pre_eta=%d\n\r",
              (int)frame, g_mot.n_det, g_mot.n_trk, nconf, g_mot.last_area,
              g_mot.raw_area, pre, eta);

#if MOT_PRE_ON
   if (pre && !g_pre_on) {
      g_pre_on = 1; g_pre_id = id; g_pre_eta = eta; g_pre_ms = (uint32_t)now_ms();
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
   static char pixels[THUMB_W * THUMB_W * 2 + 1];
   int offset = 0;
   for (int y = 0; y < THUMB_W; ++y) {
      for (int x = 0; x < THUMB_W; ++x) {
         const int i = (y * 2) * 96 + x * 2;
         const unsigned sum = (uint8_t)img[i] + (uint8_t)img[i + 1]
                            + (uint8_t)img[i + 96] + (uint8_t)img[i + 97];
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
#define WB_B             0x1A4    /* 1.640625x（v29.2 本轮默认值） */
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

   MicroPrintf("MMT_MOT_CFG ver=v30 on=%d pre=%d diff=%d min_area=%d max_area=%d "
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
#endif

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
      }
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
      if (motion || last_person) {
         lp_last_active_ms = now_ms();
         if (motion) fw_lp = 0;
      } else if ((!fw_lp) && ((now_ms() - lp_last_active_ms) >= LP_ENTER_MS)) {
         fw_lp = 1;
      }
      if (fw_lp || low_pwr) {
         if (!infer_paused) {
            infer_paused = 1;
            ai_reset(); last_person = 0;   /* 进入低功耗清空 AI 历史 */
            lp_entry_cnt++;
            APB_SCORE = 0;
            APB_OSD   = 0;
            lp_enter_ms = now_ms();
            MicroPrintf("MMT_LP_ENTER f=%d cnt=%d ms=%d fw_lp=%d rtl_lp=%d\n\r",
                        (int)frame, lp_entry_cnt, (int)lp_enter_ms, fw_lp, low_pwr);
         }
         dec_update(score, motion, ir_hot, 0, 0, 1, (int32_t)area);   /* v18: LP 中 person=0 */

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
               dump_thumb(input_snapshot, frame, ai_p_now);
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
      APB_OSD = (uint32_t)person;
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
         dump_thumb(input_snapshot, frame, p);
      }
      ++frame;
   }
}