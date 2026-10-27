#include <stdint.h>
static uint32_t simulated_time;
static uint64_t now_ms(void){return simulated_time;}
static void bsp_printf(const char* fmt,...){(void)fmt;}
static volatile uint32_t dec_reg,ctrl_reg;
#define APB_DEC dec_reg
#define APB_CTRL ctrl_reg
#define FW_DECISION_ON   1       /* v15 默认 */
#define AI_P_TH          (0)
#define AI_VOTE_N        3
#define AI_VOTE_K        2
#define AI_P_STRONG      60
#define AI_P_OFF         (-80)
#define AI_AREA_MIN      200     /* 运动面积门限：压制全局亮变/AGC 型大 motion */
#define AI_AREA_MAX      20000
#define DEC_CAND_FRAMES  6
#define DEC_RELEASE_FRAMES 3     /* 连续无运动且无 AI 的解除计数（≈1.6s） */
#define DEC_WARMUP       2
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
volatile int input_data[10],output_data[6];
void replay_frame(void){
 int person=0;
 if(input_data[0]){
  ai_reset();alarm_on=0;alarm_frames=0;cand_left=0;rel_cnt=0;last_person=0;dec_evt=0;dec_conf=0;
#ifdef IR_OFF_WIN
  ir_idx=0;ir_cnt10=0;ir_cnt15=0;for(int i=0;i<IR_OFF_WIN;i++)ir_hist[i]=0;
#endif
 }
 if(input_data[3]){ai_reset();last_person=0;}
 if(input_data[2])person=ai_vote_update(input_data[1]);
 last_person=person;simulated_time=input_data[9];
 dec_update(input_data[7],input_data[5],input_data[8],input_data[2],person,input_data[4],input_data[6]);
 output_data[0]=alarm_on;output_data[1]=cand_left;output_data[2]=rel_cnt;output_data[3]=person;
#ifdef IR_OFF_WIN
 output_data[4]=ir_cnt10;output_data[5]=ir_cnt15;
#else
 output_data[4]=0;output_data[5]=0;
#endif
}
