/*==============================================================================
 * test_preprocess.c — 电脑端验证 AI 输入预处理（v16）
 *
 * 测试项：
 *  1) 回归：CROP_MODE=0/NORM=0/STRETCH=0 与 main_live15 的 sample_frame_box 逐像素一致
 *  2) CROP_MODE=1/2 的取样范围正确（已知亮块落点 +  crop1 看不到裁剪区外的亮块）
 *  3) NORM_ON：均值接近 115（±3），增益限幅正确
 *  4) STRETCH_ON：1%/99% 分位拉伸到 0/255 附近
 *
 * 编译：gcc -O2 -std=c99 -I.. test_preprocess.c -o test_preprocess
 *============================================================================*/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "preprocess_core.h"

#define W PP_FRAME_W
#define H PP_FRAME_H

static unsigned char frame[W * H];
static signed char out[PP_OUT_W * PP_OUT_H];

static unsigned char get_px(void *ctx, int x, int y)
{
    (void)ctx;
    if (x < 0) x = 0;
    if (y < 0) y = 0;
    if (x >= W) x = W - 1;
    if (y >= H) y = H - 1;
    return frame[y * W + x];
}

/* main_live15 的原算法（逐字保留，仅把帧缓冲换成内存数组） */
static unsigned int quad_mean_v15(int x, int y)
{
    const unsigned int a = get_px(0, x, y);
    const unsigned int b = get_px(0, x + 1, y);
    const unsigned int c = get_px(0, x, y + 1);
    const unsigned int d = get_px(0, x + 1, y + 1);
    return (a + b + c + d) >> 2;
}

static unsigned int sample_frame_box_v15(signed char *o)
{
    unsigned int sum = 0;
    for (unsigned int oy = 0; oy < 96; ++oy) {
        for (unsigned int ox = 0; ox < 96; ++ox) {
            const unsigned int bx = ox * 20u;
            unsigned int acc = 0;
            for (unsigned int j = 0; j < 3; ++j) {
                unsigned int sy = (oy * 45u + (j * 45u) / 3u) / 4u;
                sy &= ~1u;
                if (sy > H - 2u) sy = H - 2u;
                for (unsigned int i = 0; i < 3; ++i) {
                    unsigned int sx = bx + (i * 20u) / 3u;
                    sx &= ~1u;
                    if (sx > W - 2u) sx = W - 2u;
                    acc += quad_mean_v15((int)sx, (int)sy);
                }
            }
            const unsigned int v = acc / 9u;
            o[oy * 96 + ox] = (signed char)v;
            sum += (unsigned char)o[oy * 96 + ox];
        }
    }
    return sum;
}

static int errors = 0, checks = 0;
static void check(int cond, const char *name, const char *detail)
{
    ++checks;
    if (cond) {
        printf("PASS %-52s %s\n", name, detail ? detail : "");
    } else {
        ++errors;
        printf("FAIL %-52s %s\n", name, detail ? detail : "");
    }
}

static void fill_flat(int v)
{
    memset(frame, v, sizeof(frame));
}

/* 在指定矩形填亮块 */
static void put_rect(int x0, int y0, int x1, int y1, int val)
{
    for (int y = y0; y < y1; ++y)
        for (int x = x0; x < x1; ++x)
            frame[y * W + x] = (unsigned char)val;
}

static void stats_out(pp_stats_t *st, int *sum_out, int *mn, int *mx)
{
    int s = 0, lo = 255, hi = 0;
    for (int i = 0; i < PP_OUT_W * PP_OUT_H; ++i) {
        const int v = (unsigned char)out[i];
        s += v;
        if (v < lo) lo = v;
        if (v > hi) hi = v;
    }
    *sum_out = s; *mn = lo; *mx = hi;
    (void)st;
}

int main(void)
{
    pp_cfg_t cfg;
    pp_stats_t st;
    int i;

    printf("== test_preprocess (v16) ==\n");

    /* ---------------------------------------------------------------- */
    /* 1) 回归：默认配置必须与 v15 逐像素一致                              */
    /* ---------------------------------------------------------------- */
    srand(12345);
    for (i = 0; i < W * H; ++i) frame[i] = (unsigned char)(rand() & 0xFF);
    memset(&cfg, 0, sizeof(cfg));
    memset(&st, 0, sizeof(st));
    memset(out, 0, sizeof(out));
    unsigned int sum_new = pp_run(get_px, 0, &cfg, out, &st);
    signed char ref[PP_OUT_W * PP_OUT_H];
    memset(ref, 0, sizeof(ref));
    unsigned int sum_ref = sample_frame_box_v15(ref);
    int diff = 0;
    for (i = 0; i < PP_OUT_W * PP_OUT_H; ++i)
        if (out[i] != ref[i]) diff++;
    {
        char d[160];
        snprintf(d, sizeof d, "diff_pixels=%d sum_new=%u sum_ref=%u", diff, sum_new, sum_ref);
        check(diff == 0 && sum_new == sum_ref, "regression CROP=0 == main_live15", d);
    }

    /* ---------------------------------------------------------------- */
    /* 2) 裁剪模式：已知亮块落点                                          */
    /* ---------------------------------------------------------------- */
    /* 亮块放在整幅中间偏左：x 600..899, y 300..599 */
    fill_flat(0);
    put_rect(600, 300, 900, 600, 255);
    cfg.crop_mode = 1; cfg.norm_on = 0; cfg.stretch_on = 0;
    pp_run(get_px, 0, &cfg, out, &st);
    {
        int ox_min = 999, ox_max = -1, oy_min = 999, oy_max = -1, bright = 0;
        for (int y = 0; y < PP_OUT_H; ++y)
            for (int x = 0; x < PP_OUT_W; ++x)
                if ((unsigned char)out[y * PP_OUT_W + x] > 200) {
                    bright++;
                    if (x < ox_min) ox_min = x;
                    if (x > ox_max) ox_max = x;
                    if (y < oy_min) oy_min = y;
                    if (y > oy_max) oy_max = y;
                }
        /* crop1: x0=420, cw=1080 => 600→(600-420)*96/1080≈16.0; 900→42.7 */
        char d[200];
        snprintf(d, sizeof d, "bright=%d x=[%d,%d] y=[%d,%d] (expect x≈16..42, y≈27..53)",
                 bright, ox_min, ox_max, oy_min, oy_max);
        check(bright > 100 && abs(ox_min - 16) <= 2 && abs(ox_max - 42) <= 2 &&
              abs(oy_min - 27) <= 2 && abs(oy_max - 53) <= 2,
              "crop1 samples the 1080x1080 center square", d);
    }
    /* crop2: x0=150, cw=1620 => 600→(450)*96/1620≈26.7; 900→44.4 */
    cfg.crop_mode = 2;
    pp_run(get_px, 0, &cfg, out, &st);
    {
        int ox_min = 999, ox_max = -1, bright = 0;
        for (int y = 0; y < PP_OUT_H; ++y)
            for (int x = 0; x < PP_OUT_W; ++x)
                if ((unsigned char)out[y * PP_OUT_W + x] > 200) {
                    bright++;
                    if (x < ox_min) ox_min = x;
                    if (x > ox_max) ox_max = x;
                }
        char d[200];
        snprintf(d, sizeof d, "bright=%d x=[%d,%d] (expect x≈26..45)", bright, ox_min, ox_max);
        check(bright > 100 && abs(ox_min - 26) <= 2 && abs(ox_max - 45) <= 2,
              "crop2 samples the 1620x1080 center region", d);
    }
    /* crop1 看不到裁剪区外的亮块（x 50..300 在 420 左边） */
    fill_flat(0);
    put_rect(50, 0, 300, H, 255);
    cfg.crop_mode = 1;
    pp_run(get_px, 0, &cfg, out, &st);
    {
        int bright = 0;
        for (i = 0; i < PP_OUT_W * PP_OUT_H; ++i) if ((unsigned char)out[i] > 200) bright++;
        char d[120];
        snprintf(d, sizeof d, "bright=%d (expect 0)", bright);
        check(bright == 0, "crop1 ignores left strip outside the square", d);
    }
    /* 同一亮块，整幅模式应看得到 */
    cfg.crop_mode = 0;
    pp_run(get_px, 0, &cfg, out, &st);
    {
        int bright0 = 0;
        for (i = 0; i < PP_OUT_W * PP_OUT_H; ++i) if ((unsigned char)out[i] > 200) bright0++;
        char d[120];
        snprintf(d, sizeof d, "bright=%d (expect >100)", bright0);
        check(bright0 > 100, "crop0 still sees the same block", d);
    }

    /* ---------------------------------------------------------------- */
    /* 3) NORM_ON：均值 115 ±3，增益限幅                                   */
    /* ---------------------------------------------------------------- */
    cfg.crop_mode = 0; cfg.norm_on = 1; cfg.stretch_on = 0;
    fill_flat(50);
    pp_run(get_px, 0, &cfg, out, &st);
    {
        int sum, mn, mx; stats_out(&st, &sum, &mn, &mx);
        const int mean = sum / (PP_OUT_W * PP_OUT_H);
        char d[200];
        snprintf(d, sizeof d, "mean_in=%d mean_out=%d gain_x100=%d", st.mean_in, mean, st.gain_x100);
        check(abs(mean - 115) <= 3 && st.gain_x100 >= 200 && st.gain_x100 <= 260,
              "norm dark->115 (gain unclipped)", d);
    }
    fill_flat(20);
    pp_run(get_px, 0, &cfg, out, &st);
    {
        int sum, mn, mx; stats_out(&st, &sum, &mn, &mx);
        char d[200];
        snprintf(d, sizeof d, "mean_in=%d mean_out=%d gain_x100=%d (clamp_hi=300)",
                 st.mean_in, sum / (PP_OUT_W * PP_OUT_H), st.gain_x100);
        check(st.gain_x100 == 300, "norm very dark -> gain clamped to 3.0", d);
    }
    fill_flat(240);
    {
        int sum, mn, mx;
        memset(&st, 0, sizeof(st));
        pp_run(get_px, 0, &cfg, out, &st);
        stats_out(&st, &sum, &mn, &mx);
        char d[200];
        snprintf(d, sizeof d, "mean_in=%d mean_out=%d gain_x100=%d (clamp_lo=50)",
                 st.mean_in, sum / (PP_OUT_W * PP_OUT_H), st.gain_x100);
        check(st.gain_x100 == 50, "norm very bright -> gain clamped to 0.5", d);
    }

    /* ---------------------------------------------------------------- */
    /* 4) STRETCH_ON：1%/99% 分位拉伸                                      */
    /* ---------------------------------------------------------------- */
    cfg.crop_mode = 0; cfg.norm_on = 0; cfg.stretch_on = 1;
    /* 线性梯度 20..235，直方图近似均匀 */
    for (int y = 0; y < H; ++y)
        for (int x = 0; x < W; ++x)
            frame[y * W + x] = (unsigned char)(20 + (x * 215) / (W - 1));
    pp_run(get_px, 0, &cfg, out, &st);
    {
        unsigned int hist[256];
        int k, lo_out = 0, hi_out = 0, mean_out;
        int sum = 0;
        memset(hist, 0, sizeof(hist));
        for (k = 0; k < PP_OUT_W * PP_OUT_H; ++k) hist[(unsigned char)out[k]]++;
        for (k = 0; k < 256; ++k) {
            if (hist[k]) { if (!lo_out) lo_out = k; hi_out = k; }
            sum += k * (int)hist[k];
        }
        mean_out = sum / (PP_OUT_W * PP_OUT_H);
        char d[220];
        snprintf(d, sizeof d, "lo=%d hi=%d out_min=%d out_max=%d mean=%d stretch=[%d,%d]",
                 st.stretch_lo, st.stretch_hi, lo_out, hi_out, mean_out,
                 st.stretch_lo, st.stretch_hi);
        check(lo_out <= 8 && hi_out >= 247,
              "stretch maps 1%/99% to ~0/255", d);
    }

    printf("\n== test_preprocess: %d checks, %d errors ==\n", checks, errors);
    if (errors == 0) printf("RESULT PASS\n");
    else             printf("RESULT FAIL\n");
    return errors ? 1 : 0;
}
