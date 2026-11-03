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
#define MOT_MAX_TRK      2       /* v2.1：现场最多 2 人；4 会容纳超分割产生的虚警轨（3~4群 占 22~27%） */
#define MOT_TRAJ_LEN     12      /* 每目标保留的轨迹点数 */

#define MOT_DIFF_THR     14      /* 与背景的差阈值（拉伸后画面） */
#define MOT_MOTION_THR   10      /* 帧间差分阈值（鬼影剔除用） */
#ifndef MOT_MERGE_PX
#define MOT_MERGE_PX        14   /* v2.0：两条航迹质心距离 <= 该值（px）且面积相近 => 合并 */
#endif
#ifndef MOT_NEWTRK_IOU
#define MOT_NEWTRK_IOU   320   /* 千分比：新检测与已确认航迹（含外推框）IoU >= 该值 => 视为同一目标，不再新建航迹 */
#endif
#ifndef MOT_MERGE_IOU
#define MOT_MERGE_IOU     300   /* 千分比：旧判据（对切分两半恒不触发，已废弃，仅保留作关闭开关） */
#define MOT_MERGE_Y_OVERLAP 80  /* v2.1：两框竖向带交叠 >= 较小框高度的 80% 才并 */
#endif
#ifndef MOT_MERGE_AREA_HI
#define MOT_MERGE_AREA_HI  170   /* v2.0：面积比上限（%） */
#endif
#ifndef MOT_MERGE_ADJ_GAP
#define MOT_MERGE_ADJ_GAP   0    /* v3.10：切分两半的水平间隙上限（px），<=0 关闭该判据 */
#endif
#ifndef MOT_SPLIT_MIN_SEP
#define MOT_SPLIT_MIN_SEP    12  /* v2.0：切开后左右两半质心至少相距该值（px），否则不切（v2.1: 9->12，减少超分割） */
#endif
#ifndef MOT_SPLIT_HALF_H
#define MOT_SPLIT_HALF_H    60   /* v2.0：切开后每一半高度 >= 整块高度的 60% 才认 */
#endif
#ifndef MOT_SPLIT_MIN_W
#define MOT_SPLIT_MIN_W  20
#endif      /* v1.9：宽度 >= 该值的连通域才尝试"两人粘连"切分 */
#ifndef MOT_SPLIT_MIN_ASPECT
#define MOT_SPLIT_MIN_ASPECT 70  /* 宽度/高度 >= 70% 才认为"像两个人并肩"（单人约 30~40%） */
#endif
#ifndef MOT_SPLIT_MAX_ASPECT
#define MOT_SPLIT_MAX_ASPECT 170 /* 宽度/高度 <= 170%：再宽就是背景墙条，不是两个并肩的人 */
#endif
#ifndef MOT_SPLIT_MIN_H
#define MOT_SPLIT_MIN_H  12
#endif
#define MOT_SPLIT_VALLEY 45      /* 谷深：切分列像素数 <= 峰值 * 45%（v2.1: 35->45，要求更明显的谷才切） */
#define MOT_MIN_AREA     60      /* 最小目标面积（膨胀后 px）：暗场噪点约 20-50 */
#define MOT_MIN_PERSON_AREA 150  /* v3.6：页面"人数"只数面积达标的框（<150 是噪点/反光） */
#define MOT_MIN_PERSON_H    12   /* v3.6：且高度 >=12（96 格里 12.5%，8 m 外的人也比他高） */
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
/* v3.11：ETA/提前唤醒专用关注区（画面中段），与"报警区"解耦 —— 报警区是整幅，
   但"预测还有几帧进入关注区"必须有一个有限的目标区，否则 eta 恒为 -1。 */
/* v17：靠近镜头 -> 预测到"贴脸"的帧数（离线实测：面积增长比质心速度稳） */
#ifndef MOT_NEAR_PCT
#define MOT_NEAR_PCT    55
#endif
#ifndef MOT_ARATE_MIN
#define MOT_ARATE_MIN   6
#endif
/* v17.1（默认关闭，等有操作者的两次上板对比再开）：
   关联门限随目标尺寸放大 —— 整幅框(96 高)的人一步能跳出 MOT_GATE_PX=16，旧门限必然换号。
   MOT_GATE_SIZE_DIV = 3 表示 gate = max(MOT_GATE_PX, 框宽/3)。 */
#ifndef MOT_GATE_SIZE_DIV
#define MOT_GATE_SIZE_DIV 0
#endif
#ifndef MOT_PRED_DAMP_N
#define MOT_PRED_DAMP_N 1     /* 预测速度阻尼 1/2：离线 37 条航迹实测，误差中位 5.0 px vs 静止 6.0 px */
#endif
#ifndef MOT_PRED_DAMP_D
#define MOT_PRED_DAMP_D 2
#endif
#ifndef MOT_ETA_X0
#define MOT_ETA_X0      24
#define MOT_ETA_Y0      24
#define MOT_ETA_X1      72
#define MOT_ETA_Y1      72
#endif

#define MOT_ROI_X0       0       /* v3.0: 报警区扩到整幅（原 16..80 只认中心） */
#define MOT_ROI_Y0       0
#define MOT_ROI_X1       95
#define MOT_ROI_Y1       95

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
   short area;               /* v3.11：上一帧面积（判"正在靠近"） */
   short grow;               /* v3.11：连续面积增长帧数 */
   short arate;              /* v17：面积增长率 EMA（%/帧），用于"还有几帧贴脸" */
   short full;               /* v3.6：整幅检测（>80% 宽且 >80% 高）——光照突变，不是人 */
   short eta;              /* 预计还有几帧进入 ROI；-1=不会进/已在 ROI */
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
#ifdef MOT_TEST_DEBUG
typedef struct { int calls, area_rej, ghost_rej, dup_rej, ok, last_mov, last_area, last_split, merged, t_pair, t_dist, t_area, t_iou; } mot_dbg_t;
static mot_dbg_t mot_dbg;
#endif
static int mot_push_det(mot_ctx_t* c, int x0, int y0, int x1, int y1,
                        int area, long sumx, long sumy, long sumv, int mov)
{
   int q, n = c->n_det;
#ifdef MOT_TEST_DEBUG
   mot_dbg.calls++; mot_dbg.last_mov = mov; mot_dbg.last_area = area;
#endif
   if (area < MOT_MIN_AREA || area > MOT_MAX_AREA) {
#ifdef MOT_TEST_DEBUG
      mot_dbg.area_rej++;
#endif
      return 0;
   }
   /* v1.3 Bug1：静止目标（站着不动）没有帧间运动，会被鬼影判据丢掉；
      只要这个连通域和"已确认航迹"的当前框对得上，就跳过鬼影过滤。 */
   if (mov * MOT_GHOST_DIV < area &&
       !mot_hit_confirmed(c, x0, y0, x1, y1, (int)(sumx / area), (int)(sumy / area),
                          c->ai_p, c->ir_cnt)) {
#ifdef MOT_TEST_DEBUG
      mot_dbg.ghost_rej++;
#endif
      return 0;
   }
   if (n >= MOT_MAX_DET) return 0;
   for (q = 0; q < n; ++q) {
      /* v1.3：同一个人的重复连通域（膨胀后会裂开）只留大的，避免一帧内新建多条航迹 */
      const int ix0 = x0 > c->det[q].x0 ? x0 : c->det[q].x0;
      const int iy0 = y0 > c->det[q].y0 ? y0 : c->det[q].y0;
      const int ix1 = x1 < c->det[q].x1 ? x1 : c->det[q].x1;
      const int iy1 = y1 < c->det[q].y1 ? y1 : c->det[q].y1;
      if (ix1 >= ix0 && iy1 >= iy0) {
         const long inter = (long)(ix1 - ix0 + 1) * (iy1 - iy0 + 1);
         const long ua = (long)(x1 - x0 + 1) * (y1 - y0 + 1)
                       + (long)(c->det[q].x1 - c->det[q].x0 + 1)
                         * (long)(c->det[q].y1 - c->det[q].y0 + 1) - inter;
         if (ua > 0 && inter * 1000 / ua >= 500) {
#ifdef MOT_TEST_DEBUG
            mot_dbg.dup_rej++;
#endif
            return 0;
         }
      }
   }
   c->det[n].x0 = (short)x0; c->det[n].y0 = (short)y0;
   c->det[n].x1 = (short)x1; c->det[n].y1 = (short)y1;
   c->det[n].cx = (short)(sumx / area);
   c->det[n].cy = (short)(sumy / area);
   c->det[n].area = (short)area;
   c->det[n].mean = (short)(c->cur ? sumv / area : 0);
   c->n_det = n + 1;
#ifdef MOT_TEST_DEBUG
   mot_dbg.ok++;
#endif
   return 1;
}

/* v1.9 ④：两个人挨着走时前景会粘成一个连通域，检测层就只剩 1 个目标。
   这里看列投影：在中间 1/3 里找"谷"，够深就沿该列切成左右两块分别上报。 */
static int mot_find_split(const mot_work_t* w, unsigned char id,
                          int x0, int y0, int x1, int y1, int area)
{
   short col[MOT_W];
   int x, y, peak = 0, lo, hi, best = -1, bestv = 0;
   long la = 0, ra = 0;
   const int wd = x1 - x0 + 1, ht = y1 - y0 + 1;
   if (wd < MOT_SPLIT_MIN_W || ht < MOT_SPLIT_MIN_H) return -1;
   if (wd * 100 < ht * MOT_SPLIT_MIN_ASPECT) return -1;   /* 单个人：宽高比远小于 0.7，不切 */
   if (wd * 100 > ht * MOT_SPLIT_MAX_ASPECT) return -1;   /* 背景墙条：宽高比过大，不切 */
   if (area < 2 * MOT_MIN_AREA) return -1;
   for (x = x0; x <= x1; ++x) col[x] = 0;
   for (y = y0; y <= y1; ++y) {
      const int base = y * MOT_W;
      for (x = x0; x <= x1; ++x) if (w->lab[base + x] == id) col[x]++;
   }
   for (x = x0; x <= x1; ++x) if (col[x] > peak) peak = col[x];
   if (peak <= 0) return -1;
   lo = x0 + wd / 3; hi = x1 - wd / 3;
   if (hi <= lo) return -1;
   best = lo; bestv = col[lo];
   for (x = lo; x <= hi; ++x) if (col[x] < bestv) { bestv = col[x]; best = x; }
   if (bestv * 100 > peak * MOT_SPLIT_VALLEY) return -1;   /* 谷不够深 ⇒ 是一个人 */
   for (x = x0; x <= best; ++x) la += col[x];
   for (x = best + 1; x <= x1; ++x) ra += col[x];
   if (la < MOT_MIN_AREA || ra < MOT_MIN_AREA) return -1;  /* 一侧太窄 ⇒ 不切 */
   return best;
}

static int mot_label(mot_work_t* w, mot_ctx_t* c)
{
   int i, n_id = 0;
   c->raw_area = 0;
   c->n_det = 0;
   memset(w->lab, 0, sizeof(w->lab));
   for (i = 0; i < MOT_N; ++i) {
      int sp = 0, area = 0, mov = 0;
      long sumv = 0, sx = 0, sy = 0;
      int x0 = MOT_W, y0 = MOT_H, x1 = -1, y1 = -1;
      unsigned char id;
      int xs;
      if (!w->mask[i] || w->lab[i]) continue;
      id = (unsigned char)(++n_id);
      w->lab[i] = id;
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
                  w->lab[q] = id;
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
      xs = mot_find_split(w, id, x0, y0, x1, y1, area);
#ifdef MOT_TEST_DEBUG
   if (xs >= 0) mot_dbg.last_split = xs;
#endif
      if (xs >= 0) {
         long la = 0, lb = 0, lax = 0, lay = 0, lbx = 0, lby = 0, lav = 0, lbv = 0;
         int lmov = 0, rmov = 0;
         int lx0 = MOT_W, ly0 = MOT_H, lx1 = -1, ly1 = -1;
         int rx0 = MOT_W, ry0 = MOT_H, rx1 = -1, ry1 = -1;
         int y, x;
         for (y = y0; y <= y1; ++y) for (x = x0; x <= x1; ++x) {
            const int p = y * MOT_W + x;
            if (w->lab[p] != id) continue;
            if (x <= xs) {
               la++; lax += x; lay += y;
               if (c->cur) lav += c->cur[p];
               if (w->dmask[p]) lmov++;
               if (x < lx0) lx0 = x; if (x > lx1) lx1 = x;
               if (y < ly0) ly0 = y; if (y > ly1) ly1 = y;
            } else {
               lb++; lbx += x; lby += y;
               if (c->cur) lbv += c->cur[p];
               if (w->dmask[p]) rmov++;
               if (x < rx0) rx0 = x; if (x > rx1) rx1 = x;
               if (y < ry0) ry0 = y; if (y > ry1) ry1 = y;
            }
         }
         if (la >= MOT_MIN_AREA && lb >= MOT_MIN_AREA && lx1 >= lx0 && rx1 >= rx0) {
            /* v2.0：两半必须"够远、够高"才认是两个人，否则仍按一个人上报 */
            const int sep_ok = (lax / la - lbx / lb) >= MOT_SPLIT_MIN_SEP ||
                               (lbx / lb - lax / la) >= MOT_SPLIT_MIN_SEP;
            const int h_ok = (ly1 - ly0 + 1) * 100 >= (y1 - y0 + 1) * MOT_SPLIT_HALF_H &&
                             (ry1 - ry0 + 1) * 100 >= (y1 - y0 + 1) * MOT_SPLIT_HALF_H;
            if (sep_ok && h_ok) {
               mot_push_det(c, lx0, ly0, lx1, ly1, (int)la, lax, lay, lav, lmov);
               mot_push_det(c, rx0, ry0, rx1, ry1, (int)lb, lbx, lby, lbv, rmov);
               continue;
            }
         }
      }
      mot_push_det(c, x0, y0, x1, y1, area, sx, sy, sumv, mov);
   }
   {
      int a, b;
      for (a = 0; a < c->n_det; ++a) for (b = a + 1; b < c->n_det; ++b) {
         if (c->det[b].area > c->det[a].area) {
            const mot_det_t tt = c->det[a];
            c->det[a] = c->det[b];
            c->det[b] = tt;
         }
      }
   }
   c->last_area = (c->n_det > 0) ? (int)c->det[0].area : 0;
   return c->n_det;
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
   int best = -1;
   /* ① 靠近镜头：面积按 arate %/帧 增长 → 估算距离"近景阈值"还有几帧。
      人往镜头走时框一直在变大，这条比质心速度更早、更稳地给出提前量。 */
   if (t->arate >= MOT_ARATE_MIN && t->area > 0) {
      const long tgt = (long)MOT_W * MOT_H * MOT_NEAR_PCT / 100;
      long a = t->area;
      int k;
      for (k = 1; k <= 30; ++k) {
         a += a * t->arate / 100;
         if (a >= tgt) { best = k; break; }
         if (a > (long)MOT_W * MOT_H) break;
      }
   }
   /* ② 位置：不在 ROI 里时，按速度外推看几帧后能进 ROI（横向跑进来的人） */
   if (!(t->cx >= MOT_ETA_X0 && t->cx <= MOT_ETA_X1 &&
         t->cy >= MOT_ETA_Y0 && t->cy <= MOT_ETA_Y1)) {
      int k;
      for (k = 1; k <= MOT_HORIZON + 4; ++k) {
         const int x = (int)t->cx + ((int)t->vx * k) / 16;
         const int y = (int)t->cy + ((int)t->vy * k) / 16;
         if (x >= MOT_ETA_X0 && x <= MOT_ETA_X1 && y >= MOT_ETA_Y0 && y <= MOT_ETA_Y1) {
            if (best < 0 || k < best) best = k;
            break;
         }
         if (x < 0 || x >= MOT_W || y < 0 || y >= MOT_H) break;
      }
   }
   return best;
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
   /* 整幅检测（人贴近镜头）不参与速度更新，否则质心跳变会算出几百 px/帧 的假速度 */
   t->full = ((int)(d->x1 - d->x0 + 1) > MOT_W * 4 / 5 &&
              (int)(d->y1 - d->y0 + 1) > MOT_H * 4 / 5) ? 1 : 0;
   if (t->full) {
      t->vx = (short)0; t->vy = (short)0;
   }
   if (t->vx > -8 && t->vx < 8 && t->vy > -8 && t->vy < 8) { if (t->still < 32000) t->still++; }
   else t->still = 0;
   {   /* v3.11：面积连续变大 = 正在靠近镜头（比质心速度稳） */
      const int ar = (int)(d->x1 - d->x0 + 1) * (int)(d->y1 - d->y0 + 1);
      if (t->area > 0 && ar * 100 > (int)t->area * 108) { if (t->grow < 32000) t->grow++; }
      else if (t->area > 0 && ar * 100 < (int)t->area * 96) t->grow = 0;
      if (t->area > 0) {                      /* v17：面积增长率 EMA（%/帧） */
         int r = (ar * 100) / (int)t->area - 100;
         if (r > 60) r = 60;
         if (r < -60) r = -60;
         t->arate = (short)(((int)t->arate * 3 + r) / 4);
      }
      t->area = (short)(ar > 32767 ? 32767 : ar);
   }
   t->x0 = d->x0; t->y0 = d->y0; t->x1 = d->x1; t->y1 = d->y1;
   t->cx = d->cx; t->cy = d->cy;
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
   /* v17：预测用 1/2 阻尼速度 —— 离线（out/ev1..ev3 共 37 条航迹）实测，
      下一帧位置误差中位 5.00 px，比全速外推 7.07 px 低 30%，也优于"空间静止" 6.00 px。 */
   const int sx = ((int)t->vx * kq4 * MOT_PRED_DAMP_N) / (16 * 16 * MOT_PRED_DAMP_D);
   const int sy = ((int)t->vy * kq4 * MOT_PRED_DAMP_N) / (16 * 16 * MOT_PRED_DAMP_D);
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

/* v2.0：一人多轨合并（防御性）。实测：切分产生的左右两半是"相邻"关系，IoU 常 <0.30，
   本函数很少触发；真正把 ID 抖动压下来的是 mot_find_split 的两道门槛（最小间距/最低高度）。 */
static void mot_merge_tracks(mot_ctx_t* c)
{
   int i, j;
   for (i = 0; i < c->n_trk; ++i) {
      mot_trk_t* a = &c->trk[i];
      if (a->misses) continue;
      for (j = i + 1; j < c->n_trk; ++j) {
         mot_trk_t* b = &c->trk[j];
         int dx, dy;
         long ar, br;
         mot_trk_t* keep;
         mot_trk_t* drop;
         if (b->misses) continue;
         if (a->confirmed != b->confirmed) continue;
#ifdef MOT_TEST_DEBUG
         mot_dbg.t_pair++;
#endif
         {   /* v3.10：先看"相邻两半"——切分产生的是同一条人形被切成左右两块，
                质心距离可能 >MOT_MERGE_PX，但水平间隙很小、竖向几乎完全重叠。 */
            const int gap = (b->x0 > a->x1) ? (int)b->x0 - (int)a->x1 - 1
                          : ((a->x0 > b->x1) ? (int)a->x0 - (int)b->x1 - 1 : 0);
            const int oy0 = a->y0 > b->y0 ? a->y0 : b->y0;
            const int oy1 = a->y1 < b->y1 ? a->y1 : b->y1;
            const int ha = (int)a->y1 - (int)a->y0 + 1;
            const int hb = (int)b->y1 - (int)b->y0 + 1;
            const int hmin = ha < hb ? ha : hb;
            if (MOT_MERGE_ADJ_GAP > 0 && gap <= MOT_MERGE_ADJ_GAP && hmin > 0 &&
                (oy1 - oy0 + 1) * 5 >= hmin * 4) {
               keep = (a->hits >= b->hits) ? a : b;
               drop = (keep == a) ? b : a;
#ifdef MOT_TEST_DEBUG
               mot_dbg.merged++;
#endif
               keep->hits = (short)(keep->hits + drop->hits / 2);
               if (keep->age < drop->age) keep->age = drop->age;
               /* 合成一个大框（覆盖两半），否则下一帧又会把另一半当成新目标 → ID 反复新建 */
               if (keep->x0 > drop->x0) keep->x0 = drop->x0;
               if (keep->y0 > drop->y0) keep->y0 = drop->y0;
               if (keep->x1 < drop->x1) keep->x1 = drop->x1;
               if (keep->y1 < drop->y1) keep->y1 = drop->y1;
               keep->cx = (short)((keep->x0 + keep->x1) / 2);
               keep->cy = (short)((keep->y0 + keep->y1) / 2);
               drop->misses = (short)(MOT_MAX_MISS + 1);
               continue;
            }
         }
         dx = (int)a->cx - (int)b->cx;
         dy = (int)a->cy - (int)b->cy;
         if (dx * dx + dy * dy > MOT_MERGE_PX * MOT_MERGE_PX) continue;
#ifdef MOT_TEST_DEBUG
         mot_dbg.t_dist++;
#endif
         ar = (long)(a->x1 - a->x0 + 1) * (a->y1 - a->y0 + 1);
         br = (long)(b->x1 - b->x0 + 1) * (b->y1 - b->y0 + 1);
         if (ar <= 0 || br <= 0) continue;
         if (br * 100 > ar * MOT_MERGE_AREA_HI || ar * 100 > br * MOT_MERGE_AREA_HI) continue;
#ifdef MOT_TEST_DEBUG
         mot_dbg.t_area++;
#endif
         if (MOT_MERGE_IOU > 1000) continue;   /* -DMOT_MERGE_IOU=2001 = 整体关闭合并（A/B 用） */
         {
            /* v2.1 判据：切分把一个人切成"同一竖向带内的左右两块"——两块共享同一条人形高度，
               但框是相邻不重叠的，所以旧 IoU 判据实测 0/51 触发（等于合并从未生效）。
               改用竖向带交叠比例；并肩两人通常纵向错开（一个近一个远），交叠比例上不去。 */
            const int oy0 = a->y0 > b->y0 ? a->y0 : b->y0;
            const int oy1 = a->y1 < b->y1 ? a->y1 : b->y1;
            const int ha = (int)a->y1 - (int)a->y0 + 1;
            const int hb = (int)b->y1 - (int)b->y0 + 1;
            const int hmin = ha < hb ? ha : hb;
            if (oy1 < oy0) continue;
            if (hmin <= 0) continue;
            if ((oy1 - oy0 + 1) * 100 < hmin * MOT_MERGE_Y_OVERLAP) continue;
#ifdef MOT_TEST_DEBUG
            mot_dbg.t_iou++;
#endif
         }
         keep = (a->hits >= b->hits) ? a : b;
         drop = (keep == a) ? b : a;
#ifdef MOT_TEST_DEBUG
         mot_dbg.merged++;
#endif
         keep->hits = (short)(keep->hits + drop->hits / 2);
         if (keep->age < drop->age) keep->age = drop->age;
         drop->misses = (short)(MOT_MAX_MISS + 1);   /* 交给后面的删除趟收走 */
      }
   }
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
         int gate = (c->trk[bt].confirmed && lost > 0) ? MOT_REID_PX : MOT_GATE_PX;
#if MOT_GATE_SIZE_DIV > 0
         {   /* v17.1：门限随框宽放大（大目标一步位移大，固定 16 px 必然换号） */
            const int w = (int)c->trk[bt].x1 - (int)c->trk[bt].x0 + 1;
            const int g2 = w / MOT_GATE_SIZE_DIV;
            if (g2 > gate) gate = g2;
         }
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

   /* 未匹配检测：新建航迹（v2.1：先排除"其实就是已有确认航迹"的检测，避免一人多轨） */
   for (i = 0; i < c->n_det; ++i) {
      mot_trk_t* t;
      int dup_of_trk = 0;
      if (det_used[i]) continue;
      for (k = 0; k < c->n_trk; ++k) {
         short b4[4]; int pcx, pcy;
         if (!c->trk[k].confirmed || !c->trk[k].active) continue;
         mot_predict_box(&c->trk[k], 16, b4, &pcx, &pcy);
         if (mot_iou4(&c->det[i], b4) >= MOT_NEWTRK_IOU) { dup_of_trk = 1; break; }
      }
      if (dup_of_trk) continue;
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

   /* v2.0：先把"同一目标的多条航迹"合并，再执行删除 */
   mot_merge_tracks(c);

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

/* 当前在场的确认航迹数（丢失中的不算；整幅光照突变不算） */
static int mot_active_confirmed(const mot_ctx_t* c)
{
   int k, n = 0;
   for (k = 0; k < c->n_trk; ++k) {
      if (c->trk[k].confirmed && c->trk[k].active && !c->trk[k].full) n++;
   }
   return n;
}

/* v3.6 "画面里有几个人"。页面原来显示 n_trk（航迹表大小，含正在丢失的航迹和噪点），
   所以会出现"一个人显示两个人""人走了还显示一个人"。这里只数：
   - 本帧真的看到（misses==0，不是靠 coast 撑着）
   - 框够大（面积 >=150 且高 >=12）
   - 整幅框（>=80% 宽且 >=80% 高）需要 AI 判人有 或 红外热，否则按光照突变/自动曝光处理
   - 同一个人的两块（谷切分、或一块被另一块包住）只算一个 */
static int mot_fresh_confirmed(const mot_ctx_t* c)
{
   short bx0[MOT_MAX_TRK], by0[MOT_MAX_TRK], bx1[MOT_MAX_TRK], by1[MOT_MAX_TRK];
   const int human = (c->ai_p >= 0) || (c->ir_cnt > 0);
   int k, j, n = 0;
   for (k = 0; k < c->n_trk; ++k) {
      const mot_trk_t* t = &c->trk[k];
      const int w = (int)t->x1 - (int)t->x0 + 1;
      const int h = (int)t->y1 - (int)t->y0 + 1;
      if (!t->confirmed || !t->active || t->misses != 0) continue;
      if (w * h < MOT_MIN_PERSON_AREA || h < MOT_MIN_PERSON_H) continue;
      if (w * 5 >= MOT_W * 4 && h * 5 >= MOT_H * 4 && !human) continue;
      bx0[n] = t->x0; by0[n] = t->y0; bx1[n] = t->x1; by1[n] = t->y1; n++;
      if (n >= MOT_MAX_TRK) break;
   }
   for (k = 0; k < n; ++k) {
      for (j = k + 1; j < n; ++j) {
         if (bx1[k] < 0 || bx1[j] < 0) continue;
         {
            const int hk = by1[k] - by0[k] + 1, hj = by1[j] - by0[j] + 1;
            const int hm = hk < hj ? hk : hj;
            const int oy0 = by0[k] > by0[j] ? by0[k] : by0[j];
            const int oy1 = by1[k] < by1[j] ? by1[k] : by1[j];
            const int oy = oy1 - oy0 + 1;
            const int gap = (bx0[j] > bx1[k]) ? (bx0[j] - bx1[k] - 1)
                           : ((bx0[k] > bx1[j]) ? (bx0[k] - bx1[j] - 1) : 0);
            const int ix0 = bx0[k] > bx0[j] ? bx0[k] : bx0[j];
            const int ix1 = bx1[k] < bx1[j] ? bx1[k] : bx1[j];
            const int iy0 = by0[k] > by0[j] ? by0[k] : by0[j];
            const int iy1 = by1[k] < by1[j] ? by1[k] : by1[j];
            const int iw = ix1 - ix0 + 1, ih = iy1 - iy0 + 1;
            const int ak = hk * (bx1[k] - bx0[k] + 1), aj = hj * (bx1[j] - bx0[j] + 1);
            const int am = ak < aj ? ak : aj;
            const int inter = (iw > 0 && ih > 0) ? iw * ih : 0;
            const int adj  = (oy * 5 >= hm * 4 && gap <= 3);       /* 左右两半 */
            const int cont = (am > 0 && inter * 20 >= am * 17);    /* 一块基本包住另一块（>=85%） */
            if (adj || cont) {
               bx1[k] = (short)(bx1[k] > bx1[j] ? bx1[k] : bx1[j]);
               bx0[k] = (short)(bx0[k] < bx0[j] ? bx0[k] : bx0[j]);
               by1[k] = (short)(by1[k] > by1[j] ? by1[k] : by1[j]);
               by0[k] = (short)(by0[k] < by0[j] ? by0[k] : by0[j]);
               bx1[j] = (short)-1;
            }
         }
      }
   }
   j = 0;
   for (k = 0; k < n; ++k) if (bx1[k] >= 0) j++;
   return j;
}

/* v3.11：有目标正在靠近镜头（面积连续 3 帧变大） */
static int mot_approach(const mot_ctx_t* c)
{
   int k;
   for (k = 0; k < c->n_trk; ++k) {
      const mot_trk_t* t = &c->trk[k];
      if (t->confirmed && t->active && t->grow >= 3 && !t->full) return 1;
   }
   return 0;
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
