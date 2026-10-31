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
   mot_step(&ctx, &work, fA, 0, 2);
   for (f = 0; f < 5; ++f) mot_step(&ctx, &work, fA, 0, 2);
   check("S0 static: no det", ctx.n_det == 0 && ctx.n_trk == 0, "");

   /* S1 双目标同向右移 2 / 3 px 每帧 */
   mot_reset(&ctx); bg(fA, 60);
   mot_step(&ctx, &work, fA, 0, 2);
   {
      int idA = -1, idB = -1, stable = 1;
      for (f = 0; f < 12; ++f) {
         bg(fA, 60);
         rect(fA, 6 + f*2, 20, 10, 26, 200);
         rect(fA, 54 + f*3, 55, 8, 20, 210);
         mot_step(&ctx, &work, fA, 0, 2);
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
   mot_step(&ctx, &work, fA, 0, 2);
   {
      int id = -1, pred_ok = 1, dir_ok = 1;
      for (f = 0; f < 14; ++f) {
         bg(fA, 60); rect(fA, 40, 8 + f*3, 14, 18, 200);
         mot_step(&ctx, &work, fA, 0, 2);
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
   mot_step(&ctx, &work, fA, 0, 2);
   {
      int ghost_ok = 1;
      for (f = 0; f < 6; ++f) { bg(fA,60); rect(fA, 30 + f*2, 30, 12, 20, 200); mot_step(&ctx,&work,fA, 0, 2); }
      check("S3 track exists", ctx.n_trk == 1, "");
      bg(fA, 60);
      for (f = 0; f < MOT_MAX_MISS + 1; ++f) {
         mot_step(&ctx, &work, fA, 0, 2);
         if (f < 2 && ctx.n_det > 0) ghost_ok = 0;   /* 人走后 2 帧内不应再有检测 */
      }
      check("S3 no ghost detection", ghost_ok, "");
      check("S3 deleted after MAX_MISS", ctx.n_trk == 0, "");
   }

   /* S4 交叉 */
   mot_reset(&ctx); bg(fA, 60);
   mot_step(&ctx, &work, fA, 0, 2);
   {
      for (f = 0; f < 18; ++f) {
         bg(fA, 60);
         rect(fA, 4 + f*4, 30, 10, 24, 200);
         rect(fA, 80 - f*4, 34, 10, 24, 205);
         mot_step(&ctx, &work, fA, 0, 2);
      }
      check("S4 crossing survives", ctx.n_trk >= 1 && ctx.n_trk <= MOT_MAX_TRK, "");
   }

   /* S5 整幅亮变（AGC/开灯）应被面积门限丢弃 */
   mot_reset(&ctx); bg(fA, 60);
   mot_step(&ctx, &work, fA, 0, 2);
   bg(fA, 200);
   mot_step(&ctx, &work, fA, 0, 2);
   check("S5 global change rejected", ctx.n_det == 0, "");

   /* ---------- S6 (Bug1) 静止目标：走进来后站着不动 10 帧不能被鬼影过滤丢掉 ---------- */
   mot_reset(&ctx); bg(fA, 60);
   mot_step(&ctx, &work, fA, 0, 2);
   {
      int id0 = -1, alive = 0, ok = 1;
      for (f = 0; f < 16; ++f) {
         bg(fA, 60);
         if (f >= 2 && f <= 5) rect(fA, 20 + (f - 2) * 6, 30, 16, 30, 200);   /* 走进来（有运动） */
         else if (f > 5) rect(fA, 38, 30, 16, 30, 200);                        /* 站定不动 */
         mot_step(&ctx, &work, fA, 80, 2);
         if (f == 5 && ctx.n_trk > 0) id0 = ctx.trk[0].id;
         if (f > 5) {
            int k = find_trk(id0);
            if (k < 0) { ok = 0; break; }
            if (ctx.trk[k].confirmed) alive++;
         }
      }
      check("S6 static target kept", ok && alive >= 9, "");
   }

   /* ---------- S7 (Bug2) 整幅突变：AI 判无人时 1 帧复位、3 帧内恢复 ---------- */
   mot_reset(&ctx); bg(fA, 60);
   mot_step(&ctx, &work, fA, -100, 0);
   {
      int jump_det = -1, recover_frames = -1, k;
      for (f = 0; f < 3; ++f) { mot_step(&ctx, &work, fA, -100, 0); }      /* 空场稳定 */
      bg(fA, 200);                                                       /* 整幅变亮 */
      mot_step(&ctx, &work, fA, -100, 0);                                   /* ai_p<0 ⇒ 复位背景 */
      jump_det = ctx.n_det;
      for (f = 0; f < 4; ++f) {
         bg(fA, 200);
         rect(fA, 30 + f, 30, 14, 24, 40);                                /* 恢复后有人 */
         mot_step(&ctx, &work, fA, 90, 2);
         if (recover_frames < 0 && ctx.n_det > 0) recover_frames = f + 1;
      }
      k = (recover_frames > 0 && recover_frames <= 3) && jump_det == 0;
      check("S7 full-frame reset recovers <=3f", k, "");
   }

   /* ---------- S8 (Bug3) 目标消失 5 帧后原位重现，ID 不变 ---------- */
   mot_reset(&ctx); bg(fA, 60);
   mot_step(&ctx, &work, fA, -100, 0);
   {
      int id0 = -1, same = 0, gone = 0;
      for (f = 0; f < 5; ++f) {                                          /* 人走动几帧，建立 ID */
         bg(fA, 60); rect(fA, 20 + f * 2, 30, 14, 26, 200);
         mot_step(&ctx, &work, fA, 90, 2);
      }
      if (ctx.n_trk > 0) id0 = ctx.trk[0].id;
      bg(fA, 60);
      for (f = 0; f < 5; ++f) { mot_step(&ctx, &work, fA, -60, 0); gone++; }  /* 消失 5 帧 */
      bg(fA, 60); rect(fA, 28, 30, 14, 26, 200);                          /* 原位重现 */
      mot_step(&ctx, &work, fA, 90, 2);
      if (id0 >= 0) same = (find_trk(id0) >= 0);
      check("S8 same ID after 5-frame gap", same && gone == 5, "");
   }

   /* ---------- S9 (#2) 无支撑航迹：先有支撑确认，再撤掉 AI/红外/运动 → supported=0 ---------- */
   mot_reset(&ctx); bg(fA, 60);
   mot_step(&ctx, &work, fA, -100, 0);
   {
      int k, sup_ok = 0;
      for (f = 0; f < 4; ++f) { bg(fA, 60); rect(fA, 38, 30, 14, 26, 200); mot_step(&ctx, &work, fA, 90, 0); }   /* 有 AI 支撑 */
      for (f = 0; f < 8; ++f) { bg(fA, 60); rect(fA, 38, 30, 14, 26, 200); mot_step(&ctx, &work, fA, -100, 0); } /* 撤掉支撑 */
      if (ctx.n_trk == 0) sup_ok = 1;                      /* 直接删掉也算"不再输出" */
      for (k = 0; k < ctx.n_trk; ++k) if (!ctx.trk[k].supported) sup_ok = 1;
      check("S9 unsupported flagged", sup_ok == 1, "");
   }

   /* ---------- S10 (#3) 相机被移动：整幅前景期间不产生新航迹，稳定后清空 ---------- */
   mot_reset(&ctx); bg(fA, 60);
   mot_step(&ctx, &work, fA, -100, 0);
   {
      int i2, n_before = 0, n_during = 0;
      for (i2 = 0; i2 < 4; ++i2) { bg(fA, 60); rect(fA, 30 + i2, 30, 12, 20, 200); mot_step(&ctx, &work, fA, 90, 2); }
      n_before = ctx.n_trk;
      for (i2 = 0; i2 < 4; ++i2) {                       /* 整幅前景 + 大位移 */
         bg(fA, 40 + i2 * 40);
         mot_step(&ctx, &work, fA, -90, 0);
      }
      n_during = ctx.n_trk;
      for (i2 = 0; i2 < 3; ++i2) { bg(fA, 60); mot_step(&ctx, &work, fA, -90, 0); }
      check("S10 shake: no new track", n_during <= n_before && ctx.n_trk == 0, "");
   }

   /* ---------- S11 (v15) 边缘入场：左边缘首次出现且朝内 → edge_entry=1, eta=1 ---------- */
   mot_reset(&ctx); bg(fA, 60);
   mot_step(&ctx, &work, fA, -100, 0);
   {
      int ok = 0;
      for (f = 0; f < 3; ++f) {
         bg(fA, 60); rect(fA, 4 + f * 3, 34, 12, 26, 200);
         mot_step(&ctx, &work, fA, 90, 2);
      }
      if (ctx.n_trk > 0) ok = (ctx.trk[0].edge_entry == 1) && (ctx.trk[0].eta == 1);
      check("S11 edge entry warns", ok, "");
   }

   /* ---------- S12 (v15) 停止后预测不漂：移动几帧后停住，速度衰减 ---------- */
   mot_reset(&ctx); bg(fA, 60);
   mot_step(&ctx, &work, fA, -100, 0);
   {
      int v_move = 0, v_still = 0;
      for (f = 0; f < 5; ++f) { bg(fA, 60); rect(fA, 20 + f * 6, 34, 12, 26, 200); mot_step(&ctx, &work, fA, 90, 2); }
      if (ctx.n_trk > 0) v_move = ctx.trk[0].vx < 0 ? -ctx.trk[0].vx : ctx.trk[0].vx;
      for (f = 0; f < 3; ++f) { bg(fA, 60); rect(fA, 50, 34, 12, 26, 200); mot_step(&ctx, &work, fA, 90, 2); }
      if (ctx.n_trk > 0) v_still = ctx.trk[0].vx < 0 ? -ctx.trk[0].vx : ctx.trk[0].vx;
      check("S12 stop damps velocity", v_still <= v_move, "");
   }

   /* ---------- S13 (v15) 快走不换号：每帧 10 px 快速移动，ID 保持 ---------- */
   mot_reset(&ctx); bg(fA, 60);
   mot_step(&ctx, &work, fA, -100, 0);
   {
      int id0 = -1, kept = 1;
      for (f = 0; f < 6; ++f) {
         bg(fA, 60); rect(fA, 6 + f * 10, 34, 12, 26, 200);
         mot_step(&ctx, &work, fA, 90, 2);
         if (ctx.n_trk > 0) {
            if (id0 < 0) id0 = ctx.trk[0].id;
            else if (ctx.trk[0].id != id0) kept = 0;
         }
      }
      check("S13 fast walk keeps id", kept && id0 > 0, "");
   }

   printf("\nMOT_TESTS %s (fails=%d)\n", fails ? "FAIL" : "PASS", fails);
   return fails ? 1 : 0;
}
