#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../v30_mot/mot_core.h"
static int failed=0,passed=0;
static mot_ctx_t c;static mot_work_t w;static unsigned char pixels[MOT_N];
#define CHECK(name,x) do {if(x){passed++;printf("PASS %s\n",name);}else{failed++;printf("FAIL %s line %d\n",name,__LINE__);}}while(0)
static void det(int i,int x,int y,int width,int height,int mean) {
 mot_det_t* d=&c.det[i];memset(d,0,sizeof(*d));d->cx=x;d->cy=y;
 d->x0=x-width/2;d->y0=y-height/2;d->x1=d->x0+width-1;d->y1=d->y0+height-1;
 d->area=width*height;d->mean=mean;
}
static void track(int i,int id,int x,int y,int width,int height,int vx) {
 mot_trk_t* t=&c.trk[i];memset(t,0,sizeof(*t));t->id=id;t->cx=x;t->cy=y;
 t->x0=x-width/2;t->y0=y-height/2;t->x1=t->x0+width-1;t->y1=t->y0+height-1;
 t->obs_cx=x;t->obs_cy=y;t->vx=vx;t->sample_ms=MOT_TIME_STEP_MS;
 t->hits=4;t->confirmed=1;t->active=1;t->supported=1;t->mean=100;
 t->area=width*height;t->traj_n=1;t->traj[0][0]=x;t->traj[0][1]=y;
}
int main(void) {
 short box[4]={10,10,29,29};int x,y;mot_det_t d;
 memset(&d,0,sizeof(d));d.x0=10;d.y0=10;d.x1=29;d.y1=29;d.area=80;
 CHECK("bbox IoU identical is 1000 despite sparse foreground",mot_iou(&d,box)==1000 && mot_iou4(&d,box)==1000);
 d.x0=20;d.x1=39;
 CHECK("bbox IoU half-overlap uses union",mot_iou(&d,box)==333 && mot_iou4(&d,box)==333);
 mot_reset(&c);c.n_trk=2;c.n_det=2;c.ai_p=90;
 track(0,10,30,40,11,25,0);track(1,20,40,40,11,25,0);
 det(0,34,40,11,25,100);det(1,22,40,11,25,100);mot_associate(&c);
 CHECK("global assignment preserves both feasible matches",c.n_trk==2 && c.trk[0].id==10 && c.trk[0].cx==22 && c.trk[1].id==20 && c.trk[1].cx==34);
 CHECK("independent close people are counted separately",mot_fresh_confirmed(&c)==2);
 mot_reset(&c);c.n_trk=1;c.n_det=1;c.ai_p=90;track(0,10,30,40,11,25,0);det(0,30,40,11,25,200);mot_associate(&c);
 CHECK("appearance gate also protects high-IoU pairing",c.trk[0].hits==4 && c.trk[0].misses==1);
 mot_reset(&c);c.n_trk=1;c.ai_p=90;track(0,10,20,40,11,25,48);c.n_det=0;
 mot_associate(&c);mot_associate(&c);c.n_det=1;det(0,26,40,11,25,100);mot_associate(&c);
 CHECK("gap velocity comes from last real observations",c.trk[0].id==10 && c.trk[0].vx==32 && c.trk[0].misses==0);
 mot_reset(&c);c.n_trk=1;c.n_det=1;c.ai_p=90;track(0,10,20,40,11,25,0);c.trk[0].hits=1;
 c.dt_ms=100;det(0,21,40,11,25,100);mot_associate(&c);
 c.dt_ms=300;det(0,24,40,11,25,100);mot_associate(&c);
 CHECK("velocity invariant under 100/300ms sample intervals",c.trk[0].vx==32);
 {
 mot_ctx_t save=c;mot_reset(&c);c.n_trk=1;c.n_det=1;c.ai_p=90;track(0,11,60,60,11,25,0);c.trk[0].hits=1;
 c.dt_ms=100;det(0,59,59,11,25,100);mot_associate(&c);
 c.dt_ms=300;det(0,56,56,11,25,100);mot_associate(&c);
 CHECK("negative x/y velocity at variable dt has signed arithmetic",c.trk[0].vx==-32 && c.trk[0].vy==-32);
 mot_predict_position_ms(&c.trk[0],400,&x,&y);
 CHECK("left/up prediction remains left/up on 32-bit-long hosts",x==52 && y==52 && c.trk[0].px==52 && c.trk[0].py==52);
 c.n_det=0;c.dt_ms=200;mot_associate(&c);
 CHECK("negative coast cannot jump to opposite edge",c.trk[0].cx==54 && c.trk[0].cy==54);
 c=save;
 }
 mot_predict_position_ms(&c.trk[0],400,&x,&y);
 CHECK("published prediction uses same 400ms motion model",x==28 && c.trk[0].px==x && c.trk[0].py==y);
 c.trk[0].cx=20;c.trk[0].cy=40;c.trk[0].vx=32;c.trk[0].vy=0;c.trk[0].grow2=0;
 CHECK("ROI ETA uses same physical velocity",mot_eta_frames(&c.trk[0])==2);
 mot_reset(&c);c.n_trk=2;c.n_det=1;c.ai_p=90;
 track(0,10,30,40,11,25,16);track(1,20,44,40,11,25,-16);
 {int i;for(i=0;i<8;i++) {det(0,37,40,27,25,100);c.n_det=1;mot_associate(&c);}
  CHECK("merged observation preserves two IDs beyond normal miss limit",c.n_trk==2 && c.trk[0].occluded && c.trk[1].occluded && c.trk[0].id==10 && c.trk[1].id==20);
  c.n_det=2;det(0,39,40,11,25,100);det(1,35,40,11,25,100);mot_associate(&c);
  CHECK("separated observations recover original crossing identities",c.n_trk==2 && c.trk[0].cx==39 && c.trk[1].cx==35 && !c.trk[0].occluded && !c.trk[1].occluded);
 }
 c.trk[0].occluded=1;c.trk[1].occluded=1;c.n_det=0;
 {int i;for(i=0;i<25;i++)mot_associate(&c);CHECK("merged-track retention is bounded by four seconds",c.n_trk==0);}
 mot_reset(&c);memset(pixels,100,sizeof(pixels));mot_step_timed(&c,&w,pixels,-100,0,100);
 {int f=c.frame;mot_step_timed(&c,&w,pixels,-100,0,100);mot_step_timed(&c,&w,pixels,-100,0,99);CHECK("duplicate/backward timestamp cannot advance state",c.frame==f);}
 c.n_trk=1;track(0,10,20,40,11,25,32);mot_step_timed(&c,&w,pixels,-100,0,10000);
 CHECK("long recording discontinuity resets unobserved tracks",c.n_trk==0);
 mot_reset(&c);memset(pixels,100,sizeof(pixels));mot_set_background(&c,pixels);memset(&w,0,sizeof(w));
 {int i;for(i=0;i<MOT_N;i++)pixels[i]=(unsigned char)(i&1?102:98);for(i=0;i<100;i++)mot_bg_update(&c,&w,pixels);
 CHECK("fractional background follows small positive and negative changes symmetrically",c.bg[0]==98 && c.bg[1]==102);}
 {int row,col;mot_reset(&c);memset(&w,0,sizeof(w));
  for(row=1;row<95;row+=6)for(col=1;col<95;col+=6) {w.mask[row*MOT_W+col]=1;w.mask[row*MOT_W+col+1]=1;}
  mot_label(&w,&c);
  CHECK("256 components cannot wrap the visited label to zero",c.n_det==0 && c.raw_area==2 && w.lab[91*MOT_W+91]>255);
 }
 printf("ALG_REGRESSIONS passed=%d failed=%d sizeof_ctx=%u sizeof_work=%u\n",passed,failed,(unsigned)sizeof(c),(unsigned)sizeof(w));return failed?1:0;
}
