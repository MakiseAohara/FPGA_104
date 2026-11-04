#ifndef MMT_MOT_WEB_STATE_H
#define MMT_MOT_WEB_STATE_H
/* Bounded, allocation-free JSON shared by firmware and native replay. Include
 * mot_core.h first. Coordinates always describe the supplied 96x96 MOT image. */
#include <stdint.h>
#ifndef MW_VIEW_WIDTH
#define MW_VIEW_WIDTH 96
#define MW_VIEW_HEIGHT 96
#endif
typedef struct { char* data; int cap,len,failed; } mw_json_t;
static void mw_char(mw_json_t* w,char c) {
 if(w->len+1>=w->cap) {w->failed=1;return;}
 w->data[w->len++]=c;
}
static void mw_str(mw_json_t* w,const char* s) {while(*s)mw_char(w,*s++);}
static void mw_int(mw_json_t* w,int v) {
 char tmp[12];int n=0;unsigned x;
 if(v<0){mw_char(w,'-');x=0u-(unsigned)v;}else x=(unsigned)v;
 do {tmp[n++]=(char)('0'+x%10);x/=10;}while(x);
 while(n)mw_char(w,tmp[--n]);
}
static void mw_pair(mw_json_t* w,int x,int y) {
 mw_char(w,'[');mw_int(w,x);mw_char(w,',');mw_int(w,y);mw_char(w,']');
}
static int mw_clip(int x,int max) {return x<0?0:(x>max?max:x);}
static void mw_predict(const mot_trk_t* t,int ms,int* x,int* y) {
#ifdef MOT_HAS_TIMED_API
 mot_predict_position_ms(t,ms,x,y);
#else
 *x=t->cx+(t->vx*ms)/(16*200);*y=t->cy+(t->vy*ms)/(16*200);
#endif
 *x=mw_clip(*x,MOT_W-1);*y=mw_clip(*y,MOT_H-1);
}
static int mot_web_write(const mot_ctx_t* c,const char* source,int frame_id,
                        uint32_t timestamp_ms,int sample_ms,char* data,int cap) {
 mw_json_t w={data,cap,0,0};int k,j,n=0,pre_id=0,pre_eta=-1;
 if(!data || cap<2)return 0;
 mw_str(&w,"{\"schema\":1,\"source\":\"");mw_str(&w,source);
 mw_str(&w,"\",\"frame_id\":");mw_int(&w,frame_id);
 mw_str(&w,",\"timestamp_ms\":");mw_int(&w,(int)timestamp_ms);
 mw_str(&w,",\"sample_ms\":");mw_int(&w,sample_ms);
 mw_str(&w,",\"time_step_ms\":200,\"width\":96,\"height\":96,\"aspect_width\":");mw_int(&w,MW_VIEW_WIDTH);
 mw_str(&w,",\"aspect_height\":");mw_int(&w,MW_VIEW_HEIGHT);
 mw_str(&w,",\"people_count\":");mw_int(&w,mot_fresh_confirmed(c));
 mw_str(&w,",\"capacity\":");mw_int(&w,MOT_MAX_TRK);
 mw_str(&w,",\"frame_aligned\":true,\"frame_url\":\"/frame.png?seq=");mw_int(&w,frame_id);mw_char(&w,'"');
 mw_str(&w,",\"horizon_steps\":2,\"horizon_ms\":400,\"roi\":[");
 mw_int(&w,MOT_ETA_X0);mw_char(&w,',');mw_int(&w,MOT_ETA_Y0);mw_char(&w,',');
 mw_int(&w,MOT_ETA_X1);mw_char(&w,',');mw_int(&w,MOT_ETA_Y1);
 mw_str(&w,"],\"tracks\":[");
 for(k=0;k<c->n_trk;k++) {
  const mot_trk_t* t=&c->trk[k];int x,y,warning;
  if(!t->confirmed)continue;
#ifdef MOT_HAS_GROUP_OCCLUSION
  if(t->misses>MOT_MAX_MISS && !t->occluded)continue;
#else
  if(t->misses>MOT_MAX_MISS)continue;
#endif
  if(n++)mw_char(&w,',');
  mw_str(&w,"{\"id\":");mw_int(&w,t->id);
  mw_str(&w,",\"bbox\":[");mw_int(&w,t->x0);mw_char(&w,',');mw_int(&w,t->y0);
  mw_char(&w,',');mw_int(&w,t->x1);mw_char(&w,',');mw_int(&w,t->y1);mw_char(&w,']');
  mw_str(&w,",\"center\":");mw_pair(&w,t->cx,t->cy);
  mw_str(&w,",\"velocity_q4\":");mw_pair(&w,t->vx,t->vy);
  mw_str(&w,",\"prediction\":");mw_predict(t,400,&x,&y);mw_pair(&w,x,y);
  mw_str(&w,",\"future\":[");mw_predict(t,200,&x,&y);mw_pair(&w,x,y);mw_char(&w,',');
  mw_predict(t,400,&x,&y);mw_pair(&w,x,y);mw_str(&w,"],\"history\":[");
  for(j=0;j<t->traj_n;j++) {if(j)mw_char(&w,',');mw_pair(&w,t->traj[j][0],t->traj[j][1]);}
  mw_str(&w,"],\"confirmed\":true,\"visible\":");mw_str(&w,t->misses==0?"true":"false");
  mw_str(&w,",\"misses\":");mw_int(&w,t->misses);
  mw_str(&w,",\"state\":\"");mw_str(&w,t->misses?"coasting":"observed");
  mw_str(&w,"\",\"supported\":");mw_str(&w,t->supported?"true":"false");
  mw_str(&w,",\"eta_steps\":");mw_int(&w,t->eta);
  mw_str(&w,",\"eta_ms\":");mw_int(&w,t->eta<0?-1:t->eta*200);
  warning=t->supported && !c->shaking && !t->misses && t->eta>0 && t->eta<=3;
  mw_str(&w,",\"warning\":");mw_str(&w,warning?"true":"false");mw_char(&w,'}');
  if(warning && (pre_eta<0 || t->eta<pre_eta)) {pre_id=t->id;pre_eta=t->eta;}
 }
 mw_str(&w,"],\"prewarn\":{\"active\":");mw_str(&w,pre_eta>=0?"true":"false");
 mw_str(&w,",\"id\":");mw_int(&w,pre_id);
 mw_str(&w,",\"eta_steps\":");mw_int(&w,pre_eta);
 mw_str(&w,",\"action\":\"");mw_str(&w,pre_eta>=0?(source[0]=='o'?"wake_inference":"prewarn_only"):"none");
 mw_str(&w,"\"},\"metrics\":{\"observed\":");mw_int(&w,mot_fresh_confirmed(c));
 mw_str(&w,",\"retained\":");mw_int(&w,n);mw_str(&w,"}}");
 if(w.failed){data[0]=0;return 0;}data[w.len]=0;return w.len;
}
#endif
