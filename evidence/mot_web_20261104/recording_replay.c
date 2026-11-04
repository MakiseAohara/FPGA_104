#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef BASELINE
#include "../v30_mot/mot_core_baseline.h"
#else
#include "../v30_mot/mot_core.h"
#endif

/* Independent executable for recording regression; never accesses hardware. */
int main(int argc,char **argv) {
    FILE *raw,*ai,*ir,*times;
    static unsigned char pixels[MOT_N];
    static mot_ctx_t ctx;
    static mot_work_t work;
    int index=0,score=-128,thermal=0,k,first,recorded;
    unsigned stamp=0;
    if(argc!=6) {fprintf(stderr,"raw ai ir time recorded_time\n");return 2;}
    raw=fopen(argv[1],"rb");ai=fopen(argv[2],"r");ir=fopen(argv[3],"r");times=fopen(argv[4],"r");
    if(!raw||!ai||!ir||!times)return 3;
    recorded=atoi(argv[5]);mot_reset(&ctx);
    while(fread(pixels,1,MOT_N,raw)==MOT_N) {
        if(fscanf(ai,"%d",&score)!=1 || fscanf(ir,"%d",&thermal)!=1 || fscanf(times,"%u",&stamp)!=1)return 4;
        if(!recorded)stamp=(unsigned)(index+1)*200u;
#ifdef MOT_HAS_TIMED_API
        mot_step_timed(&ctx,&work,pixels,score,thermal,(uint32_t)stamp);
#else
        mot_step(&ctx,&work,pixels,score,thermal);
#endif
        printf("{\"index\":%d,\"timestamp_ms\":%u,\"ai_score\":%d,\"n_det\":%d,\"personlike_count\":%d,\"tracks\":[",index,stamp,score,ctx.n_det,mot_fresh_confirmed(&ctx));
        first=1;
        for(k=0;k<ctx.n_trk;k++) {
            mot_trk_t *t=&ctx.trk[k];
            if(!first)printf(",");first=0;
            printf("{\"id\":%d,\"cx\":%d,\"cy\":%d,\"px\":%d,\"py\":%d,\"vx_q4\":%d,\"vy_q4\":%d,\"confirmed\":%d,\"active\":%d,\"misses\":%d,\"bbox\":[%d,%d,%d,%d]}",
                   t->id,t->cx,t->cy,t->px,t->py,t->vx,t->vy,t->confirmed,t->active,t->misses,t->x0,t->y0,t->x1,t->y1);
        }
        printf("]}\n");index++;
    }
    fclose(raw);fclose(ai);fclose(ir);fclose(times);
    fprintf(stderr,"replayed %d frames\n",index);
    return 0;
}
