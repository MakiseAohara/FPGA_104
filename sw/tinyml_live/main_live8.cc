////////////////////////////////////////////////////////////////////////////////
// Live inference v8 — box-filtered downsampling.
//
// v6/v7 used nearest-neighbour point sampling: 960x1080 -> 96x96 picks one pixel
// out of every 10x11 block. That is severe undersampling and shreds the shape of
// a person, which matches what we saw: clusters of PERSON mixed with confident
// EMPTY while someone was walking in front of the camera.
//
// This version averages a 5x5 grid inside each 10x11 block (25 samples per
// output pixel) — a cheap box filter that keeps low-frequency structure.
//
// Luma channel: byte0 of the 32-bit word (RGB565 interpretation was ruled out by
// the A/B test in v7).
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
#define BOX          5          /* 5x5 samples inside each block */
#define VOTE         3          /* frames to average over */

namespace {
   tflite::ErrorReporter* error_reporter = nullptr;
   const tflite::Model* model = nullptr;
   tflite::MicroInterpreter* interpreter = nullptr;
   TfLiteTensor* model_input = nullptr;

   constexpr int kTensorArenaSize = 136 * 1024;
   uint8_t tensor_arena[kTensorArenaSize];
}

/* Box-filter the live bank into out[96*96]. Returns the sum of output values. */
static uint32_t sample_frame_box(int8_t* out)
{
   const uint32_t base = FB_BASE + (uint32_t)LIVE_BANK * FB_FRAME_LEN;
   const uint32_t step_y = FB_H / 96u;      /* 11 */
   const uint32_t step_x = FB_W / 96u;      /* 10 */
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
         const uint32_t v = acc / (BOX * BOX);
         out[y * 96 + x] = (int8_t)v;
         sum += v;
      }
   }
   return sum;
}

void tinyml_init()
{
   static tflite::MicroErrorReporter micro_error_reporter;
   error_reporter = &micro_error_reporter;

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
   MicroPrintf("MMT_LIVE_BOOT v8_box\n\r");
   const u32 hart = csr_read(mhartid);
   tinyml_init();
   IntcInitialize();
   init_accel(hart);
   print_accel(hart);
   MicroPrintf("MMT_LIVE_HW_READY uuid=%x\n\r", hw_accel_setting[0].uuid);

   volatile uint32_t* diag = (volatile uint32_t*)0xF8100000u;
   uint32_t frame = 0;

   while (1) {
      const uint32_t chk = sample_frame_box(model_input->data.int8);

      const uint32_t ci0 = diag[6];
      const uint64_t t0 = clint_getTime(BSP_CLINT);
      interpreter->Invoke();
      const uint64_t t1 = clint_getTime(BSP_CLINT);
      const int p = interpreter->output(0)->data.int8[kPersonIndex];
      const int a = interpreter->output(0)->data.int8[kNotAPersonIndex];

      MicroPrintf("MMT_BOX f=%d chk=%x p=%d a=%d v=%d ci=%d ms=%d\n\r",
                  (int)frame, chk, p, a, (p > 0) ? 1 : 0,
                  (int)(diag[6] - ci0),
                  (int)((t1 - t0) / (SYSTEM_CLINT_HZ / 1000)));
      ++frame;
   }
}
