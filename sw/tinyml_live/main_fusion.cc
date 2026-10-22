////////////////////////////////////////////////////////////////////////////////
// main_fusion.cc — RISC-V 侧决策融合 + 低功耗事件驱动推理  (扩展项 ② / ⑤)
//
// 设计原则：
//   1. 所有跨模块输入都从 APB 只读寄存器读取；地址集中在下面的「对齐区」，
//      队友给出正式编号后只改这几行，其余代码不动。
//   2. 寄存器读不到（RTL 未实现 ⇒ 返回 0）时自动降级：只用 AI 一路，
//      绝不因为缺一路信号就卡死。
//   3. 保持向后兼容：仍然每帧写 reg9 (ai_person) 与 reg10 (0x100|score)。
//
// 融合模型（按赛题 60/25/15 权重）：
//     score = 0.60 * motion + 0.25 * ir + 0.15 * env        (0..100)
//     AI 作为「强证据」：AI 命中时降低报警门限，未命中时提高门限。
//     报警 = score >= TH_ON ；报警后保持到 score <= TH_OFF（迟滞）
//
// 低功耗（⑤）：
//     无运动且无红外热点超过 IDLE_FRAMES 帧后，推理降频到每 INFER_IDLE_DECIM 帧一次；
//     一旦检测到运动，立刻恢复全速推理。
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

// ============================ 与 RTL 对齐区 ============================
// 队友确认编号后，只需修改下面 6 个地址与位定义。
#define APB_BASE        0xF8100000u

#define REG_AI_PERSON   (*(volatile uint32_t*)(APB_BASE + 4u * 9u))   // 只写：bit0
#define REG_AI_SCORE    (*(volatile uint32_t*)(APB_BASE + 4u * 10u))  // 只写：0x100|int8

// --- 以下为「待 RTL 提供」的只读寄存器，当前按提议编号 ---
#define REG_MOTION      (*(volatile uint32_t*)(APB_BASE + 4u * 11u))  // bit0=有运动, [31:16]=帧差面积
#define REG_IR          (*(volatile uint32_t*)(APB_BASE + 4u * 12u))  // bit31=有效, [15:0]=最高温(0.01C,有符号)
#define REG_ENV         (*(volatile uint32_t*)(APB_BASE + 4u * 13u))  // bit31=有效, [15:0]=温度(0.01C), [31:16]=湿度(0.01%)
// --- 以下为「写回 RTL」的输出寄存器 ---
#define REG_ALARM       (*(volatile uint32_t*)(APB_BASE + 4u * 14u))  // [0]=报警, [15:8]=置信度, [23:16]=触发原因位图
#define REG_AI_CTRL     (*(volatile uint32_t*)(APB_BASE + 4u * 15u))  // [0]=本周期是否跑推理, [15:8]=降频倍数
// ======================================================================

// ---- 融合参数（可按实测调整）----
#define W_MOTION   60
#define W_IR       25
#define W_ENV      15

#define TH_ON_BASE      55     // 无 AI 支援时的报警门限(0..100)
#define TH_ON_AI_BONUS  25     // AI 命中时门限下调
#define TH_OFF_BASE     35     // 解除门限（迟滞）

#define IDLE_FRAMES      8     // 连续多少帧无运动才算空闲
#define INFER_IDLE_DECIM 10    // 空闲时每 N 帧推理一次

// ---- 判据阈值（现场可调）----
#define MOTION_AREA_HI   800   // 帧差面积「强运动」
#define MOTION_AREA_LO   120   // 帧差面积「有变化」
#define IR_DELTA_HI      600   // 红外最高温 − 环境温度 > 6.00C
#define IR_DELTA_LO      250   // > 2.50C

namespace {
   tflite::ErrorReporter* error_reporter = nullptr;
   const tflite::Model* model = nullptr;
   tflite::MicroInterpreter* interpreter = nullptr;
   TfLiteTensor* model_input = nullptr;
   constexpr int kTensorArenaSize = 136 * 1024;
   uint8_t tensor_arena[kTensorArenaSize];
}

// ---------------- 画面采样（与已验证固件一致）----------------
#define FB_BASE      0x01000000u
#define FB_W         960
#define FB_H         1080
#define FB_FRAME_LEN (960u * 1080u * 4u + 0x200u)
#define LIVE_BANK    2
#define BOX          5
#define IMG_N        (96 * 96)

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

// ---------------- 各路打分 0..100 ----------------
static int score_motion(uint32_t area)
{
   if (area >= MOTION_AREA_HI) return 100;
   if (area <= MOTION_AREA_LO) return 0;
   return (int)((area - MOTION_AREA_LO) * 100u / (MOTION_AREA_HI - MOTION_AREA_LO));
}

static int score_ir(int32_t ir_centi, int32_t env_centi)
{
   const int32_t d = ir_centi - env_centi;
   if (d >= IR_DELTA_HI) return 100;
   if (d <= IR_DELTA_LO) return 0;
   return (int)((d - IR_DELTA_LO) * 100 / (IR_DELTA_HI - IR_DELTA_LO));
}

static int score_env(int32_t temp_centi, uint32_t hum_centi)
{
   /* 环境本身不直接判入侵：只贡献"是否处于异常工况"的弱信号。
      这里用「温度在 15..30C 之外」或「湿度 > 70%」作为轻微加权。 */
   int s = 0;
   if (temp_centi < 1500 || temp_centi > 3000) s += 60;
   if (hum_centi > 7000) s += 40;
   return s > 100 ? 100 : s;
}

// ---------------- 模型 ----------------
void tinyml_init()
{
   static tflite::MicroErrorReporter reporter;
   error_reporter = &reporter;
   model = tflite::GetModel(mobilenetv1_person_detect_model_data);
   if (model->version() != TFLITE_SCHEMA_VERSION) {
      MicroPrintf("MMT_FUSE_FAIL MODEL\n\r");
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
      MicroPrintf("MMT_FUSE_FAIL ALLOC\n\r");
      while (1) {}
   }
   model_input = interpreter->input(0);
}

extern "C" int main()
{
   MicroPrintf("MMT_FUSE_BOOT v13_fusion\r\n");
   const u32 hart = csr_read(mhartid);
   tinyml_init();
   IntcInitialize();
   init_accel(hart);
   print_accel(hart);
   MicroPrintf("MMT_FUSE_HW_READY uuid=%x\r\n", hw_accel_setting[0].uuid);

   REG_AI_PERSON = 0;
   REG_AI_SCORE = 0;
   REG_ALARM = 0;
   REG_AI_CTRL = 0;

   uint32_t frame = 0;
   uint32_t idle_cnt = 0;
   int alarm = 0;
   int last_p = -128;

   while (1) {
      const uint32_t m = REG_MOTION;
      const uint32_t ir = REG_IR;
      const uint32_t env = REG_ENV;

      const uint32_t area = (m >> 16) & 0xFFFFu;
      const int motion_now = (m & 1u) || (area >= MOTION_AREA_LO);

      const int ir_valid = (ir >> 31) & 1u;
      const int32_t ir_centi = (int32_t)(int16_t)(ir & 0xFFFFu);
      const int env_valid = (env >> 31) & 1u;
      const int32_t temp_centi = (int32_t)(int16_t)(env & 0xFFFFu);
      const uint32_t hum_centi = (env >> 16) & 0xFFFFu;

      /* ---- 低功耗：决定本周期是否推理 ---- */
      if (motion_now) idle_cnt = 0;
      else if (idle_cnt < 0xFFFFu) ++idle_cnt;

      const int idle = (idle_cnt >= IDLE_FRAMES);
      const int run_infer = (!idle) || ((frame % INFER_IDLE_DECIM) == 0);

      if (run_infer) {
         const uint32_t chk = sample_frame_box(model_input->data.int8);
         (void)chk;
         interpreter->Invoke();
         last_p = interpreter->output(0)->data.int8[kPersonIndex];
         REG_AI_PERSON = (last_p > 0) ? 1u : 0u;
         REG_AI_SCORE = 0x100u | (uint32_t)(uint8_t)last_p;
      }
      REG_AI_CTRL = (run_infer ? 1u : 0u) | ((uint32_t)(idle ? INFER_IDLE_DECIM : 1) << 8);

      /* ---- 融合 ---- */
      const int sm = score_motion(area);
      const int si = ir_valid ? score_ir(ir_centi, env_valid ? temp_centi : 2200) : 0;
      const int se = env_valid ? score_env(temp_centi, hum_centi) : 0;
      const int base = (W_MOTION * sm + W_IR * si + W_ENV * se) / 100;

      const int ai_hit = (last_p > 0) ? 1 : 0;
      const int th_on = TH_ON_BASE - (ai_hit ? TH_ON_AI_BONUS : 0);

      if (!alarm) {
         if (base >= th_on) alarm = 1;
      } else {
         if (base <= TH_OFF_BASE && !ai_hit) alarm = 0;
      }

      /* 置信度：融合分与 AI 得分合成 0..100 */
      int conf = base;
      if (ai_hit) conf = (conf + 100) / 2;
      if (conf > 100) conf = 100;
      if (conf < 0) conf = 0;

      uint32_t reason = 0;
      if (sm > 0) reason |= 0x01;
      if (si > 0) reason |= 0x02;
      if (se > 0) reason |= 0x04;
      if (ai_hit) reason |= 0x08;

      REG_ALARM = ((uint32_t)alarm) | ((uint32_t)conf << 8) | (reason << 16);

      MicroPrintf("MMT_FUSE f=%d area=%d ir=%d env=%d sm=%d si=%d se=%d "
                  "base=%d ai=%d conf=%d alarm=%d idle=%d infer=%d\r\n",
                  (int)frame, (int)area, (int)ir_centi, (int)temp_centi,
                  sm, si, se, base, (int)last_p, conf, alarm, idle, run_infer);
      ++frame;
   }
}
