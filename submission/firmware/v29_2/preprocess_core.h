/*==============================================================================
 * preprocess_core.h — AI 输入预处理核心（v16）
 *
 * 固件与电脑端测试共用（纯 C，无平台依赖）。
 *
 * 输入帧：行距 1920 字节、1 字节/像素、1920x1080（MERGE11 位流的帧缓冲格式）
 * 输出：96x96 灰度，位重解释为 int8（(int8_t)v，与 main_live15 一致）
 *
 * CROP_MODE: 0 = 整幅 1920x1080 压缩（原行为）
 *            1 = 中间正方形 1080x1080（横向居中，x0=420）
 *            2 = 中间 1.5 倍宽 1620x1080（横向居中，x0=150）
 * NORM_ON:   对取样后 0..255 值做亮度归一化（目标均值 115，增益限幅 0.5..3.0）
 * STRETCH_ON:按 1% / 99% 分位拉伸到 0..255
 *
 * 处理顺序：取样 → （STRETCH）→ （NORM）→ int8
 * 默认（全 0）时与 main_live15 的 sample_frame_box 逐像素一致（电脑端测试验证）。
 *============================================================================*/
#ifndef PREPROCESS_CORE_H
#define PREPROCESS_CORE_H

#define PP_OUT_W        96
#define PP_OUT_H        96
#define PP_FRAME_W      1920
#define PP_FRAME_H      1080
#define PP_BOX          3       /* 每个输出像素的采样点 3x3 */
#define PP_NORM_TARGET  115     /* 归一化目标均值 */
#define PP_NORM_GAIN_LO 50      /* 增益下限 ×100 = 0.5 */
#define PP_NORM_GAIN_HI 300     /* 增益上限 ×100 = 3.0 */
#define PP_STRETCH_LO_PM 10     /* 1% 分位（千分比） */
#define PP_STRETCH_HI_PM 990    /* 99% 分位（千分比） */

typedef struct {
    int crop_mode;      /* 0/1/2 */
    int norm_on;        /* 0/1 */
    int stretch_on;     /* 0/1 */
} pp_cfg_t;

/* 取像素回调：x,y 为帧缓冲绝对坐标；返回 0..255 */
typedef unsigned char (*pp_get_fn)(void *ctx, int x, int y);

typedef struct {
    int mean_sensor;    /* 原始取样均值（拉伸/归一化之前，AE 控制器用） */
    int mean_in;        /* 转 int8 前的均值（拉伸后、归一化前） */
    int mean_out;       /* 最终 uint8 均值 */
    int gain_x100;      /* 归一化增益 ×100；未启用=100 */
    int norm_applied;
    int stretch_applied;
    int stretch_lo;
    int stretch_hi;
    int crop_mode;
} pp_stats_t;

/* 取裁剪区域（x0,y0,cw,ch） */
static void pp_geometry(int crop_mode, int *x0, int *y0, int *cw, int *ch)
{
    switch (crop_mode) {
    case 1:  *x0 = (PP_FRAME_W - 1080) / 2; *y0 = 0; *cw = 1080; *ch = PP_FRAME_H; break;
    case 2:  *x0 = (PP_FRAME_W - 1620) / 2; *y0 = 0; *cw = 1620; *ch = PP_FRAME_H; break;
    default: *x0 = 0; *y0 = 0; *cw = PP_FRAME_W; *ch = PP_FRAME_H; break;
    }
}

/* 2x2 Bayer 均值（与 main_live15 的 quad_mean 完全一致） */
static unsigned int pp_quad_mean(pp_get_fn get, void *ctx, int x, int y)
{
    const unsigned int a = get(ctx, x, y);
    const unsigned int b = get(ctx, x + 1, y);
    const unsigned int c = get(ctx, x, y + 1);
    const unsigned int d = get(ctx, x + 1, y + 1);
    return (a + b + c + d) >> 2;
}

/* 直方图分位（permille 千分比，0..1000；返回 0..255） */
static int pp_hist_percentile(const unsigned int *hist, int total, int permille)
{
    int cum = 0;
    int i;
    int target = (total * permille) / 1000;
    if (total <= 0) return 0;
    for (i = 0; i < 256; ++i) {
        cum += (int)hist[i];
        if (cum >= target) return i;
    }
    return 255;
}

/* 主函数：取样 + 可选拉伸/归一化，输出 96x96 int8
 * out  : 96*96
 * st   : 统计输出（可为 0）
 * 返回 : out 中各 uint8 值之和（与 main_live15 的返回值语义一致）
 */
static unsigned int pp_run(pp_get_fn get, void *ctx, const pp_cfg_t *cfg,
                           signed char *out, pp_stats_t *st)
{
    unsigned int raw[PP_OUT_W * PP_OUT_H];
    int x0, y0, cw, ch;
    int ox, oy, i, j;
    unsigned int sum = 0;
    int mean_sensor = 0, mean_in, mean_out, gain_x100 = 100;
    int lo = 0, hi = 255, stretched = 0, normed = 0;
    const int crop_mode = cfg ? cfg->crop_mode : 0;
    const int norm_on   = cfg ? cfg->norm_on : 0;
    const int stretch_on= cfg ? cfg->stretch_on : 0;

    pp_geometry(crop_mode, &x0, &y0, &cw, &ch);

    /* ---- 1) 取样：与 main_live15 同一几何公式，逐像素对齐 ---- */
    for (oy = 0; oy < PP_OUT_H; ++oy) {
        for (ox = 0; ox < PP_OUT_W; ++ox) {
            unsigned int acc = 0;
            for (j = 0; j < PP_BOX; ++j) {
                int sy = ((oy * PP_BOX + j) * ch) / (PP_OUT_H * PP_BOX) + y0;
                sy &= ~1;
                if (sy > y0 + ch - 2) sy = y0 + ch - 2;
                for (i = 0; i < PP_BOX; ++i) {
                    int sx = ((ox * PP_BOX + i) * cw) / (PP_OUT_W * PP_BOX) + x0;
                    sx &= ~1;
                    if (sx > x0 + cw - 2) sx = x0 + cw - 2;
                    acc += pp_quad_mean(get, ctx, sx, sy);
                }
            }
            raw[oy * PP_OUT_W + ox] = acc / (PP_BOX * PP_BOX);
        }
    }

    /* ---- 1b) 原始取样均值（AE 用；在任何拉伸/归一化之前） ---- */
    {
        unsigned int sum_raw = 0;
        for (i = 0; i < PP_OUT_W * PP_OUT_H; ++i) sum_raw += raw[i];
        mean_sensor = (int)(sum_raw / (PP_OUT_W * PP_OUT_H));
    }

    /* ---- 2) 1%/99% 分位拉伸 ---- */
    if (stretch_on) {
        unsigned int hist[256];
        int k;
        for (k = 0; k < 256; ++k) hist[k] = 0;
        for (k = 0; k < PP_OUT_W * PP_OUT_H; ++k) hist[raw[k] & 0xFF] += 1;
        lo = pp_hist_percentile(hist, PP_OUT_W * PP_OUT_H, PP_STRETCH_LO_PM);
        hi = pp_hist_percentile(hist, PP_OUT_W * PP_OUT_H, PP_STRETCH_HI_PM);
        if (hi > lo) {
            const int span = hi - lo;
            for (k = 0; k < PP_OUT_W * PP_OUT_H; ++k) {
                int v = (int)raw[k];
                v = ((v - lo) * 255) / span;
                if (v < 0) v = 0;
                if (v > 255) v = 255;
                raw[k] = (unsigned int)v;
            }
            stretched = 1;
        } else {
            /* 画面极平：不拉伸，避免除零/放大噪声 */
            lo = 0; hi = 255; stretched = 0;
        }
    }

    /* ---- 3) 亮度归一化（目标均值 115，增益 0.5..3.0） ---- */
    {
        unsigned int sum_in = 0;
        for (i = 0; i < PP_OUT_W * PP_OUT_H; ++i) sum_in += raw[i];
        mean_in = (int)(sum_in / (PP_OUT_W * PP_OUT_H));
        if (norm_on && mean_in > 0) {
            int g = (PP_NORM_TARGET * 100 + mean_in / 2) / mean_in;   /* ×100，四舍五入 */
            if (g < PP_NORM_GAIN_LO) g = PP_NORM_GAIN_LO;
            if (g > PP_NORM_GAIN_HI) g = PP_NORM_GAIN_HI;
            gain_x100 = g;
            for (i = 0; i < PP_OUT_W * PP_OUT_H; ++i) {
                int v = (int)raw[i] * g / 100;
                if (v > 255) v = 255;
                raw[i] = (unsigned int)v;
            }
            normed = 1;
        }
    }

    /* ---- 4) 输出 int8（位重解释，与 main_live15 一致） ---- */
    {
        unsigned int sum_out = 0;
        for (i = 0; i < PP_OUT_W * PP_OUT_H; ++i) {
            const unsigned char u = (unsigned char)(raw[i] & 0xFF);
            out[i] = (signed char)u;
            sum_out += u;
        }
        sum = sum_out;
        mean_out = (int)(sum_out / (PP_OUT_W * PP_OUT_H));
    }

    if (st) {
        st->mean_sensor = mean_sensor;
        st->mean_in = mean_in;
        st->mean_out = mean_out;
        st->gain_x100 = gain_x100;
        st->norm_applied = normed;
        st->stretch_applied = stretched;
        st->stretch_lo = lo;
        st->stretch_hi = hi;
        st->crop_mode = crop_mode;
    }
    return sum;
}

#endif /* PREPROCESS_CORE_H */
