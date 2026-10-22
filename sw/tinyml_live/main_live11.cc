////////////////////////////////////////////////////////////////////////////////
// main_live11.cc — main_live9 + model-input diagnostics
//
// Adds, on top of main_live9.cc (register 9 and register 10 writes unchanged):
//   1. every 40 frames: one MMT_IMGSTAT line + 96 MMT_IMG lines dumping the
//      exact 96x96 int8 values that were written into the model
//   2. every MMT_OSD line gains b0m=<mean of the 9216 input bytes, integer>
//      and raw=<p as two hex digits>
//
// Definitions used here (important, they are easy to misread):
//   * MMT_IMGSTAT min/max/mean are computed over the SIGNED int8 values, i.e.
//     exactly what the model consumes.
//   * MMT_IMG prints each pixel as (uint8_t)value, two hex digits, in the same
//     order as the tensor: y = 0..95 top to bottom, x = 0..95 left to right.
//   * b0m is the mean of the same 9216 values taken as UNSIGNED bytes.
//
// MicroPrintf on this BSP only handles %d / %x (no width, no %s), so all
// fixed-width formatting is done by hand and printed through bsp_printf.
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

#define APB_BASE     0xF8100000u
#define APB_OSD      (*(volatile uint32_t*)(APB_BASE + 4u * 9u))
#define APB_SCORE    (*(volatile uint32_t*)(APB_BASE + 4u * 10u))

#define IMG_DUMP_EVERY 40
#define IMG_N          (96 * 96)

namespace {
   tflite::ErrorReporter* error_reporter = nullptr;
   const tflite::Model* model = nullptr;
   tflite::MicroInterpreter* interpreter = nullptr;
   TfLiteTensor* model_input = nullptr;

   constexpr int kTensorArenaSize = 136 * 1024;
   uint8_t tensor_arena[kTensorArenaSize];
}

static const char HEXD[] = "0123456789abcdef";

/* Box-filter the live bank into out[96*96]. Returns the sum of output values. */
static uint32_t sample_frame_box(int8_t* out)
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
         const uint32_t v = acc / (BOX * BOX);
         out[y * 96 + x] = (int8_t)v;
         sum += v;
      }
   }
   return sum;
}

/* Dump the model input exactly as consumed. */
static void dump_image(const int8_t* img, uint32_t frame, int p)
{
   int mn = 127;
   int mx = -128;
   long sum = 0;

   for (int i = 0; i < IMG_N; ++i) {
      const int v = (int)img[i];
      if (v < mn) mn = v;
      if (v > mx) mx = v;
      sum += v;
   }
   const int mean = (int)(sum / IMG_N);

   bsp_printf("MMT_IMGSTAT f=%d min=%d max=%d mean=%d p=%d\n\r",
              (int)frame, mn, mx, mean, p);

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
   MicroPrintf("MMT_LIVE_BOOT v11_imgdump\n\r");
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
      const uint32_t chk = sample_frame_box(model_input->data.int8);

      /* mean of the 9216 input bytes, taken as unsigned */
      uint32_t bsum = 0;
      for (int i = 0; i < IMG_N; ++i) {
         bsum += (uint8_t)model_input->data.int8[i];
      }
      const uint32_t b0m = bsum / IMG_N;

      const uint32_t ci0 = diag[6];
      const uint64_t t0 = clint_getTime(BSP_CLINT);
      interpreter->Invoke();
      const uint64_t t1 = clint_getTime(BSP_CLINT);
      const int p = interpreter->output(0)->data.int8[kPersonIndex];
      const int a = interpreter->output(0)->data.int8[kNotAPersonIndex];

      const int alarm = (p > 0) ? 1 : 0;
      APB_OSD = (uint32_t)alarm;

      /* APB reg 10: bit8 = valid marker, low byte = raw int8 score p */
      const uint32_t score = 0x100u | (uint32_t)(uint8_t)p;
      APB_SCORE = score;

      char raw[3];
      const uint8_t pb = (uint8_t)p;
      raw[0] = HEXD[pb >> 4];
      raw[1] = HEXD[pb & 0x0Fu];
      raw[2] = 0;

      bsp_printf("MMT_OSD f=%d chk=%x p=%d a=%d v=%d osd=%d ci=%d ms=%d b0m=%d raw=%s\n\r",
                 (int)frame, chk, p, a, alarm, alarm,
                 (int)(diag[6] - ci0),
                 (int)((t1 - t0) / (SYSTEM_CLINT_HZ / 1000)),
                 (int)b0m, raw);

      if ((frame % IMG_DUMP_EVERY) == 0) {
         dump_image(model_input->data.int8, frame, p);
      }

      ++frame;
   }
}
