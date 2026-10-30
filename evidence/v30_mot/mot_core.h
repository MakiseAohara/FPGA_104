/*==============================================================================
 * mot_core.h — 多目标跟踪（IOU Tracker）+ 行为预测      v1.1
 *
 * 纯 C（无平台依赖、无动态内存），固件与电脑端测试共用。
 * 输入：每帧 96x96 uint8 灰度（固件里就是 AI 输入的那张图，字节原样 u）
 * 输出：多目标轨迹（稳定 ID）/ 速度向量 / 下一位置预测 / 到达 ROI 的剩余帧数
 *
 * 处理链：
 *   1) 背景建模：bg += (cur-bg)>>BG_SHIFT（α=1/32，与 RTL 帧差背景同思路），
 *      整幅均值补偿掉 AGC/增益跳变，避免误检整幅
 *   2) 前景：mask = |cur-bg| >= MOT_DIFF_THR，再做 3x3 膨胀把人体合成整块
 *   3) 鬼影剔除：连通域内"当前帧差分"像素太少 ⇒ 是背景残留（人走了），丢弃
 *   4) 连通域：4 邻域 flood fill（栈式，无递归），按面积降序取前 MOT_MAX_DET 个
 *   5) 关联：检测框 ∩ 航迹框 IOU 贪心匹配（阈值 MOT_IOU_THR 千分比）
 *   6) 速度：质心位移的 EMA（Q4 定点，16 = 1 px/帧）
 *   7) 预测：pred = 质心 + v*MOT_HORIZON（默认 2 帧 ≈ 1 s @2fps）
 *
 * 单位：坐标/面积是 96x96 网格上的像素；速度 Q4（右移 4 位得 px/帧）。
 *============================================================================*/
#ifndef MOT_CORE_H
#define MOT_CORE_H

#include <string.h>

#define MOT_W            96
#define MOT_H            96
#define MOT_N            (MOT_W * MOT_H)

#define MOT_MAX_DET      6
#define MOT_MAX_TRK      4
#define MOT_TRAJ_LEN     12      /* 每目标保留的轨迹点数 */

#define MOT_DIFF_THR     14      /* 与背景的差阈值（拉伸后画面） */
#define MOT_MOTION_THR   10      /* 帧间差分阈值（鬼影剔除用） */
#define MOT_MIN_AREA     60      /* 最小目标面积（膨胀后 px）：暗场噪点约 20-50 */
#define MOT_MAX_AREA     9000    /* 最大目标面积：人贴近镜头可占整幅九成，只有"整幅全变"才丢 */
#define MOT_IOU_THR      200     /* IOU 阈值，千分比（200 = 0.20） */
#define MOT_MAX_MISS     3       /* 连续丢失多少帧后删航迹（2fps ≈1.5 s） */
#define MOT_CONFIRM_HITS 2       /* 连续命中多少帧算确认目标 */
#define MOT_HORIZON      2       /* 预测前视帧数（2fps → 1 s） */
#define MOT_GATE_PX      16      /* 二级关联：质心距离门限（IOU 全丢失时按速度外推后仍可续轨） */
#define MOT_BG_SHIFT     5       /* 背景更新 α = 1/(1<<5) */
#define MOT_GHOST_DIV    8       /* 连通域内运动像素 < 面积/该值 ⇒ 判鬼影（要求 ≥12.5% 像素在动） */

/* 行为预测用的 ROI：画面中间 2/3（进入这块才算"进入画面主体"） */
#define MOT_ROI_X0       16
#define MOT_ROI_Y0       16
#define MOT_ROI_X1       80
#define MOT_ROI_Y1       80

typedef struct {
   short x0, y0, x1, y1;   /* 闭区间包围盒 */
   short cx, cy;           /* 质心 */
   short area;
} mot_det_t;

typedef struct {
   short id;
   short x0, y0, x1, y1;   /* 当前框 */
   short cx, cy;           /* 当前质心 */
   short vx, vy;           /* 速度 Q4（px/帧 ×16） */
   short px, py;           /* 前视预测位置（质心 + v*HORIZON） */
   short dir;              /* 0=静止 1=左 2=右 3=上 4=下 5=斜移 */
   short hits, misses, age;
   short confirmed;
   short eta;              /* 预计还有几帧进入 ROI；-1=不会进/已在 ROI */
   short traj_n;
   short traj[MOT_TRAJ_LEN][2];
} mot_trk_t;

typedef struct {
   int n_det;                        /* 本帧有效检测数 */
   int raw_area;                     /* 滤波前最大连通域面积（诊断） */
   mot_det_t det[MOT_MAX_DET];
   int n_trk;                        /* 当前航迹数（含未确认） */
   mot_trk_t trk[MOT_MAX_TRK];
   int next_id;
   int frame;
   int last_area;
   unsigned char bg[MOT_N];          /* 背景模型 */
   unsigned char prev[MOT_N];        /* 上一帧（鬼影剔除用） */
   int have_prev;
} mot_ctx_t;

typedef struct {
   unsigned char mask[MOT_N];
   unsigned char dmask[MOT_N];
   unsigned char lab[MOT_N];
   short stack[MOT_N];
} mot_work_t;

static void mot_reset(mot_ctx_t* c)
{
   if (!c) return;
   c->n_det = 0; c->n_trk = 0; c->next_id = 1; c->frame = 0;
   c->last_area = 0; c->have_prev = 0;
   memset(c->trk, 0, sizeof(c->trk));
}

/* ---------------- 1)+2) 背景差分 → 前景 mask ---------------- */
static void mot_foreground(mot_ctx_t* c, mot_work_t* w, const unsigned char* cur)
{
   int i, x, y;
   long sc = 0, sb = 0;
   int delta;

   for (i = 0; i < MOT_N; ++i) { sc += cur[i]; sb += c->bg[i]; }
   delta = (int)((sc - sb) / MOT_N);              /* 整幅亮度补偿 */

   for (i = 0; i < MOT_N; ++i) {
      int b = (int)c->bg[i] + delta;
      int d;
      if (b < 0) b = 0; if (b > 255) b = 255;
      d = (int)cur[i] - b;
      w->mask[i] = ((d >= MOT_DIFF_THR) || (d <= -MOT_DIFF_THR)) ? 1u : 0u;
      if (c->have_prev) {
         int m = (int)cur[i] - (int)c->prev[i];
         w->dmask[i] = ((m >= MOT_MOTION_THR) || (m <= -MOT_MOTION_THR)) ? 1u : 0u;
      } else {
         w->dmask[i] = 0u;
      }
   }

   /* 3x3 膨胀：把人体边缘的碎片合成整块（两邻域已够，避免收成骨架） */
   for (y = 1; y < MOT_H - 1; ++y) {
      const int row = y * MOT_W;
      for (x = 1; x < MOT_W - 1; ++x) {
         const int i = row + x;
         if (w->mask[i]) continue;
         /* 只看种子（==1），不把本次膨胀出来的 2 当种子，否则会沿扫描方向级联填满 */
         if (w->mask[i-1] == 1u || w->mask[i+1] == 1u ||
             w->mask[i-MOT_W] == 1u || w->mask[i+MOT_W] == 1u)
            w->mask[i] = 2u;                      /* 2 = 膨胀补出来的，稍后统一成 1 */
      }
   }
   for (i = 0; i < MOT_N; ++i) if (w->mask[i] == 2u) w->mask[i] = 1u;
}

/* 背景更新：在"被判为背景"的像素上快速跟上，前景像素上慢速（保留记忆） */
static void mot_bg_update(mot_ctx_t* c, mot_work_t* w, const unsigned char* cur)
{
   int i;
   for (i = 0; i < MOT_N; ++i) {
      const int b = (int)c->bg[i];
      const int d = (int)cur[i] - b;
      const int sh = w->mask[i] ? (MOT_BG_SHIFT + 2) : MOT_BG_SHIFT;
      c->bg[i] = (unsigned char)(b + (d >> sh));
   }
   memcpy(c->prev, cur, MOT_N);
   c->have_prev = 1;
}

/* ---------------- 4) 连通域 ---------------- */
static int mot_label(mot_work_t* w, mot_ctx_t* c)
{
   int i, n = 0;
   c->raw_area = 0;
   memset(w->lab, 0, sizeof(w->lab));
   for (i = 0; i < MOT_N; ++i) {
      int sp = 0, area = 0, mov = 0;
      int x0 = MOT_W, y0 = MOT_H, x1 = -1, y1 = -1;
      long sx = 0, sy = 0;
      if (!w->mask[i] || w->lab[i]) continue;
      w->lab[i] = 1;
      w->stack[sp++] = (short)i;
      while (sp > 0) {
         const int p = w->stack[--sp];
         const int px = p % MOT_W, py = p / MOT_W;
         area++;
         if (w->dmask[p]) mov++;
         sx += px; sy += py;
         if (px < x0) x0 = px;
         if (px > x1) x1 = px;
         if (py < y0) y0 = py;
         if (py > y1) y1 = py;
         {
            const int nb[4] = { p - 1, p + 1, p - MOT_W, p + MOT_W };
            const int ok[4] = { px > 0, px < MOT_W - 1, py > 0, py < MOT_H - 1 };
            int k;
            for (k = 0; k < 4; ++k) {
               const int q = nb[k];
               if (ok[k] && w->mask[q] && !w->lab[q]) {
                  w->lab[q] = 1;
                  w->stack[sp++] = (short)q;
               }
            }
         }
      }
      if (area > c->raw_area) c->raw_area = area;
      if (area < MOT_MIN_AREA || area > MOT_MAX_AREA) continue;
      if (mov * MOT_GHOST_DIV < area) continue;        /* 鬼影：没有当前运动 */
      if (n >= MOT_MAX_DET) continue;
      c->det[n].x0 = (short)x0; c->det[n].y0 = (short)y0;
      c->det[n].x1 = (short)x1; c->det[n].y1 = (short)y1;
      c->det[n].cx = (short)(sx / area);
      c->det[n].cy = (short)(sy / area);
      c->det[n].area = (short)area;
      n++;
   }
   {
      int a, b;
      for (a = 0; a < n; ++a) for (b = a + 1; b < n; ++b) {
         if (c->det[b].area > c->det[a].area) {
            const mot_det_t t = c->det[a];
            c->det[a] = c->det[b];
            c->det[b] = t;
         }
      }
   }
   c->n_det = n;
   c->last_area = (n > 0) ? (int)c->det[0].area : 0;
   return n;
}

/* ---------------- IOU（千分比） ---------------- */
static int mot_iou(const mot_det_t* a, const short* b)
{
   const int ix0 = a->x0 > b[0] ? a->x0 : b[0];
   const int iy0 = a->y0 > b[1] ? a->y0 : b[1];
   const int ix1 = a->x1 < b[2] ? a->x1 : b[2];
   const int iy1 = a->y1 < b[3] ? a->y1 : b[3];
   int inter, ua;
   if (ix1 < ix0 || iy1 < iy0) return 0;
   inter = (ix1 - ix0 + 1) * (iy1 - iy0 + 1);
   ua = (int)a->area + (b[2] - b[0] + 1) * (b[3] - b[1] + 1) - inter;
   if (ua <= 0) return 0;
   return inter * 1000 / ua;
}

/* ---------------- 5)~7) 关联 / 生命周期 / 速度 / 预测 ---------------- */
static int mot_eta_frames(const mot_trk_t* t)
{
   /* 已在 ROI 内 → -1（不需要"提前"响应） */
   const int in_x = (t->cx >= MOT_ROI_X0 && t->cx <= MOT_ROI_X1);
   const int in_y = (t->cy >= MOT_ROI_Y0 && t->cy <= MOT_ROI_Y1);
   int k;
   if (in_x && in_y) return -1;
   for (k = 1; k <= MOT_HORIZON + 4; ++k) {
      const int x = (int)t->cx + ((int)t->vx * k) / 16;
      const int y = (int)t->cy + ((int)t->vy * k) / 16;
      if (x >= MOT_ROI_X0 && x <= MOT_ROI_X1 && y >= MOT_ROI_Y0 && y <= MOT_ROI_Y1)
         return (short)k;
      if (x < 0 || x >= MOT_W || y < 0 || y >= MOT_H) break;
   }
   return -1;
}

/* 命中后更新航迹（速度 = 质心位移 EMA，Q4） */
static void mot_update_track(mot_ctx_t* c, int bt, int bd)
{
   mot_trk_t* t = &c->trk[bt];
   const mot_det_t* d = &c->det[bd];
   const int dx = (int)d->cx - (int)t->cx;
   const int dy = (int)d->cy - (int)t->cy;
   t->vx = (short)(((int)t->vx * 3 + dx * 16) / 4);
   t->vy = (short)(((int)t->vy * 3 + dy * 16) / 4);
   t->x0 = d->x0; t->y0 = d->y0; t->x1 = d->x1; t->y1 = d->y1;
   t->cx = d->cx; t->cy = d->cy;
   if (t->hits < 32000) t->hits++;
   t->age++;
   t->misses = 0;
   if (t->hits >= MOT_CONFIRM_HITS) t->confirmed = 1;
   if (t->traj_n >= MOT_TRAJ_LEN) {
      memmove(&t->traj[0][0], &t->traj[1][0], sizeof(short) * 2 * (MOT_TRAJ_LEN - 1));
      t->traj_n = MOT_TRAJ_LEN - 1;
   }
   t->traj[t->traj_n][0] = t->cx;
   t->traj[t->traj_n][1] = t->cy;
   t->traj_n++;
}

/* 用当前速度把航迹框外推 k 帧（k 用 Q4 定点 16=1 帧），写进 b4 并返回预测质心 */
static void mot_predict_box(const mot_trk_t* t, int kq4, short* b4, int* pcx, int* pcy)
{
   const int sx = ((int)t->vx * kq4) / (16 * 16);
   const int sy = ((int)t->vy * kq4) / (16 * 16);
   b4[0] = (short)(t->x0 + sx); b4[1] = (short)(t->y0 + sy);
   b4[2] = (short)(t->x1 + sx); b4[3] = (short)(t->y1 + sy);
   *pcx = (int)t->cx + sx;
   *pcy = (int)t->cy + sy;
}

static int mot_iou4(const mot_det_t* d, const short* b4)
{
   const int ix0 = d->x0 > b4[0] ? d->x0 : b4[0];
   const int iy0 = d->y0 > b4[1] ? d->y0 : b4[1];
   const int ix1 = d->x1 < b4[2] ? d->x1 : b4[2];
   const int iy1 = d->y1 < b4[3] ? d->y1 : b4[3];
   int inter, ua;
   if (ix1 < ix0 || iy1 < iy0) return 0;
   inter = (ix1 - ix0 + 1) * (iy1 - iy0 + 1);
   ua = inter + (int)d->area + (b4[2] - b4[0] + 1) * (b4[3] - b4[1] + 1) - inter;
   if (ua <= 0) return 0;
   return inter * 1000 / ua;
}

static void mot_associate(mot_ctx_t* c)
{
   static unsigned char det_used[MOT_MAX_DET];
   static unsigned char trk_used[MOT_MAX_TRK];
   int i, k, pass;

   for (i = 0; i < c->n_det; ++i) det_used[i] = 0;
   for (i = 0; i < c->n_trk; ++i) trk_used[i] = 0;

   /* ---- 一级：与"按速度外推一帧"的框算 IOU，贪心取最大 ---- */
   for (pass = 0; pass < MOT_MAX_DET * MOT_MAX_TRK; ++pass) {
      int best = -1, bd = -1, bt = -1;
      for (k = 0; k < c->n_trk; ++k) {
         short b4[4]; int pcx, pcy;
         if (trk_used[k]) continue;
         mot_predict_box(&c->trk[k], 16, b4, &pcx, &pcy);   /* 外推 1 帧 */
         for (i = 0; i < c->n_det; ++i) {
            int v;
            if (det_used[i]) continue;
            v = mot_iou4(&c->det[i], b4);
            if (v > best) { best = v; bd = i; bt = k; }
         }
      }
      if (best < MOT_IOU_THR) break;
      det_used[bd] = 1; trk_used[bt] = 1;
      mot_update_track(c, bt, bd);
   }

   /* ---- 二级（v1.2）：IOU 全丢（人走得太快/帧间隔太大）时，按"预测质心距离"续轨 ---- */
   for (pass = 0; pass < MOT_MAX_DET * MOT_MAX_TRK; ++pass) {
      int best = 1 << 20, bd = -1, bt = -1;
      for (k = 0; k < c->n_trk; ++k) {
         short b4[4]; int pcx, pcy;
         if (trk_used[k]) continue;
         mot_predict_box(&c->trk[k], 16, b4, &pcx, &pcy);
         for (i = 0; i < c->n_det; ++i) {
            int dx, dy, d;
            if (det_used[i]) continue;
            dx = (int)c->det[i].cx - pcx;
            dy = (int)c->det[i].cy - pcy;
            if (dx < 0) dx = -dx;
            if (dy < 0) dy = -dy;
            d = (dx > dy ? dx : dy) + ((dx + dy) >> 2);       /* 近似欧氏距离 */
            if (d < best) { best = d; bd = i; bt = k; }
         }
      }
      if (bd < 0 || best > MOT_GATE_PX) break;
      det_used[bd] = 1; trk_used[bt] = 1;
      mot_update_track(c, bt, bd);
   }

   /* 未匹配航迹：丢失 + 按速度外推（人走两步再回来仍保留 ID） */
   /* 未匹配航迹：丢失 + 按速度外推（人走两步再回来仍保留 ID） */
   for (k = 0; k < c->n_trk; ++k) {
      mot_trk_t* t = &c->trk[k];
      if (trk_used[k]) continue;
      if (t->misses < 32000) t->misses++;
      t->age++;
      {
         const int dcx = (int)t->cx + (int)t->vx / 16;
         const int dcy = (int)t->cy + (int)t->vy / 16;
         const int px = dcx - (t->x0 + t->x1) / 2;
         const int py = dcy - (t->y0 + t->y1) / 2;
         t->x0 = (short)(t->x0 + px); t->x1 = (short)(t->x1 + px);
         t->y0 = (short)(t->y0 + py); t->y1 = (short)(t->y1 + py);
         t->cx = (short)(dcx < 0 ? 0 : (dcx > MOT_W - 1 ? MOT_W - 1 : dcx));
         t->cy = (short)(dcy < 0 ? 0 : (dcy > MOT_H - 1 ? MOT_H - 1 : dcy));
         if (t->x0 < 0) t->x0 = 0;
         if (t->y0 < 0) t->y0 = 0;
         if (t->x1 > MOT_W - 1) t->x1 = MOT_W - 1;
         if (t->y1 > MOT_H - 1) t->y1 = MOT_H - 1;
      }
   }

   /* 未匹配检测：新建航迹 */
   for (i = 0; i < c->n_det; ++i) {
      mot_trk_t* t;
      if (det_used[i]) continue;
      if (c->n_trk >= MOT_MAX_TRK) {
         int victim = -1, j;
         for (j = 0; j < c->n_trk; ++j) if (!c->trk[j].confirmed) { victim = j; break; }
         if (victim < 0) continue;
         memmove(&c->trk[victim], &c->trk[victim + 1], sizeof(mot_trk_t) * (MOT_MAX_TRK - victim - 1));
         c->n_trk--;
      }
      t = &c->trk[c->n_trk++];
      memset(t, 0, sizeof(*t));
      t->id = (short)c->next_id++;
      t->x0 = c->det[i].x0; t->y0 = c->det[i].y0;
      t->x1 = c->det[i].x1; t->y1 = c->det[i].y1;
      t->cx = c->det[i].cx; t->cy = c->det[i].cy;
      t->hits = 1; t->age = 1; t->traj_n = 1;
      t->traj[0][0] = t->cx; t->traj[0][1] = t->cy;
   }

   /* 删除丢失过久的航迹 */
   {
      int wr = 0;
      for (k = 0; k < c->n_trk; ++k) {
         if (c->trk[k].misses > MOT_MAX_MISS) continue;
         if (wr != k) c->trk[wr] = c->trk[k];
         wr++;
      }
      c->n_trk = wr;
   }

   /* 预测 + 方向 + ROI 到达时间 */
   for (k = 0; k < c->n_trk; ++k) {
      mot_trk_t* t = &c->trk[k];
      const int ax = (int)t->vx, ay = (int)t->vy;
      t->px = (short)((int)t->cx + (ax * MOT_HORIZON) / 16);
      t->py = (short)((int)t->cy + (ay * MOT_HORIZON) / 16);
      if (ax > -8 && ax < 8 && ay > -8 && ay < 8) t->dir = 0;
      else if ((ax >= 8 || ax <= -8) && (ay >= 8 || ay <= -8)) t->dir = 5;
      else if (ax >= 8) t->dir = 2;
      else if (ax <= -8) t->dir = 1;
      else if (ay <= -8) t->dir = 3;
      else t->dir = 4;
      t->eta = (short)mot_eta_frames(t);
   }
}

/* 一站式：返回本帧航迹数 */
static int mot_step(mot_ctx_t* c, mot_work_t* w, const unsigned char* cur)
{
   if (!c || !w || !cur) return 0;
   if (!c->have_prev && c->frame == 0) {
      /* 第一帧：只建背景 */
      memcpy(c->bg, cur, MOT_N);
      memcpy(c->prev, cur, MOT_N);
      c->have_prev = 1;
      c->frame++;
      return 0;
   }
   mot_foreground(c, w, cur);
   mot_label(w, c);
   mot_bg_update(c, w, cur);
   if (c->n_trk > MOT_MAX_TRK) c->n_trk = MOT_MAX_TRK;
   mot_associate(c);
   c->frame++;
   return c->n_trk;
}

#endif /* MOT_CORE_H */
