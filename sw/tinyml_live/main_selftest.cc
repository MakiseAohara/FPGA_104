////////////////////////////////////////////////////////////////////////////////
// main_selftest.cc — 端到端自检（对应 10/26「入侵→报警端到端跑通」关卡）
//
// 一条命令跑完，打印 PASS/FAIL 汇总，可直接贴进记录/文档。
//
// 检查项（把这一路踩过的坑全部固化成判据）：
//   1. DDR     : 写入/读回图样（挤掉 cache 后再验）
//   2. 加速器   : UUID = 0x4923687a，且 Active = 1
//   3. 模型     : 张量分配成功，输入 9216 字节 / int8
//   4. 画面活着 : 连续两帧的采样校验和必须不同
//   5. 画面可用 : 输入不退化（标准差 > 5，饱和率 < 5%）
//   6. 推理     : Invoke 返回 kTfLiteOk 且 CI 指令数 > 0
//   7. 输出     : 寄存器 9 / 10 写入后不崩（可写性）
//
// 用法：加载后约 3 秒内输出全部结果，最后一行是 MMT_SELFTEST_RESULT。
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
#include "tensorflow/lite/micro/micro_time.h"
#include "platform/tinyml/profiler.h"
#include "model/mobilenetv1_person_detect_model_data.h"
#include "model/model_settings.h"

#define FB_BASE      0x01000000u
#define FB_W         960
#define FB_H         1080
#define FB_FRAME_LEN (960u * 1080u * 4u + 0x200u)
#define LIVE_BANK    2
#define BOX          5
#define IMG_N        (96 * 96)

#define APB_BASE     0xF8100000u
#define APB_OSD      (*(volatile uint32_t*)(APB_BASE + 4u * 9u))
#define APB_SCORE    (*(volatile uint32_t*)(APB_BASE + 4u * 10u))
#define APB_CAL      (*(volatile uint32_t*)(APB_BASE + 4u * 0u))
#define APB_CI       (*(volatile uint32_t*)(APB_BASE + 4u * 6u))

namespace {
   tflite::ErrorReporter* error_reporter = nullptr;
   const tflite::Model* model = nullptr;
   tflite::MicroInterpreter* interpreter = nullptr;
   TfLiteTensor* model_input = nullptr;
   constexpr int kTensorArenaSize = 136 * 1024;
   uint8_t tensor_arena[kTensorArenaSize];
   int8_t snap[IMG_N];
}

static int g_fail = 0;

static void report(const char* name, int ok, const char* detail)
{
   if (!ok) ++g_fail;
   bsp_printf("MMT_ST %-12s %s  %s\n\r", name, ok ? "PASS" : "FAIL", detail ? detail : "");
}

// ---------- 1. DDR ----------
static void test_ddr(void)
{
   volatile uint32_t* p = (volatile uint32_t*)0x00200000u;
   int ok_w = 1, ok_r = 1;
   for (uint32_t i = 0; i < 16; ++i) p[i] = 0x5A5A0000u | i;
   for (uint32_t i = 0; i < 16; ++i) if (p[i] != (0x5A5A0000u | i)) ok_w = 0;
   /* 扫 2MB 挤掉 D-cache 后复验 */
   volatile uint32_t* s = (volatile uint32_t*)0x00300000u;
   uint32_t acc = 0;
   for (uint32_t i = 0; i < (512u * 1024u); ++i) acc += s[i];
   (void)acc;
   for (uint32_t i = 0; i < 16; ++i) if (p[i] != (0x5A5A0000u | i)) ok_r = 0;
   report("DDR", ok_w && ok_r, ok_w ? (ok_r ? "write+readback ok" : "sweep changed data") : "write failed");
}

// ---------- 采样 ----------
static uint32_t sample(int8_t* out)
{
   const uint32_t base = FB_BASE + (uint32_t)LIVE_BANK * FB_FRAME_LEN;
   const uint32_t step_y = FB_H / 96u;
   const uint32_t step_x = FB_W / 96u;
   uint32_t sum = 0;
   for (uint32_t y = 0; y < 96; ++y) {
      const uint32_t sy0 = y * step_y;
      for (uint32_t x = 0; x < 96; ++x) {
         const uint32_t sx0 = x * step_x;
         uint32_t a = 0;
         for (uint32_t dy = 0; dy < BOX; ++dy) {
            const uint32_t sy = sy0 + dy * step_y / BOX;
            const volatile uint32_t* row =
                  (const volatile uint32_t*)(base + (sy * FB_W) * 4u);
            for (uint32_t dx = 0; dx < BOX; ++dx)
               a += row[sx0 + dx * step_x / BOX] & 0xFFu;
         }
         const uint32_t v = a / (BOX * BOX);
         out[y * 96 + x] = (int8_t)v;
         sum += v;
      }
   }
   return sum;
}

extern "C" int main()
{
   bsp_printf("\n\rMMT_SELFTEST_BEGIN\n\r");
   const u32 hart = csr_read(mhartid);
   IntcInitialize();

   /* 1. DDR（必须最先跑：后面所有步骤都依赖 DDR） */
   test_ddr();

   /* 2. 加速器 */
   init_accel(hart);
   print_accel(hart);
   const uint32_t uuid = hw_accel_setting[0].uuid;
   report("ACCEL", accel_count == 1 && hw_accel_setting[0].accel_active == 1 &&
                  uuid == 0x4923687au, "uuid=0x4923687a expected");

   /* 3. 模型 */
   static tflite::MicroErrorReporter reporter;
   error_reporter = &reporter;
   model = tflite::GetModel(mobilenetv1_person_detect_model_data);
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
   const int alloc_ok = (interpreter->AllocateTensors() == kTfLiteOk);
   model_input = interpreter->input(0);
   report("MODEL", alloc_ok && model_input->bytes == IMG_N &&
                   model_input->type == kTfLiteInt8,
          alloc_ok ? "alloc ok" : "alloc failed");

   /* 4/5. 画面活着 + 可用 */
   const uint32_t chk1 = sample(snap);
   for (volatile uint32_t d = 0; d < 2000000u; ++d) {}
   const uint32_t chk2 = sample(snap);

   uint32_t sum = 0, sumsq = 0, sat = 0;
   int mn = 127, mx = -128;
   for (int i = 0; i < IMG_N; ++i) {
      const int v = snap[i];
      const uint32_t b = (uint8_t)v;
      sum += b;
      sumsq += b * b;
      if (b == 0xFFu) ++sat;
      if (v < mn) mn = v;
      if (v > mx) mx = v;
   }
   const uint32_t mean = sum / IMG_N;
   const uint32_t var = sumsq / IMG_N - mean * mean;
   uint32_t sd = 0;
   while ((sd + 1) * (sd + 1) <= var) ++sd;
   const uint32_t satp = sat * 1000u / IMG_N;

   char buf[64];
   bsp_printf("MMT_ST_IMG mean=%d sd=%d sat_permil=%d min=%d max=%d\n\r",
              (int)mean, (int)sd, (int)satp, mn, mx);
   report("CAM_ALIVE", chk1 != chk2, chk1 != chk2 ? "frame changed" : "frozen frame");
   report("CAM_USABLE", sd > 5 && satp < 50,
          sd <= 5 ? "too flat (sd<=5)" : (satp >= 50 ? "over-exposed (sat>=5%)" : "ok"));

   /* 6. 推理 */
   for (int i = 0; i < IMG_N; ++i) model_input->data.int8[i] = snap[i];
   const uint32_t ci0 = APB_CI;
   const uint64_t t0 = clint_getTime(BSP_CLINT);
   const TfLiteStatus st = interpreter->Invoke();
   const uint64_t t1 = clint_getTime(BSP_CLINT);
   const uint32_t ci = APB_CI - ci0;
   const int p = interpreter->output(0)->data.int8[kPersonIndex];
   const int a = interpreter->output(0)->data.int8[kNotAPersonIndex];
   bsp_printf("MMT_ST_INFER p=%d a=%d ci=%d ms=%d\n\r",
              p, a, (int)ci, (int)((t1 - t0) / (SYSTEM_CLINT_HZ / 1000)));
   report("INFER", st == kTfLiteOk && ci > 0,
          st != kTfLiteOk ? "Invoke failed" : (ci == 0 ? "no CI activity" : "ok"));

   /* 7. 输出寄存器可写 */
   APB_OSD = 1u;
   APB_SCORE = 0x100u | (uint32_t)(uint8_t)p;
   report("APB_OUT", 1, "reg9/reg10 written");

   /* 汇总 */
   bsp_printf("MMT_SELFTEST_RESULT %s fail=%d\n\r",
              g_fail == 0 ? "PASS" : "FAIL", g_fail);
   bsp_printf("MMT_SELFTEST_END\n\r");

   while (1) {}
}
