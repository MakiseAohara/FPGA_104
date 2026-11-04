#include <stdint.h>
#include <string.h>
#ifdef BASELINE
#include "../v30_mot/mot_core_baseline.h"
#else
#include "../v30_mot/mot_core.h"
#endif
#include "../v30_mot/mot_web_state.h"
static mot_ctx_t context;
static mot_work_t work;
static uint32_t stamp,delta;
__declspec(dllexport) void reset(void) {
 memset(&context,0,sizeof(context));memset(&work,0,sizeof(work));mot_reset(&context);stamp=0;delta=200;
}
__declspec(dllexport) void step(const uint8_t* pixels,int ai,int ir,uint32_t ms) {
 delta=ms>stamp?ms-stamp:200;stamp=ms;
#ifdef MOT_HAS_TIMED_API
 mot_step_timed(&context,&work,pixels,ai,ir,ms);
#else
 mot_step(&context,&work,pixels,ai,ir);
#endif
}
__declspec(dllexport) void boxes(const int* b,int count,int ai,uint32_t ms) {
 int i;delta=ms>stamp?ms-stamp:200;stamp=ms;
#ifdef MOT_HAS_TIMED_API
 /* A blank timed step sets elapsed-time state, then detector output is replaced
    below. Direct box regression is implemented in the algorithm unit suite. */
#endif
 context.ai_p=ai;context.ir_cnt=2;context.n_det=count;
 for(i=0;i<count;i++) {
  mot_det_t* d=&context.det[i];d->x0=b[i*6];d->y0=b[i*6+1];d->x1=b[i*6+2];d->y1=b[i*6+3];
  d->cx=(d->x0+d->x1)/2;d->cy=(d->y0+d->y1)/2;d->area=(d->x1-d->x0+1)*(d->y1-d->y0+1);d->mean=b[i*6+4];
 }
 mot_associate(&context);context.frame++;
}
__declspec(dllexport) int snapshot(char* out,int cap,int frame_id) {
 return mot_web_write(&context,"offline_synthetic",frame_id,stamp,(int)delta,out,cap);
}
