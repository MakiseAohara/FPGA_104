////////////////////////////////////////////////////////////////////////////////
// main_live12.cc — exposure-sensitivity test.
//
// Hypothesis to test: the false positives are caused by the image being blown out
// (~20% of pixels saturate at 0xff), so lowering the brightness should pull the
// score down.
//
// The SAME frame is sampled once, then the model is invoked three times with the
// input scaled by 1.00 / 0.75 / 0.50 (in the byte domain, so 0xff-clipped areas
// come back into range).
//
// No person needed: this only measures how sensitive the decision is to exposure.
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
#include "tensorflow/lite/micro/testing/micro_test.h"
#include "tensorflow/lite/schema/schema_generated.h"
#include "tensorflow/lite/c/common.h"
#include "tensorflow/lite/micro/debug_log.h"
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

namespace {
   tflite::ErrorReporter* error_reporter = nullptr;
   const tflite::Model* model = nullptr;
   tflite::MicroInterpreter* interpreter = nullptr;
   TfLiteTensor* model_input = nullptr;
   constexpr int kTensorArenaSize = 136 * 1024;
   uint8_t tensor_arena[kTensorArenaSize];
   uint8_t raw[IMG_N];
}

static uint32_t sample_frame_box(uint8_t* out)
{
   const uint32_t base = FB_BASE + (uint32_t)LIVE_BANK * FB_FRAME_LEN;
   const uint32_t step_y = FB_H / 96u;
   const uint32_t step_x = FB_W / 96u;
   uint32_t sum = 0;
   for (uint32_t y = 0; y < 96; ++y) {
      const uint32_t sy0 = y * step_y;
      for (uint32_t x = 0; x < 96; ++x) {
         const uint32_t sx0 = x * step_x;
         uint32_t acc = 0;
         for (uint32_t dy = 0; dy < BOX; ++dy) {
            const uint32_t sy = sy0 + dy * step_y / BOX;
            const volatile uint32_t* row =
                  (const volatile uint32_t*)(base + (sy * FB_W) * 4u);
            for (uint32_t dx = 0; dx < BOX; ++dx) {
               const uint32_t sx = sx0 + dx * step_x / BOX;
               acc += row[sx] & 0xFFu;
            }
         }
         out[y * 96 + x] = (uint8_t)(acc / (BOX * BOX));
         sum += out[y * 96 + x];
      }
   }
   return sum;
}

static void apply_scale(uint32_t num, uint32_t den)
{
   for (int i = 0; i < IMG_N; ++i) {
      uint32_t v = (uint32_t)raw[i] * num / den;
      if (v > 255u) v = 255u;
      model_input->data.int8[i] = (int8_t)(uint8_t)v;
   }
}

static int run_once(uint32_t num, uint32_t den)
{
   apply_scale(num, den);
   interpreter->Invoke();
   return interpreter->output(0)->data.int8[kPersonIndex];
}

void tinyml_init()
{
   static tflite::MicroErrorReporter micro_error_reporter;
   error_reporter = &micro_error_reporter;
   model = tflite::GetModel(mobilenetv1_person_detect_model_data);
   static tflite::MicroMutableOpResolver<5> resolver;
   resolver.AddAveragePool2D();
   resolver.AddConv2D();
   resolver.AddDepthwiseConv2D();
   resolver.AddReshape();
   resolver.AddSoftmax();
   static FullProfiler prof;
   static tflite::MicroInterpreter static_interpreter(
      model, resolver, tensor_arena, kTensorArenaSize, error_reporter, nullptr);
   interpreter = &static_interpreter;
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

extern "C" int main()
{
   MicroPrintf("MMT_LIVE_BOOT v12_exposure\n\r");
   const u32 hart = csr_read(mhartid);
   tinyml_init();
   IntcInitialize();
   init_accel(hart);
   print_accel(hart);
   MicroPrintf("MMT_LIVE_HW_READY uuid=%x\n\r", hw_accel_setting[0].uuid);

   APB_OSD = 0;
   volatile uint32_t* diag = (volatile uint32_t*)APB_BASE;
   uint32_t frame = 0;

   while (1) {
      const uint32_t chk = sample_frame_box(raw);

      uint32_t sum = 0, sat = 0;
      for (int i = 0; i < IMG_N; ++i) {
         sum += raw[i];
         if (raw[i] == 0xFFu) ++sat;
      }
      const uint32_t b0m = sum / IMG_N;
      const uint32_t satp = sat * 1000u / IMG_N;   /* per-mille */

      const int p100 = run_once(100, 100);
      const int p75  = run_once(75, 100);
      const int p50  = run_once(50, 100);

      const int alarm = (p100 > 0) ? 1 : 0;
      APB_OSD = (uint32_t)alarm;
      APB_SCORE = 0x100u | (uint32_t)(uint8_t)p100;

      MicroPrintf("MMT_EXP f=%d chk=%x b0m=%d sat=%d p100=%d p75=%d p50=%d\n\r",
                  (int)frame, chk, (int)b0m, (int)satp, p100, p75, p50);
      ++frame;
   }
}
