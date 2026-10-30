/* test_mot.c — mot_core.h 主机侧单元测试（v1.1 背景差分版） */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "mot_core.h"

static unsigned char fA[MOT_N];
static mot_ctx_t ctx;
static mot_work_t work;
static int fails = 0;

static void bg(unsigned char* p, int v) { memset(p, v, MOT_N); }
static void rect(unsigned char* p, int x0, int y0, int w, int h, int v)
{
   int y, x;
   for (y = y0; y < y0+h; ++y) for (x = x0; x < x0+w; ++x)
      if (x>=0&&x<MOT_W&&y>=0&&y<MOT_H) p[y*MOT_W+x] = (unsigned char)v;
}
static void check(const char* name, int cond, const char* detail)
{
   printf("%-30s %-4s %s\n", name, cond ? "PASS" : "FAIL", detail ? detail : "");
   if (!cond) fails++;
}
static int find_trk(int id)
{
   int i; for (i = 0; i < ctx.n_trk; ++i) if (ctx.trk[i].id == id) return i;
   return -1;
}

int main(void)
{
   int f;

   /* S0 静止场景 */
   mot_reset(&ctx); bg(fA, 60);
   mot_step(&ctx, &work, fA);
   for (f = 0; f < 5; ++f) mot_step(&ctx, &work, fA);
   check("S0 static: no det", ctx.n_det == 0 && ctx.n_trk == 0, "");

   /* S1 双目标同向右移 2 / 3 px 每帧 */
   mot_reset(&ctx); bg(fA, 60);
   mot_step(&ctx, &work, fA);
   {
      int idA = -1, idB = -1, stable = 1;
      for (f = 0; f < 12; ++f) {
         bg(fA, 60);
         rect(fA, 6 + f*2, 20, 10, 26, 200);
         rect(fA, 54 + f*3, 55, 8, 20, 210);
         mot_step(&ctx, &work, fA);
         if (f >= 6) {
            int k;
            if (idA < 0 || idB < 0) {
               for (k = 0; k < ctx.n_trk; ++k) {
                  if (ctx.trk[k].cx < 48 && idA < 0) idA = ctx.trk[k].id;
                  if (ctx.trk[k].cx > 48 && idB < 0) idB = ctx.trk[k].id;
               }
            }
            if (idA >= 0 && find_trk(idA) < 0) stable = 0;
            if (idB >= 0 && find_trk(idB) < 0) stable = 0;
         }
      }
      {
         char buf[192];
         const int kA = find_trk(idA), kB = find_trk(idB);
         sprintf(buf, "trk=%d idA=%d idB=%d vA16=%d vB16=%d", ctx.n_trk, idA, idB,
                 kA >= 0 ? ctx.trk[kA].vx : -999, kB >= 0 ? ctx.trk[kB].vx : -999);
         check("S1 two targets: count", ctx.n_trk == 2, buf);
         check("S1 two targets: id stable", stable && kA >= 0 && kB >= 0, "");
         check("S1 vel A ~2px/f", kA >= 0 && abs(ctx.trk[kA].vx - 32) <= 10, "");
         check("S1 vel B ~3px/f", kB >= 0 && abs(ctx.trk[kB].vx - 48) <= 10, "");
      }
   }

   /* S2 纵向移动 + 预测 */
   mot_reset(&ctx); bg(fA, 60);
   mot_step(&ctx, &work, fA);
   {
      int id = -1, pred_ok = 1, dir_ok = 1;
      for (f = 0; f < 14; ++f) {
         bg(fA, 60); rect(fA, 40, 8 + f*3, 14, 18, 200);
         mot_step(&ctx, &work, fA);
         if (f >= 6) {
            int k = find_trk(id);
            if (id < 0 && ctx.n_trk > 0) { id = ctx.trk[0].id; k = 0; }
            if (k < 0) pred_ok = 0;
            else {
               const int expect = ctx.trk[k].cy + 6;   /* 再走 2 帧 */
               if (abs(ctx.trk[k].py - expect) > 4) pred_ok = 0;
               if (ctx.trk[k].dir != 4) dir_ok = 0;
            }
         }
      }
      check("S2 vertical: dir=down", dir_ok, "");
      check("S2 pred 2-frame ahead", pred_ok, "");
   }

   /* S3 目标离开：鬼影不产生检测，航迹按时删除 */
   mot_reset(&ctx); bg(fA, 60);
   mot_step(&ctx, &work, fA);
   {
      int ghost_ok = 1;
      for (f = 0; f < 6; ++f) { bg(fA,60); rect(fA, 30 + f*2, 30, 12, 20, 200); mot_step(&ctx,&work,fA); }
      check("S3 track exists", ctx.n_trk == 1, "");
      bg(fA, 60);
      for (f = 0; f < MOT_MAX_MISS + 1; ++f) {
         mot_step(&ctx, &work, fA);
         if (f < 2 && ctx.n_det > 0) ghost_ok = 0;   /* 人走后 2 帧内不应再有检测 */
      }
      check("S3 no ghost detection", ghost_ok, "");
      check("S3 deleted after MAX_MISS", ctx.n_trk == 0, "");
   }

   /* S4 交叉 */
   mot_reset(&ctx); bg(fA, 60);
   mot_step(&ctx, &work, fA);
   {
      for (f = 0; f < 18; ++f) {
         bg(fA, 60);
         rect(fA, 4 + f*4, 30, 10, 24, 200);
         rect(fA, 80 - f*4, 34, 10, 24, 205);
         mot_step(&ctx, &work, fA);
      }
      check("S4 crossing survives", ctx.n_trk >= 1 && ctx.n_trk <= MOT_MAX_TRK, "");
   }

   /* S5 整幅亮变（AGC/开灯）应被面积门限丢弃 */
   mot_reset(&ctx); bg(fA, 60);
   mot_step(&ctx, &work, fA);
   bg(fA, 200);
   mot_step(&ctx, &work, fA);
   check("S5 global change rejected", ctx.n_det == 0, "");

   printf("\nMOT_TESTS %s (fails=%d)\n", fails ? "FAIL" : "PASS", fails);
   return fails ? 1 : 0;
}
