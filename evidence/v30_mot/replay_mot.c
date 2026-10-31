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
   FILE* fa = NULL; FILE* fi = NULL;
   if (argc > 2) { fa = fopen(argv[2], "r"); }
   if (argc > 3) { fi = fopen(argv[3], "r"); }
   int ai_p = -100;   /* ai.txt 缺省：按"判无人"处理 */
   int ir_c = 2;      /* ir.txt 缺省：按"红外热"处理（保守，不触发背景复位） */
   static unsigned char frame[MOT_N];
   static mot_ctx_t ctx;
   static mot_work_t work;
   int idx = 0, k;
   int prev_pre = 0;
   mot_reset(&ctx);
   while (fread(frame, 1, MOT_N, fp) == MOT_N) {
      if (fa) { if (fscanf(fa, "%d", &ai_p) != 1) ai_p = -100; }
      if (fi) { if (fscanf(fi, "%d", &ir_c) != 1) ir_c = 2; }
      int n = mot_step(&ctx, &work, frame, ai_p, ir_c);
      for (k = 0; k < ctx.n_trk; ++k) {
         const mot_trk_t* t = &ctx.trk[k];
         if (!t->active) continue;
         printf("MMT_TRK f=%d id=%d c=%d,%d b=%d,%d,%d,%d v16=%d,%d dir=%d hit=%d miss=%d conf=%d pred=%d,%d eta=%d\n",
                idx, (int)t->id, t->cx, t->cy, t->x0, t->y0, t->x1, t->y1,
                (int)t->vx, (int)t->vy, (int)t->dir, (int)t->hits, (int)t->misses,
                (int)t->confirmed, (int)t->px, (int)t->py, (int)t->eta);
      }
      {
         const int nconf = mot_active_confirmed(&ctx);
         int pre = 0, pre_eta = -1, pre_id = -1;
         for (k = 0; k < ctx.n_trk; ++k) {
            const mot_trk_t* t = &ctx.trk[k];
            if (!t->active) continue;
            if (!(t->supported && t->hits >= 1 && t->eta >= 0 && t->eta <= (MOT_HORIZON + 3))) continue;
#if MOT_V15_ENTRY
            if (!(t->confirmed || t->edge_entry)) continue;
            if (t->pre_ok < MOT_PRE_OK_N) continue;
#endif
            if (pre_eta < 0 || (int)t->eta < pre_eta) { pre = 1; pre_eta = (int)t->eta; pre_id = (int)t->id; }
         }
         if (pre && !prev_pre) printf("MMT_PREWARN f=%d id=%d eta=%d\n", idx, pre_id, pre_eta);
         prev_pre = pre;
         printf("MMT_MOT f=%d nd=%d nt=%d conf=%d area=%d raw=%d pre=%d pre_eta=%d bigr=%d bigf=%d\n",
                idx, ctx.n_det, n, nconf, ctx.last_area, ctx.raw_area, pre, pre_eta, ctx.big_reset, ctx.big_full);
      }
      idx++;
   }
   fclose(fp);
   if (fa) fclose(fa);
   if (fi) fclose(fi);
   fprintf(stderr, "replayed %d frames\n", idx);
   return 0;
}
