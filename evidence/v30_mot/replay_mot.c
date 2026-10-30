/* replay_mot.c — 把导出的 96x96 帧序列回放进 mot_core，输出与固件同格式的 MMT_TRK/MMT_MOT 行 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "mot_core.h"

int main(int argc, char** argv)
{
   if (argc < 2) { fprintf(stderr, "usage: replay_mot frames.bin\n"); return 2; }
   FILE* fp = fopen(argv[1], "rb");
   if (!fp) { perror("open"); return 2; }
   static unsigned char frame[MOT_N];
   static mot_ctx_t ctx;
   static mot_work_t work;
   int idx = 0, k;
   mot_reset(&ctx);
   while (fread(frame, 1, MOT_N, fp) == MOT_N) {
      int n = mot_step(&ctx, &work, frame);
      for (k = 0; k < ctx.n_trk; ++k) {
         const mot_trk_t* t = &ctx.trk[k];
         printf("MMT_TRK f=%d id=%d c=%d,%d b=%d,%d,%d,%d v16=%d,%d dir=%d hit=%d miss=%d conf=%d pred=%d,%d eta=%d\n",
                idx, (int)t->id, t->cx, t->cy, t->x0, t->y0, t->x1, t->y1,
                (int)t->vx, (int)t->vy, (int)t->dir, (int)t->hits, (int)t->misses,
                (int)t->confirmed, (int)t->px, (int)t->py, (int)t->eta);
      }
      {
         int nconf = 0;
         for (k = 0; k < ctx.n_trk; ++k) if (ctx.trk[k].confirmed) nconf++;
         printf("MMT_MOT f=%d nd=%d nt=%d conf=%d area=%d pre=0 pre_eta=-1\n",
                idx, ctx.n_det, n, nconf, ctx.last_area);
      }
      idx++;
   }
   fclose(fp);
   fprintf(stderr, "replayed %d frames\n", idx);
   return 0;
}
