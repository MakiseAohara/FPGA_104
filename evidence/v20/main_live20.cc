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

#include "model/mobilenetv1_person_detect_model_data.h"
#include "model/model_settings.h"

#include "preprocess_core.h"
#include "ae_core.h"
#include "cam_ctrl_core.h"

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
#define AUTOEXP_ON 1
#endif
#ifndef LP_CAMFPS_ON
#define LP_CAMFPS_ON     0
#endif
#ifndef FW_DECISION_ON
#define FW_DECISION_ON   1       /* v15 默认 */
#endif
#ifndef LOWPOWER_ON
#define LOWPOWER_ON      1       /* v15 默认 */
#endif
#ifndef INPUT_SUB128
#define INPUT_SUB128     0
#endif

// 功能 2 参数
#ifndef AE_EVAL_FRAMES
#define AE_EVAL_FRAMES 16
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
#define AI_P_STRONG      60
#define AI_P_OFF         (-40)
#define AI_AREA_MIN      200     /* 运动面积门限：压制全局亮变/AGC 型大 motion */
#define AI_AREA_MAX      4000
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
#define IMG_DUMP_EVERY 5

namespace {
   tflite::ErrorReporter* error_reporter = nullptr;
   const tflite::Model* model = nullptr;
   tflite::MicroInterpreter* interpreter = nullptr;
   TfLiteTensor* model_input = nullptr;
   constexpr int kTensorArenaSize = 136 * 1024;
   uint8_t tensor_arena[kTensorArenaSize];
   int8_t input_snapshot[IMG_N];
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
#if INPUT_SUB128
   sum = 0;
   for (int i = 0; i < IMG_N; ++i) {
      out[i] = (int8_t)((int)out[i] - 128);
      sum += (uint8_t)out[i];
   }
#endif
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
static int alarm_on = 0, alarm_start_ms = 0, alarm_frames = 0;
static int cand_left = 0, rel_cnt = 0, dec_evt = 0, dec_conf = 0;
static int fw_lp = 0;
static uint64_t lp_last_active_ms = 0, lp_enter_ms = 0;

static int clamp_i32(int32_t v, int32_t lo, int32_t hi)
{
   if (v < lo) return lo;
   if (v > hi) return hi;
   return v;
}

static int ai_p_now = -128, g_person_off = 0;

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
   const int cand = motion && (area >= AI_AREA_MIN) && (area <= AI_AREA_MAX);
   if (cand) cand_left = DEC_CAND_FRAMES;
   else if (cand_left > 0) cand_left--;

   const uint64_t now = now_ms();
   if (!alarm_on) {
      if (person && ((cand_left > 0) || (ai_p_now >= AI_P_STRONG))) {
         alarm_on = 1; alarm_frames = 0;
         alarm_start_ms = (int)now;
         bsp_printf("MMT_ALARM start ms=%d f=%d person=%d motion=%d area=%d\n\r",
                    (int)now, (int)g_frame, person, motion, (int)area);
      }
   } else {
      alarm_frames++;
      if (infer_ran && g_person_off) {   /* 解除只看 AI，与运动无关 */
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

static void dec_log(uint32_t frame, int32_t score, int motion, int ir_hot,
                    uint32_t area, int32_t conf_rtl, int alarm_rtl)
{
   bsp_printf("MMT_DEC t=%d f=%d score=%d mean=%d slope=0 con=%d trend=0 evt=%d "
              "alarm_req=%d conf=%d motion=%d irhot=%d area=%d rtl_conf=%d "
              "rtl_alarm=%d cand=%d rel=%d person=%d\n\r",
              (int)now_ms(), (int)frame, (int)score, (int)score, cand_left, dec_evt,
              alarm_on, (alarm_on ? 100 : (last_person ? 60 : 0)), motion, ir_hot,
              (int)area, (int)conf_rtl, alarm_rtl, cand_left, rel_cnt, last_person);
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

void tinyml_init()
{
   static tflite::MicroErrorReporter reporter;
   error_reporter = &reporter;
   model = tflite::GetModel(mobilenetv1_person_detect_model_data);
   if (model->version() != TFLITE_SCHEMA_VERSION) {
      MicroPrintf("MMT_LIVE_FAIL MODEL_VERSION\n\r");
      while (1) {}
   }
   static tflite::MicroMutableOpResolver<5> resolver;
   resolver.AddAveragePool2D();
   resolver.AddConv2D();
   resolver.AddDepthwiseConv2D();
   resolver.AddReshape();
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
   MicroPrintf("MMT_LIVE_BOOT v20 CROP=%d NORM=%d STRETCH=%d AE=%d LPCAM=%d "
               "FW_DEC=%d LOWPOWER=%d\n\r",
               CROP_MODE, NORM_ON, STRETCH_ON, AUTOEXP_ON, LP_CAMFPS_ON,
               FW_DECISION_ON, LOWPOWER_ON);
   MicroPrintf("MMT_CFG v20 CROP_MODE=%d NORM_ON=%d STRETCH_ON=%d AUTOEXP_ON=%d "
               "LP_CAMFPS_ON=%d LP_VTS_MULT=%d FW_DECISION_ON=%d LOWPOWER_ON=%d "
               "INPUT_SUB128=%d AI_P_TH=%d AI_VOTE=%d/%d AREA=[%d,%d] DEC_CAND=%d\n\r",
               CROP_MODE, NORM_ON, STRETCH_ON, AUTOEXP_ON, LP_CAMFPS_ON,
               LP_VTS_MULT, FW_DECISION_ON, LOWPOWER_ON, INPUT_SUB128,
               AI_P_TH, AI_VOTE_K, AI_VOTE_N, AI_AREA_MIN, AI_AREA_MAX, DEC_CAND_FRAMES);

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
   if (AUTOEXP_ON || LP_CAMFPS_ON) {
      if (cam_boot_read_all() == 0) {
         cam_boot_log();
      } else {
         MicroPrintf("MMT_CAM_ERR boot read failed (AE/LPCAM disabled)\n\r");
      }
   }

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

      for (int i = 0; i < IMG_N; ++i) input_snapshot[i] = model_input->data.int8[i];
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

      const int person = ai_vote_update(p);      /* v17：p>=-86 且 4 帧 3 真 */
      const int alarm_ai = person;
      APB_OSD = (uint32_t)person;
      APB_SCORE = 0u;                            /* v17：ai_alive=0，RTL 改用 reg9 的 ai_person */
      bsp_printf("MMT_AI f=%d p=%d th=%d vote=%d/%d person=%d\n\r",
                 (int)frame, p, AI_P_TH, AI_VOTE_K, AI_VOTE_N, person);

      /* ---------------- 功能 2：自动曝光（超范围才动作） ---------------- */
#if AUTOEXP_ON
      if (g_ae_enabled && ((frame % AE_EVAL_FRAMES) == 0) && !motion && !alarm_on && !person) {
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

      if ((frame % IMG_DUMP_EVERY) == 0) {
         dump_image(input_snapshot, frame, p);
      }
      ++frame;
   }
}
