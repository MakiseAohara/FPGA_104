////////////////////////////////////////////////////////////////////////////////
// main_live14.cc — corrected framebuffer sampling geometry (raw Bayer, 1 B/px)
//
// Finding that motivated this version:
//   the framebuffer holds RAW BAYER, one byte per pixel.
//   one row = 1920 bytes (= 480 32-bit words, a word = 4 adjacent pixels,
//   byte0 = leftmost pixel).
//   The previous sampler used a 960-word (3840 B) row stride, so every "row"
//   spanned two real rows -> the image repeated every 48 output columns and
//   everything below output row 48 fell past the real frame (dark).
//
// This version uses the real geometry:
//   address(x,y) = FB_BASE + bank*FB_FRAME_LEN + y*1920 + x        (byte address)
//   1920 x 1080, 1 byte per pixel
//   96x96 output: output pixel (ox,oy) covers source x in [ox*20, ox*20+20)
//   and y in [oy*45/4, (oy+1)*45/4)
//   brightness of a sample point = mean of a 2x2 Bayer quad (x,y)(x+1,y)
//   (x,y+1)(x+1,y+1) with x,y even; then mean of BOX*BOX points.
//
// INPUT_SUB128 selects the int8 conversion:
//   0 -> (int8_t)v          plain bit reinterpret  (previous behaviour)
//   1 -> (int8_t)(v - 128)  offset around zero     (TFLM person example)
// Build both and compare.
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

// ------------------------- geometry -------------------------
#define FB_BASE      0x01000000u
#define FB_FRAME_LEN (960u * 1080u * 4u + 0x200u)   /* bank stride (unchanged) */
#define LIVE_BANK    2

#define FB_ROW_BYTES 1920u      /* real row stride, bytes */
#define FB_W_REAL    1920u
#define FB_H_REAL    1080u

#define BOX          3          /* BOX x BOX sample points per output pixel */

// ------------------------- input conversion -------------------------
#ifndef INPUT_SUB128
#define INPUT_SUB128 0
#endif

#define APB_BASE     0xF8100000u
#define APB_OSD      (*(volatile uint32_t*)(APB_BASE + 4u * 9u))
#define APB_SCORE    (*(volatile uint32_t*)(APB_BASE + 4u * 10u))

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

/* mean of a 2x2 Bayer quad at even (x,y) */
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

/* box-filter the live bank into out[96*96]; returns sum of model-input bytes */
static uint32_t sample_frame_box(int8_t* out)
{
   const uint32_t base = FB_BASE + (uint32_t)LIVE_BANK * FB_FRAME_LEN;
   uint32_t sum = 0;

   for (uint32_t oy = 0; oy < 96; ++oy) {
      for (uint32_t ox = 0; ox < 96; ++ox) {
         const uint32_t bx = ox * 20u;
         uint32_t acc = 0;
         for (uint32_t j = 0; j < BOX; ++j) {
            /* block height is 45/4 px; keep 1/4-px precision */
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

extern "C" int main()
{
   MicroPrintf("MMT_LIVE_BOOT v14_bayer row1920 BOX%d SUB128=%d\n\r",
               BOX, INPUT_SUB128);
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

      for (int i = 0; i < IMG_N; ++i) input_snapshot[i] = model_input->data.int8[i];
      uint32_t bsum = 0;
      for (int i = 0; i < IMG_N; ++i) bsum += (uint8_t)input_snapshot[i];
      const uint32_t b0m = bsum / IMG_N;

      const uint32_t ci0 = diag[6];
      const uint64_t t0 = clint_getTime(BSP_CLINT);
      interpreter->Invoke();
      const uint64_t t1 = clint_getTime(BSP_CLINT);
      const int p = interpreter->output(0)->data.int8[kPersonIndex];
      const int a = interpreter->output(0)->data.int8[kNotAPersonIndex];

      const int alarm = (p > 0) ? 1 : 0;
      APB_OSD = (uint32_t)alarm;
      APB_SCORE = 0x100u | (uint32_t)(uint8_t)p;

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
         dump_image(input_snapshot, frame, p);
      }
      ++frame;
   }
}
