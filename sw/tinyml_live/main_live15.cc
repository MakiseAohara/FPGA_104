////////////////////////////////////////////////////////////////////////////////
// main_live15.cc — MERGE11 固件：② RISC-V 历史决策 + ⑤ 低功耗场景管理
//
// 基线：main_live14.cc（Bayer 采样几何 / 96x96 / 硬件推理 / APB reg9,10 OSD）
// 新增（全部通过 MERGE11 RTL 新增的 APB 字 11..15）：
//
//  ② RISC-V 软核决策控制（FW_DECISION_ON）
//     - 读字 11（运动/红外摘要）、字 12（环境）、字 13（RTL 融合得分/置信度/
//       低功耗状态/报警状态/视频帧计数）
//     - 历史统计：滑动窗口均值、上升斜率（趋势）、连续确认、迟滞、事件分类
//     - 决策结果写字 14（alarm_req / 置信度 / 事件类型）
//     - 写字 15 bit0=1 使能"固件决策门控"：最终报警 = RTL 报警 & 固件 alarm_req；
//       bit0=0 时 RTL 行为与 MERGE10 完全一致（复位默认 0）
//
//  ⑤ 低功耗场景管理（LOWPOWER_ON）
//     - 读字 13 bit17 = RTL v7_pwr_ctl 的 low_pwr（无人约 15 s 进入）
//     - low_pwr=1：暂停神经网络推理（每 500 ms 只做一次证据读取 + 决策更新），
//       并把 reg9/reg10 清零让 RTL 视觉输入退回运动检测；
//       温度监测由 RTL 传感器子系统保持（SHT30 1 Hz / MLX90640 2 Hz），
//       固件通过字 11/12 的数值变化在日志中证明它仍在更新
//     - low_pwr=0：立即恢复推理并重新开始写 reg9/reg10
//     - 相机降帧（VTS）未启用：开机 ROM 表 i2c_master_reg_rom.v 中没有
//       0x320e/0x320f（已逐行核对，0 命中），按任务约定退回"只暂停推理"。
//       固件仍通过 MERGE10 的 APB 字16/17/18 读一次相机 VTS 当前值用于日志。
//
//  量化指标（MMT_LP 行）：相机帧率（字13[31:24] 视频帧计数）、推理次数/秒、
//  DDR 读事务/秒（字2 soc_ar_cnt、字4 t_ar_cnt）、传感器更新计数、VTS 读回值。
//
//  宏开关：FW_DECISION_ON=0 关闭 ②（不写 14/15，RTL 保持 MERGE10 行为）
//          LOWPOWER_ON=0   关闭 ⑤（不暂停推理，只记录 low_pwr 状态）
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

// ------------------------- compile-time switches -------------------------
#ifndef FW_DECISION_ON
#define FW_DECISION_ON   1       /* ② 固件决策门控（写 APB 字14/15） */
#endif
#ifndef LOWPOWER_ON
#define LOWPOWER_ON      1       /* ⑤ 低功耗：暂停推理 + 低频轮询 */
#endif

// ------------------------- ② decision parameters -------------------------
#define DEC_WIN          8       /* 滑动窗口长度（样本 = 一次主循环） */
#define DEC_CONSEC       3       /* 连续多少帧窗口均值 >= TH_ON 才确认报警 */
#define DEC_TH_ON        140     /* 报警置位阈值（RTL 融合得分 0..511） */
#define DEC_TH_OFF       70      /* 报警解除阈值（迟滞） */
#define DEC_TREND_TH     10      /* 上升斜率阈值：得分/样本 */
#define DEC_TREND_MIN    60      /* 趋势预警的最低窗口均值 */
#define DEC_WARMUP       2       /* 采集多少个样本后才使能固件决策门控 */
#define DEC_SLOPE_HALF   4       /* 斜率用最近半窗与最早半窗之差计算 */

// ------------------------- ⑤ low-power parameters -------------------------
#define LP_POLL_MS       500     /* 低功耗期间轮询间隔 */

// ------------------------- geometry (与 v14 相同) -------------------------
#define FB_BASE      0x01000000u
#define FB_FRAME_LEN (960u * 1080u * 4u + 0x200u)
#define LIVE_BANK    2

#define FB_ROW_BYTES 1920u
#define FB_W_REAL    1920u
#define FB_H_REAL    1080u

#define BOX          3

#ifndef INPUT_SUB128
#define INPUT_SUB128 0
#endif

// ------------------------- APB map (MERGE11) -------------------------
#define APB_BASE      0xF8100000u
#define R32(n)        (*(volatile uint32_t*)(APB_BASE + 4u * (n)))

#define APB_OSD       R32(9)     /* W: bit0 = AI 判决（OSD 红框） */
#define APB_SCORE     R32(10)    /* W: 0x100|int8(p)  AI 原始得分 */
#define APB_EVT       R32(11)    /* R: word11 motion/IR 摘要 */
#define APB_ENV       R32(12)    /* R: word12 环境温湿度 */
#define APB_ST        R32(13)    /* R: word13 RTL 融合/低功耗/报警/帧计数 */
#define APB_DEC       R32(14)    /* W: word14 固件决策结果 */
#define APB_CTRL      R32(15)    /* W: word15 固件控制 */
#define APB_I2C_CMD   R32(16)    /* W: bit31 start, bit30 rw, [23:8] reg addr */
#define APB_I2C_ST    R32(17)    /* R: bit0 busy, bit1 done(读清), bit2 ready */
#define APB_I2C_RD    R32(18)    /* R: [7:0] last read data */

// word11 bit fields
#define EVT_MOTION    (1u << 0)
#define EVT_IR_HOT    (1u << 1)
#define EVT_IR_VALID  (1u << 2)
#define EVT_SHT_SEEN  (1u << 3)
#define EVT_BODY_X10(w)  (((w) >> 4) & 0xFFFu)
#define EVT_AREA(w)      (((w) >> 16) & 0xFFFFu)

// word13 bit fields
#define ST_SCORE(w)   ((int32_t)((w) & 0x1FFu))
#define ST_CONF(w)    ((int32_t)(((w) >> 9) & 0xFFu))
#define ST_LOWPWR(w)  (((w) >> 17) & 1u)
#define ST_ALARM(w)   (((w) >> 18) & 1u)
#define ST_FWEN(w)    (((w) >> 19) & 1u)
#define ST_AIEN(w)    (((w) >> 20) & 1u)
#define ST_VSCNT(w)   (((w) >> 24) & 0xFFu)

#define IMG_N        (96 * 96)
#define IMG_DUMP_EVERY 40

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
// 相机 SCCB 读（MERGE10 APB 字16/17/18 通路；只读，不改 ROM 序列）
// ===========================================================================
static int cam_wait_ready(uint32_t timeout_ms)
{
   const uint64_t t0 = now_ms();
   while ((now_ms() - t0) < timeout_ms) {
      const uint32_t st = APB_I2C_ST;
      if (((st & 1u) == 0u) && ((st & 4u) != 0u)) return 0;   /* !busy && ready */
   }
   return -1;
}

static int cam_read_reg(uint16_t reg, uint8_t* out)
{
   if (cam_wait_ready(200)) return -1;
   APB_I2C_CMD = (1u << 31) | (1u << 30) | ((uint32_t)reg << 8);
   const uint64_t t0 = now_ms();
   while ((now_ms() - t0) < 20) {
      const uint32_t st = APB_I2C_ST;
      if (st & 2u) {                       /* done */
         *out = (uint8_t)(APB_I2C_RD & 0xFFu);
         return 0;
      }
   }
   return -1;
}

// 读相机 VTS = {0x320e[6:0], 0x320f}（SC431HAI 手册 §2.7 帧长；默认 0x05dc）
static uint32_t cam_read_vts(int* ok)
{
   uint8_t hi = 0, lo = 0;
   if (cam_read_reg(0x320E, &hi) || cam_read_reg(0x320F, &lo)) {
      *ok = 0;
      return 0;
   }
   *ok = 1;
   return ((uint32_t)(hi & 0x7Fu) << 8) | (uint32_t)lo;
}

// ===========================================================================
// 帧缓冲采样（与 v14 完全一致：原始 Bayer，1 B/px，2x2 均值 + BOX 点盒式）
// ===========================================================================
static inline uint32_t quad_mean(uint32_t base, uint32_t x, uint32_t y)
{
   const volatile uint8_t* p =
         (const volatile uint8_t*)(base + y * FB_ROW_BYTES + x);
   const uint32_t a = p[0];
   const uint32_t b = p[1];
   const uint32_t c = p[FB_ROW_BYTES];
   const uint32_t d = p[FB_ROW_BYTES + 1];
   return (a + b + c + d) >> 2;
}

static uint32_t sample_frame_box(int8_t* out)
{
   const uint32_t base = FB_BASE + (uint32_t)LIVE_BANK * FB_FRAME_LEN;
   uint32_t sum = 0;

   for (uint32_t oy = 0; oy < 96; ++oy) {
      for (uint32_t ox = 0; ox < 96; ++ox) {
         const uint32_t bx = ox * 20u;
         uint32_t acc = 0;
         for (uint32_t j = 0; j < BOX; ++j) {
            uint32_t sy = (oy * 45u + (j * 45u) / BOX) / 4u;
            sy &= ~1u;
            if (sy > FB_H_REAL - 2u) sy = FB_H_REAL - 2u;
            for (uint32_t i = 0; i < BOX; ++i) {
               uint32_t sx = bx + (i * 20u) / BOX;
               sx &= ~1u;
               if (sx > FB_W_REAL - 2u) sx = FB_W_REAL - 2u;
               acc += quad_mean(base, sx, sy);
            }
         }
         const uint32_t v = acc / (BOX * BOX);
#if INPUT_SUB128
         out[oy * 96 + ox] = (int8_t)((int32_t)v - 128);
#else
         out[oy * 96 + ox] = (int8_t)v;
#endif
         sum += (uint8_t)out[oy * 96 + ox];
      }
   }
   return sum;
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
// ② 历史决策状态
// ===========================================================================
static int32_t  dec_hist[DEC_WIN];
static int      dec_idx = 0, dec_filled = 0, dec_total = 0;
static int32_t  dec_mean = 0, dec_slope = 0;
static int      dec_consec = 0, dec_alarm = 0, dec_evt = 0, dec_trend = 0;

static int32_t clamp_i32(int32_t v, int32_t lo, int32_t hi)
{
   if (v < lo) return lo;
   if (v > hi) return hi;
   return v;
}

// 返回 1 = 本次更新后固件报警有效
static int dec_update(int32_t score, int motion, int ir_hot, int infer_ran)
{
   /* 1) 滑动窗口 */
   dec_hist[dec_idx] = score;
   dec_idx = (dec_idx + 1) % DEC_WIN;
   if (dec_filled < DEC_WIN) dec_filled++;
   if (dec_total < 0x7FFFFFFF) dec_total++;

   int32_t sum = 0;
   for (int i = 0; i < dec_filled; ++i) sum += dec_hist[i];
   dec_mean = sum / dec_filled;

   /* 2) 上升斜率：最近半窗均值 − 最早半窗均值（按样本数归一） */
   dec_slope = 0;
   if (dec_filled >= DEC_SLOPE_HALF * 2) {
      int32_t s_new = 0, s_old = 0;
      for (int i = 0; i < DEC_SLOPE_HALF; ++i) {
         const int n_new = (dec_idx - 1 - i + DEC_WIN) % DEC_WIN;
         const int n_old = (dec_idx - dec_filled + i + DEC_WIN * 2) % DEC_WIN;
         s_new += dec_hist[n_new];
         s_old += dec_hist[n_old];
      }
      dec_slope = (s_new - s_old) / DEC_SLOPE_HALF;
   }

   /* 3) 趋势预警（得分上升斜率 + 最低均值） */
   dec_trend = ((dec_slope >= DEC_TREND_TH) && (dec_mean >= DEC_TREND_MIN)) ? 1 : 0;

   /* 4) 连续确认 + 迟滞 */
   if (dec_mean >= DEC_TH_ON) {
      if (dec_consec < 0x7FFF) dec_consec++;
   } else {
      dec_consec = 0;
   }
   if (!dec_alarm && (dec_consec >= DEC_CONSEC)) dec_alarm = 1;
   else if (dec_alarm && (dec_mean <= DEC_TH_OFF)) { dec_alarm = 0; dec_consec = 0; }

   /* 5) 事件分类：1=入侵（运动+红外热点+确认）2=上升趋势预警 0=无 */
   if (dec_alarm && motion && ir_hot)      dec_evt = 1;
   else if (dec_trend)                    dec_evt = 2;
   else                                   dec_evt = 0;

   /* 6) 决策输出到 RTL（字 14 / 15） */
#if FW_DECISION_ON
   const int32_t conf = clamp_i32(dec_mean * 100 / 511, 0, 100);
   APB_DEC  = (uint32_t)(dec_alarm ? 1u : 0u) |
              ((uint32_t)conf << 8) |
              ((uint32_t)(dec_evt & 0xFF) << 16);
   {
      const int fw_en = (dec_total >= DEC_WARMUP) ? 1 : 0;
      APB_CTRL = (uint32_t)(fw_en ? 1u : 0u) |
                 (uint32_t)((infer_ran ? 1u : 0u) << 1);
   }
#endif
   return dec_alarm;
}

// ===========================================================================
// 日志：MMT_DEC（② 每帧决策明细）
// ===========================================================================
static void dec_log(uint32_t frame, int32_t score, int motion, int ir_hot,
                    uint32_t area, int32_t conf_rtl, int alarm_rtl)
{
   const int fw_en = (dec_total >= DEC_WARMUP) ? 1 : 0;
   bsp_printf("MMT_DEC f=%d score=%d mean=%d slope=%d con=%d trend=%d evt=%d "
              "alarm_req=%d conf=%d motion=%d irhot=%d area=%d rtl_conf=%d "
              "rtl_alarm=%d fw_en=%d win=%d\n\r",
              (int)frame, (int)score, (int)dec_mean, (int)dec_slope,
              dec_consec, dec_trend, dec_evt, dec_alarm,
              (int)clamp_i32(dec_mean * 100 / 511, 0, 100),
              motion, ir_hot, (int)area, (int)conf_rtl, alarm_rtl,
              fw_en, dec_filled);
}

// ===========================================================================
// 主函数
// ===========================================================================
extern "C" int main()
{
   MicroPrintf("MMT_LIVE_BOOT v15_merge11 FW_DEC=%d LOWPOWER=%d\n\r",
               FW_DECISION_ON, LOWPOWER_ON);
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

   /* 相机 VTS 只读一次（用于 ⑤ 日志；ROM 表无此寄存器 ⇒ 不做降帧） */
   int     vts_ok = 0;
   uint32_t vts = cam_read_vts(&vts_ok);
   MicroPrintf("MMT_CAM_VTS ok=%d vts=0x%04x rom_vts=0 fallback=1\n\r",
               vts_ok, (unsigned)vts);

   uint32_t frame = 0;
   uint32_t infer_total = 0, infer_win = 0;
   int      infer_paused = 0;
   int      last_p = -128;
   uint32_t sht_last = 0, sht_upd = 0;
   uint32_t ir_last_flags = 0, ir_upd = 0;
   uint32_t ddr_ar_last = 0, tinyml_ar_last = 0, ddr_win = 0, tinyml_win = 0;
   uint32_t vs_last = 0, fps_win = 0;
   uint64_t t_win = now_ms();
   uint32_t lp_entry_cnt = 0, lp_exit_cnt = 0;

   while (1) {
      /* ---------------- 读 RTL 证据（每轮都读） ---------------- */
      const uint32_t evt = APB_EVT;
      const uint32_t env = APB_ENV;
      const uint32_t st  = APB_ST;
      const int      motion  = (evt & EVT_MOTION) ? 1 : 0;
      const int      ir_hot  = (evt & EVT_IR_HOT) ? 1 : 0;
      const int      ir_val  = (evt & EVT_IR_VALID) ? 1 : 0;
      const int      sht_seen= (evt & EVT_SHT_SEEN) ? 1 : 0;
      const uint32_t body10  = EVT_BODY_X10(evt);
      const uint32_t area    = EVT_AREA(evt);
      const int32_t  amb10   = (int32_t)(int16_t)(env & 0xFFFFu);
      const uint32_t rh10    = (env >> 16) & 0xFFFFu;
      const int32_t  score   = ST_SCORE(st);
      const int32_t  conf_rtl= ST_CONF(st);
      const int      low_pwr = (int)ST_LOWPWR(st);
      const int      alarm_rtl = (int)ST_ALARM(st);
      const uint32_t vs_cnt  = ST_VSCNT(st);

      /* 传感器更新计数（证明低功耗期间温度监测仍在跑） */
      {
         const uint32_t sht_sig = (env & 0xFFFFu) ^ ((env >> 16) << 16);
         if (sht_last != 0 && sht_sig != sht_last) sht_upd++;
         sht_last = sht_sig;
         const uint32_t ir_sig = (evt & 0xFu) ^ (body10 << 8);
         if (ir_last_flags != 0 && ir_sig != ir_last_flags) ir_upd++;
         ir_last_flags = ir_sig;
      }

      /* ---------------- 每秒统计窗口（帧率 / DDR / 推理） ---------------- */
      const uint64_t t_now = now_ms();
      uint32_t cam_fps = 0, ddr_ar_ps = 0, tinyml_ar_ps = 0, infer_hz = 0;
      if ((t_now - t_win) >= 1000u) {
         const uint32_t dt = (uint32_t)(t_now - t_win);
         const uint32_t dvs = (vs_cnt - vs_last) & 0xFFu;   /* 8 位回绕 */
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

      /* ---------------- ⑤ 低功耗：暂停推理，低频轮询 ---------------- */
#if LOWPOWER_ON
      if (low_pwr) {
         if (!infer_paused) {
            infer_paused = 1;
            lp_entry_cnt++;
            APB_SCORE = 0;      /* ai_alive=0：RTL 视觉输入退回运动检测 */
            APB_OSD   = 0;
            MicroPrintf("MMT_LP_ENTER f=%d lp=%d\n\r", (int)frame, lp_entry_cnt);
         }
         /* 低功耗期间仍更新 ② 决策（RTL 融合与温度监测不停） */
         dec_update(score, motion, ir_hot, 0);

         bsp_printf("MMT_LP f=%d lowpwr=%d paused=%d camfps=%d inf_hz=%d "
                    "ddr_ar_s=%d tml_ar_s=%d infer=%d sht_upd=%d ir_upd=%d "
                    "sht=%d rh=%d body=%d vts=0x%04x vts_ok=%d fallback=1\n\r",
                    (int)frame, low_pwr, infer_paused, (int)cam_fps, (int)infer_hz,
                    (int)ddr_ar_ps, (int)tinyml_ar_ps, (int)infer_total,
                    (int)sht_upd, (int)ir_upd,
                    (int)amb10, (int)rh10, (int)body10, (unsigned)vts, vts_ok);
         dec_log(frame, score, motion, ir_hot, area, conf_rtl, alarm_rtl);
         ++frame;                    /* 低功耗期间也推进帧号，便于日志对齐 */
         delay_ms(LP_POLL_MS);
         continue;
      }
      if (infer_paused) {
         infer_paused = 0;
         lp_exit_cnt++;
         MicroPrintf("MMT_LP_EXIT f=%d lp=%d\n\r", (int)frame, lp_exit_cnt);
      }
#endif

      /* ---------------- 正常模式：采样 + 推理 + 写 AI 证据 ---------------- */
      const uint32_t chk = sample_frame_box(model_input->data.int8);

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
      last_p = p;
      infer_total++;
      infer_win++;

      const int alarm_ai = (p > 0) ? 1 : 0;
      APB_OSD = (uint32_t)alarm_ai;
      APB_SCORE = 0x100u | (uint32_t)(uint8_t)p;

      /* ---------------- ② 历史决策更新 ---------------- */
      dec_update(score, motion, ir_hot, 1);

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
      dec_log(frame, score, motion, ir_hot, area, conf_rtl, alarm_rtl);
      bsp_printf("MMT_LP f=%d lowpwr=%d paused=%d camfps=%d inf_hz=%d "
                 "ddr_ar_s=%d tml_ar_s=%d infer=%d sht_upd=%d ir_upd=%d "
                 "sht=%d rh=%d body=%d vts=0x%04x vts_ok=%d fallback=1\n\r",
                 (int)frame, low_pwr, infer_paused, (int)cam_fps, (int)infer_hz,
                 (int)ddr_ar_ps, (int)tinyml_ar_ps, (int)infer_total,
                 (int)sht_upd, (int)ir_upd,
                 (int)amb10, (int)rh10, (int)body10, (unsigned)vts, vts_ok);

      if ((frame % IMG_DUMP_EVERY) == 0) {
         dump_image(input_snapshot, frame, p);
      }
      ++frame;
   }
}
