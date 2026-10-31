/*==============================================================================
 * mot_core.h — 多目标跟踪（IOU Tracker）+ 行为预测      v1.5（按 10/31 任务书重写门控）
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
#ifndef MOT_MAX_MISS
#define MOT_MAX_MISS     6       /* v1.3 Bug3：已确认航迹丢失 6 帧内可复用 ID（2fps ≈3 s） */
#endif
#ifndef MOT_REPORT_MISS
#define MOT_REPORT_MISS  1       /* 丢失超过该帧数就不上报（仍留在表里等重连） */
#endif
#define MOT_CONFIRM_HITS 2       /* 连续命中多少帧算确认目标 */
#define MOT_HORIZON      2       /* 预测前视帧数（2fps → 1 s） */
#define MOT_GATE_PX      16      /* 二级关联：质心距离门限（IOU 全丢失时按速度外推后仍可续轨） */
#define MOT_BG_SHIFT     5       /* 背景更新 α = 1/(1<<5) */
#define MOT_GHOST_DIV    8       /* 连通域内运动像素 < 面积/该值 ⇒ 判鬼影（要求 ≥12.5% 像素在动） */
#define MOT_GHOST_IOU    300     /* v1.3 Bug1：与已确认航迹当前框 IOU ≥ 0.30 时不做鬼影剔除（千分比） */
#define MOT_GHOST_GATE   10      /* v1.3 Bug1：连通域质心距已确认航迹质心 ≤ 该值也不剔除（px） */
#define MOT_MAX_MISS_UNCONF 3    /* v1.3 Bug3：未确认航迹丢失 3 帧即删 */
#define MOT_REID_PX      25      /* 旧 ID 复用半径（px） */
#define MOT_SUP_MAX      3       /* v1.8 #2：连续 3 帧无支撑就不输出/不预警（更严） */
#define MOT_SHAKE_N      3       /* v1.7 #3：连续多少帧整幅前景判为"相机被移动" */
#define MOT_GRAY_TOL     28      /* v1.7 #4：重连时允许的平均灰度差 */
#define MOT_AREA_LO      50      /* v1.7 #4：重连时面积比下限（%） */
#define MOT_AREA_HI      200     /* v1.7 #4：重连时面积比上限（%） */
#define MOT_P_PERSON     60      /* v1.5 Bug1：AI 判人阈值（p>=60 视为人体证据） */
#define MOT_STILL_MAX    20      /* v1.6：仅靠红外豁免时，静止目标最多保 20 帧（≈10 s），防止箱子/家具长期占轨 */
#define MOT_IR_NEED      2       /* v1.5 Bug1：红外 10 帧内热计数阈值（与固件 IR_NEED 对齐） */

/* 行为预测用的 ROI：画面中间 2/3（进入这块才算"进入画面主体"） */
/* ---------------- v15 第三轮开关（默认全开；关掉回到第二轮行为） ---------------- */
#ifndef MOT_V15_SPEED
#define MOT_V15_SPEED    1      /* 速度初始化直接取位移 + 前 3 帧自适应 EMA + 静止衰减 */
#endif
#ifndef MOT_V15_ENTRY
#define MOT_V15_ENTRY    1      /* 边缘入场当帧预警 + ROI 相交判定 */
#endif
#ifndef MOT_V15_MERGE
#define MOT_V15_MERGE    1      /* （预留）检测级/航迹级碎片合并 */
#endif
#ifndef MOT_V15_GATE
#define MOT_V15_GATE     1      /* 二级关联门限随速度与框尺寸自适应 */
#endif
#define MOT_ENTRY_BAND   12     /* 边缘带宽（px，离画面边界） */
#define MOT_GATE_MAX     40     /* 自适应门限上限（px） */

#define MOT_ROI_X0       16
#define MOT_ROI_Y0       16
#define MOT_ROI_X1       80
#define MOT_ROI_Y1       80

typedef struct {
   short x0, y0, x1, y1;   /* 闭区间包围盒 */
   short cx, cy;           /* 质心 */
   short area;
   short mean;             /* v1.7 #4：连通域平均灰度（重连时比对） */
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
   short active;             /* 本帧是否在场（misses <= MOT_REPORT_MISS） */
   short sup;                /* v1.7 #2：连续无支撑帧数 */
   short supported;          /* v1.7 #2：本帧是否有 AI/红外/运动支撑 */
   short mean;               /* v1.7 #4：平均灰度 */
   short still;              /* 连续静止帧数（速度≈0） */
   short eta;              /* 预计还有几帧进入 ROI；-1=不会进/已在 ROI */
   short edge_entry;       /* v15：边缘入场标记（1=首次出现即在边缘带且朝内） */
   short traj_n;
   short traj[MOT_TRAJ_LEN][2];
} mot_trk_t;

typedef struct {
   int n_det;                        /* 本帧有效检测数 */
   int raw_area;                     /* 滤波前最大连通域面积（诊断） */
   short raw_box[4];                 /* v1.3 Bug2：最大连通域包围盒（整幅前景时直接当检测） */
   short raw_cx, raw_cy;
   short big_reset, big_full;        /* v1.5 Bug2 诊断：整幅前景时是 coast 还是复位背景 */
   int ai_p, ir_cnt;                 /* 本帧人体/红外证据 */
   const unsigned char* cur;         /* v1.7 #4：本帧像素（算平均灰度） */
   int shake_cnt;                    /* v1.7 #3：连续整幅前景帧数（相机被移动） */
   short shaking;                    /* v1.7 #3：本帧判定为"相机移动中" */
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

/* v1.3 Bug1：连通域是否与某个"已确认航迹"的当前框重合（IOU≥0.30 或质心足够近） */
static int mot_hit_confirmed(const mot_ctx_t* c, int x0, int y0, int x1, int y1, int cx, int cy,
                              int ai_p, int ir_cnt)
{
   int k;
   for (k = 0; k < c->n_trk; ++k) {
      const mot_trk_t* t = &c->trk[k];
      int ix0, iy0, ix1, iy1;
      if (!t->confirmed) continue;
      /* v1.6 Bug1：AI 明确判人 → 站着不动也保；只靠红外 → 最多保 MOT_STILL_MAX 帧（箱子/家具不会长期占轨） */
      if (!(ai_p >= MOT_P_PERSON || (ir_cnt >= MOT_IR_NEED && t->still <= MOT_STILL_MAX))) continue;
      ix0 = x0 > t->x0 ? x0 : t->x0;
      iy0 = y0 > t->y0 ? y0 : t->y0;
      ix1 = x1 < t->x1 ? x1 : t->x1;
      iy1 = y1 < t->y1 ? y1 : t->y1;
      if (ix1 >= ix0 && iy1 >= iy0) {
         const long inter = (long)(ix1 - ix0 + 1) * (iy1 - iy0 + 1);
         const long ua = (long)(x1 - x0 + 1) * (y1 - y0 + 1)
                       + (long)(t->x1 - t->x0 + 1) * (t->y1 - t->y0 + 1) - inter;
         if (ua > 0 && inter * 1000 / ua >= MOT_GHOST_IOU) return 1;
      }
      {
         int dx = cx - (int)t->cx, dy = cy - (int)t->cy;
         if (dx < 0) dx = -dx;
         if (dy < 0) dy = -dy;
         /* 质心近还要面积可比，否则人体周边的碎片也会被当成"静止目标"放过，导致 ID 碎裂 */
         if ((dx > dy ? dx : dy) <= MOT_GHOST_GATE &&
             (long)(x1 - x0 + 1) * (y1 - y0 + 1) * 2 >= (long)(t->x1 - t->x0 + 1) * (t->y1 - t->y0 + 1)) return 1;
      }
   }
   return 0;
}

/* ---------------- 4) 连通域 ---------------- */
static int mot_label(mot_work_t* w, mot_ctx_t* c)
{
   int i, n = 0;
   c->raw_area = 0;
   memset(w->lab, 0, sizeof(w->lab));
   for (i = 0; i < MOT_N; ++i) {
      int sp = 0, area = 0, mov = 0;
      long sumv = 0;
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
         if (c->cur) sumv += c->cur[p];
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
      if (area > c->raw_area) {
         c->raw_area = area;
         c->raw_box[0] = (short)x0; c->raw_box[1] = (short)y0;
         c->raw_box[2] = (short)x1; c->raw_box[3] = (short)y1;
         c->raw_cx = (short)(sx / area); c->raw_cy = (short)(sy / area);
      }
      if (area < MOT_MIN_AREA || area > MOT_MAX_AREA) continue;
      /* v1.3 Bug1：静止目标（站着不动）没有帧间运动，会被鬼影判据丢掉；
         只要这个连通域和"已确认航迹"的当前框对得上，就跳过鬼影过滤。 */
      if (mov * MOT_GHOST_DIV < area &&
          !mot_hit_confirmed(c, x0, y0, x1, y1, (int)(sx / area), (int)(sy / area), c->ai_p, c->ir_cnt)) continue;
      if (n >= MOT_MAX_DET) continue;
      {
         /* v1.3：同一个人的重复连通域（膨胀后会裂开）只留大的，避免一帧内新建多条航迹 */
         int dup = 0, q;
         for (q = 0; q < n; ++q) {
            const int ix0 = x0 > c->det[q].x0 ? x0 : c->det[q].x0;
            const int iy0 = y0 > c->det[q].y0 ? y0 : c->det[q].y0;
            const int ix1 = x1 < c->det[q].x1 ? x1 : c->det[q].x1;
            const int iy1 = y1 < c->det[q].y1 ? y1 : c->det[q].y1;
            if (ix1 >= ix0 && iy1 >= iy0) {
               const long inter = (long)(ix1 - ix0 + 1) * (iy1 - iy0 + 1);
               const long ua = (long)(x1 - x0 + 1) * (y1 - y0 + 1)
                             + (long)(c->det[q].x1 - c->det[q].x0 + 1) * (c->det[q].y1 - c->det[q].y0 + 1) - inter;
               if (ua > 0 && inter * 1000 / ua >= 500) { dup = 1; break; }
            }
         }
         if (dup) continue;
      }
      c->det[n].x0 = (short)x0; c->det[n].y0 = (short)y0;
      c->det[n].x1 = (short)x1; c->det[n].y1 = (short)y1;
      c->det[n].cx = (short)(sx / area);
      c->det[n].cy = (short)(sy / area);
      c->det[n].area = (short)area;
      c->det[n].mean = (short)(c->cur ? sumv / area : 0);
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
#if MOT_V15_ENTRY
   {
      /* 框与 ROI 相交（占框面积 ≥30%）即视为"已进入"，不再要求质心进 ROI */
      const int ix0 = (t->x0 > MOT_ROI_X0) ? t->x0 : MOT_ROI_X0;
      const int ix1 = (t->x1 < MOT_ROI_X1) ? t->x1 : MOT_ROI_X1;
      const int iy0 = (t->y0 > MOT_ROI_Y0) ? t->y0 : MOT_ROI_Y0;
      const int iy1 = (t->y1 < MOT_ROI_Y1) ? t->y1 : MOT_ROI_Y1;
      const int bw = (int)t->x1 - (int)t->x0 + 1;
      const int bh = (int)t->y1 - (int)t->y0 + 1;
      const int area = bw * bh;
      const int ov = (ix1 >= ix0 && iy1 >= iy0) ? (ix1 - ix0 + 1) * (iy1 - iy0 + 1) : 0;
      if (area > 0 && ov * 100 >= area * 30) return -1;
      if (t->edge_entry && t->supported) return 1;   /* 边缘入场：不等速度收敛 */
   }
#endif
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
#if MOT_V15_SPEED
   /* v15 (1)：首帧直接取位移；第 2~3 帧取 1/2；之后回到 1/4 EMA。
      连续 2 帧位移 < 1.5 px 时速度衰减一半，避免停下后仍沿旧速度外推。 */
   if (t->hits == 0) {
      t->vx = (short)(dx * 16);
      t->vy = (short)(dy * 16);
   } else if (t->hits < 3) {
      t->vx = (short)(((int)t->vx + dx * 16) / 2);
      t->vy = (short)(((int)t->vy + dy * 16) / 2);
   } else {
      t->vx = (short)(((int)t->vx * 3 + dx * 16) / 4);
      t->vy = (short)(((int)t->vy * 3 + dy * 16) / 4);
   }
   {
      const int kx = (dx >= 0) ? dx : -dx;
      const int ky = (dy >= 0) ? dy : -dy;
      if (kx < 2 && ky < 2) {          /* ~<1.5 px/帧 */
         t->vx = (short)(t->vx / 2);
         t->vy = (short)(t->vy / 2);
      }
   }
#else
   t->vx = (short)(((int)t->vx * 3 + dx * 16) / 4);
   t->vy = (short)(((int)t->vy * 3 + dy * 16) / 4);
#endif
   /* 整幅检测（人贴近镜头）不参与速度更新，否则质心跳变会算出几百 px/帧 的假速度 */
   if ((int)(d->x1 - d->x0 + 1) > MOT_W * 4 / 5 && (int)(d->y1 - d->y0 + 1) > MOT_H * 4 / 5) {
      t->vx = (short)0; t->vy = (short)0;
   }
   if (t->vx > -8 && t->vx < 8 && t->vy > -8 && t->vy < 8) { if (t->still < 32000) t->still++; }
   else t->still = 0;
   t->x0 = d->x0; t->y0 = d->y0; t->x1 = d->x1; t->y1 = d->y1;
   t->cx = d->cx; t->cy = d->cy;
#if MOT_V15_ENTRY
   if (t->hits <= 1) {
      const int near_l = (t->x0 <= MOT_ENTRY_BAND);
      const int near_r = (t->x1 >= MOT_W - MOT_ENTRY_BAND);
      const int near_t = (t->y0 <= MOT_ENTRY_BAND);
      const int near_b = (t->y1 >= MOT_H - MOT_ENTRY_BAND);
      const int inward = ((near_l && dx > 0) || (near_r && dx < 0) ||
                          (near_t && dy > 0) || (near_b && dy < 0));
      if ((near_l || near_r || near_t || near_b) && inward) t->edge_entry = 1;
   }
#else
   t->edge_entry = 0;
#endif
   if (t->hits < 32000) t->hits++;
   t->age++;
   t->misses = 0;
   if (t->hits >= MOT_CONFIRM_HITS) t->confirmed = 1;
   t->active = 1;
   t->mean = d->mean;
   /* v1.7 #2：AI 判人 / 红外仍热 / 自身在动 → 有支撑；否则累计无支撑帧数 */
   if (c->ai_p >= MOT_P_PERSON ||
       t->vx <= -24 || t->vx >= 24 || t->vy <= -24 || t->vy >= 24) {
      t->sup = 0;
   } else if (t->sup < 32000) {
      t->sup++;
   }
   t->supported = (t->sup <= MOT_SUP_MAX) ? 1 : 0;
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
            {
               /* v1.7 #4：位置之外再比"大小"和"平均灰度"，减少同一人换号 */
               const int an = (int)(c->det[i].x1 - c->det[i].x0 + 1) * (int)(c->det[i].y1 - c->det[i].y0 + 1);
               const int ao = (int)(c->trk[k].x1 - c->trk[k].x0 + 1) * (int)(c->trk[k].y1 - c->trk[k].y0 + 1);
               const long ratio = (long)an * 100 / (ao > 0 ? ao : 1);
               const int dg = (int)c->det[i].mean - (int)c->trk[k].mean;
               const int dga = dg < 0 ? -dg : dg;
               if (ratio < MOT_AREA_LO || ratio > MOT_AREA_HI) continue;
               if (dga > MOT_GRAY_TOL) continue;
            }
            if (d < best) { best = d; bd = i; bt = k; }
         }
      }
      if (bd < 0) break;
      {
         /* v1.3 Bug3：刚丢的已确认航迹用更大的重连半径（25 px），避免同一个人换号 */
         const int lost = c->trk[bt].misses;
      #if MOT_V15_GATE
   int gate;
   if (c->trk[bt].confirmed && lost > 0) {
      gate = MOT_REID_PX;
   } else {
      const int sp = abs((int)c->trk[bt].vx) > abs((int)c->trk[bt].vy) ? abs((int)c->trk[bt].vx) : abs((int)c->trk[bt].vy);
      const int rad = ((int)c->trk[bt].x1 - (int)c->trk[bt].x0 + (int)c->trk[bt].y1 - (int)c->trk[bt].y0) / 4;
      int g = 16 + (sp * 3) / 2 + (rad * 3) / 10;
      if (g < MOT_GATE_PX) g = MOT_GATE_PX;
      if (g > MOT_GATE_MAX) g = MOT_GATE_MAX;
      gate = g;
   }
#else
   const int gate = (c->trk[bt].confirmed && lost > 0) ? MOT_REID_PX : MOT_GATE_PX;
#endif
         if (best > gate) break;
      }
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
      t->active = (t->misses <= MOT_REPORT_MISS) ? 1 : 0;
      if (c->ai_p >= MOT_P_PERSON) t->sup = 0;
      else if (t->sup < 32000) t->sup++;
      t->supported = (t->sup <= MOT_SUP_MAX) ? 1 : 0;
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
      t->hits = 1; t->age = 1; t->traj_n = 1; t->active = 1; t->supported = 1; t->mean = c->det[i].mean;
      t->traj[0][0] = t->cx; t->traj[0][1] = t->cy;
   }

   /* 删除丢失过久的航迹 */
   {
      int wr = 0;
      for (k = 0; k < c->n_trk; ++k) {
         const int miss_limit = c->trk[k].confirmed ? MOT_MAX_MISS : MOT_MAX_MISS_UNCONF;
         if (c->trk[k].misses > miss_limit) continue;
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

/* 当前在场的确认航迹数（丢失中的不算） */
static int mot_active_confirmed(const mot_ctx_t* c)
{
   int k, n = 0;
   for (k = 0; k < c->n_trk; ++k) {
      if (c->trk[k].confirmed && c->trk[k].active) n++;
   }
   return n;
}

/* 在动且已确认的航迹数（静止的箱子/家具不算"人体证据"） */
static int mot_moving_confirmed(const mot_ctx_t* c)
{
   int k, n = 0;
   for (k = 0; k < c->n_trk; ++k) {
      if (c->trk[k].confirmed && c->trk[k].active && c->trk[k].still <= 6) n++;
   }
   return n;
}

/* 一站式：返回本帧航迹数
 * ai_p：本帧 AI 人体分数（int8，-128..127）；<0 视为"AI 判无人"，>=0 视为"AI 判有人"。
 *       v1.3 Bug2 用它决定"整幅前景"是光照突变（重置背景）还是人贴近镜头（输出整幅检测）。 */
static int mot_step(mot_ctx_t* c, mot_work_t* w, const unsigned char* cur, int ai_p, int ir_cnt)
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
   c->big_reset = 0; c->big_full = 0;
   c->ai_p = ai_p; c->ir_cnt = ir_cnt;
   c->cur = cur;
   mot_foreground(c, w, cur);
   mot_label(w, c);

   /* v1.5 Bug2：整幅前景（面积 > MOT_MAX_AREA）——
      不再丢帧、不再指望 1/128 的背景更新自己恢复：
      · 沿用上一帧的轨迹做预测（coast），本帧不产生新检测；
      · 只有 AI 判无人 且 红外也不热 时，才把背景快速重置为当前帧。 */
   /* v1.7 #3：整幅大位移 = 相机被移动。期间不出新航迹、不预警，画面稳定后再重建背景与航迹。 */
   if (c->raw_area > MOT_MAX_AREA) {
      c->shake_cnt++;
   } else {
      if (c->shake_cnt >= MOT_SHAKE_N) {
         c->n_trk = 0;              /* 抖完重建：丢掉抖动期间的全部航迹 */
         c->next_id = c->next_id < 1000 ? c->next_id : 1;
         c->big_reset = 1;
      }
      c->shake_cnt = 0;
   }
   c->shaking = (c->shake_cnt >= MOT_SHAKE_N) ? 1 : 0;

   if (c->raw_area > MOT_MAX_AREA) {
      c->n_det = 0;
      c->last_area = 0;
      c->big_full = 1;
      if (ai_p < 0 && ir_cnt < MOT_IR_NEED) {
         memcpy(c->bg, cur, MOT_N);
         memcpy(c->prev, cur, MOT_N);
         c->have_prev = 1;
         c->big_reset = 1;
      }
      if (c->n_trk > MOT_MAX_TRK) c->n_trk = MOT_MAX_TRK;
      mot_associate(c);          /* n_det=0 ⇒ 所有航迹按速度外推（coast） */
      c->frame++;
      return c->n_trk;
   }

   mot_bg_update(c, w, cur);
   if (c->n_trk > MOT_MAX_TRK) c->n_trk = MOT_MAX_TRK;
   mot_associate(c);
   c->frame++;
   return c->n_trk;
}

#endif /* MOT_CORE_H */
