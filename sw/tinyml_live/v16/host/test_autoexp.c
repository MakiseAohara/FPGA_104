/*==============================================================================
 * test_autoexp.c — 电脑端验证自动曝光控制器（v16）
 *
 * 相机模型：mean = scene * (exp/exp0) * (gain/gain0) + 噪声，clamp 0..255，
 *           测量有 1 次评估的延迟（先给上一轮结果）。
 *
 * 测试项：
 *  1) 偏暗（初始均值 45）→ 30 次评估内进入 [95,125]，且之后不再动作（无振荡）
 *  2) 偏亮（初始均值 200，AE_DIM_ENABLE=1 允许下调）→ 30 次评估内进入目标
 *  3) 全程 exp/gain 都在上下限内
 *  4) 已处于目标范围 → 0 次动作
 *  5) 极暗场景 → 到上限后报饱和（不越界、不振荡）
 *
 * 编译：gcc -O2 -std=c99 -I.. test_autoexp.c -o test_autoexp
 *============================================================================*/
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include "ae_core.h"

static int errors = 0, checks = 0;

static void check(int cond, const char *name, const char *detail)
{
    ++checks;
    if (cond) printf("PASS %-52s %s\n", name, detail ? detail : "");
    else { ++errors; printf("FAIL %-52s %s\n", name, detail ? detail : ""); }
}

typedef struct {
    double scene;      /* 场景亮度（初始设置下的均值） */
    int exp0, gain0;
    int exp, gain;     /* 当前实际寄存器 */
    int delay;         /* 1 = 测量反映上一轮设置 */
    int pend_exp, pend_gain;
    int have_pending;
    unsigned int lcg;
} camera_t;

static int cam_noise(camera_t *c)
{
    c->lcg = c->lcg * 1103515245u + 12345u;
    return (int)((c->lcg >> 16) % 5) - 2;   /* -2..+2 */
}

static void cam_init(camera_t *c, double scene, int exp0, int gain0)
{
    c->scene = scene;
    c->exp0 = exp0;
    c->gain0 = gain0;
    c->exp = exp0;
    c->gain = gain0;
    c->have_pending = 0;
    c->pend_exp = c->exp;
    c->pend_gain = c->gain;
    c->lcg = 987654321u;
}

static int cam_measure(camera_t *c)
{
    int e = c->have_pending ? c->pend_exp : c->exp;
    int g = c->have_pending ? c->pend_gain : c->gain;
    const double factor = ((double)e / (double)c->exp0) * ((double)g / (double)c->gain0);
    double mean = c->scene * factor + cam_noise(c);
    if (mean < 0) mean = 0;
    if (mean > 255) mean = 255;
    return (int)(mean + 0.5);
}

static void cam_apply(camera_t *c, int exp, int gain)
{
    c->have_pending = 1;
    c->pend_exp = exp;
    c->pend_gain = gain;
}

/* 闭环运行；返回评估次数（直到首次进入目标），并在 *acts_after_enter 里统计
 * 进入目标后（连续 3 次在范围内之后）的动作次数 */
static int run_closed_loop(ae_state_t *s, const ae_cfg_t *cfg, camera_t *cam,
                           int max_evals, int *acts_after_enter,
                           int *final_mean, int *ever_act, int *saturated,
                           int *enter_eval)
{
    int eval = 0, in_cnt = 0, entered = 0, after = 0, act = 0;
    int last = 0;
    *acts_after_enter = 0;
    *ever_act = 0;
    *saturated = 0;
    *enter_eval = -1;
    while (eval < max_evals) {
        int mean = cam_measure(cam);
        int ne = s->exp, ng = s->gain;
        act = ae_step(s, mean, cfg, &ne, &ng);
        last = mean;
        ++eval;

        /* 控制器输出的码值必须在上下限内 */
        if (s->exp < s->exp_min || s->exp > s->exp_max ||
            s->gain < s->gain_min || s->gain > s->gain_max) {
            *acts_after_enter = -999;
            return eval;
        }
        if (act > 0) (*ever_act)++;
        if (act == AE_ACT_SAT_HI || act == AE_ACT_SAT_LO) { (*saturated)++; }
        if (act > 0) cam_apply(cam, ne, ng);

        if (mean >= cfg->target_lo && mean <= cfg->target_hi) {
            in_cnt++;
            if (in_cnt >= 3 && !entered) { entered = 1; *final_mean = mean; *enter_eval = eval; }
        } else {
            if (entered) { entered = 0; }   /* 离开范围，重新计 */
            in_cnt = 0;
        }
        if (entered) {
            /* 进入后再观察，统计动作（应为 0） */
            after++;
            if (after >= 15) { *final_mean = mean; return eval; }
        }
    }
    *final_mean = last;
    return eval;
}

int main(void)
{
    ae_state_t s;
    ae_cfg_t cfg = { AE_TARGET_LO, AE_TARGET_HI };
    const int EXP0 = 0xBBF0;    /* 与 ROM 当前值 0xbb,0xf0 一致 */
    const int GAIN0 = 0x0100;
    camera_t cam;
    int acts_after, final_mean, ever_act, sat, evals, enter_eval;

    printf("== test_autoexp (v16) ==\n");

    /* ---------------- 1) 偏暗：初始 45 ---------------- */
    ae_init(&s, EXP0, GAIN0, 4, 2, 0);
    cam_init(&cam, 45.0, EXP0, GAIN0);
    evals = run_closed_loop(&s, &cfg, &cam, 60, &acts_after, &final_mean, &ever_act, &sat, &enter_eval);
    {
        char d[220];
        snprintf(d, sizeof d, "enter_eval=%d total_evals=%d final_mean=%d exp=0x%04x gain=0x%04x acts_after=%d",
                 enter_eval, evals, final_mean, (unsigned)s.exp, (unsigned)s.gain, acts_after);
        check(enter_eval >= 0 && enter_eval <= 30 && final_mean >= AE_TARGET_LO &&
              final_mean <= AE_TARGET_HI && acts_after == 0,
              "dark start (45) converges <=30 evals, no oscillation", d);
    }

    /* ---------------- 2) 偏亮：初始 200（允许下调） ---------------- */
    ae_init(&s, EXP0, GAIN0, 4, 2, 1 /* dim_enable */);
    cam_init(&cam, 200.0, EXP0, GAIN0);
    evals = run_closed_loop(&s, &cfg, &cam, 60, &acts_after, &final_mean, &ever_act, &sat, &enter_eval);
    {
        char d[220];
        snprintf(d, sizeof d, "enter_eval=%d total_evals=%d final_mean=%d exp=0x%04x gain=0x%04x acts_after=%d",
                 enter_eval, evals, final_mean, (unsigned)s.exp, (unsigned)s.gain, acts_after);
        check(enter_eval >= 0 && enter_eval <= 30 && final_mean >= AE_TARGET_LO &&
              final_mean <= AE_TARGET_HI && acts_after == 0,
              "bright start (200) converges <=30 evals with dim enabled", d);
    }

    /* ---------------- 3) 已在目标范围：不动作 ---------------- */
    ae_init(&s, EXP0, GAIN0, 4, 2, 0);
    cam_init(&cam, 110.0, EXP0, GAIN0);
    {
        int act_count = 0;
        for (int k = 0; k < 15; ++k) {
            int mean = cam_measure(&cam);
            int ne = s.exp, ng = s.gain;
            int act = ae_step(&s, mean, &cfg, &ne, &ng);
            if (act != AE_ACT_NONE) act_count++;
            if (act > 0) cam_apply(&cam, ne, ng);
        }
        char d[160];
        snprintf(d, sizeof d, "actions=%d (expect 0)", act_count);
        check(act_count == 0, "in-range scene: zero actions (hysteresis/deadband)", d);
    }

    /* ---------------- 4) 极暗场景：饱和后稳定 ---------------- */
    ae_init(&s, EXP0, GAIN0, 4, 2, 0);
    cam_init(&cam, 5.0, EXP0, GAIN0);
    evals = run_closed_loop(&s, &cfg, &cam, 120, &acts_after, &final_mean, &ever_act, &sat, &enter_eval);
    {
        char d[220];
        snprintf(d, sizeof d, "evals=%d exp=0x%04x(max=0x%04x) gain=0x%04x(max=0x%04x) sat_acts=%d",
                 evals, (unsigned)s.exp, (unsigned)s.exp_max,
                 (unsigned)s.gain, (unsigned)s.gain_max, sat);
        check(s.exp == s.exp_max && s.gain == s.gain_max && sat > 0 && acts_after != -999,
              "very dark: saturates at both upper limits, stays in bounds", d);
    }

    /* ---------------- 5) 上下限检查（多场景随机） ---------------- */
    {
        int bad = 0;
        for (int t = 0; t < 20; ++t) {
            ae_state_t s2;
            camera_t c2;
            const int sc = 10 + t * 12;
            ae_init(&s2, EXP0, GAIN0, 4, 2, (t & 1));
            cam_init(&c2, (double)sc, EXP0, GAIN0);
            for (int k = 0; k < 80; ++k) {
                int mean = cam_measure(&c2);
                int ne = s2.exp, ng = s2.gain;
                int act = ae_step(&s2, mean, &cfg, &ne, &ng);
                if (s2.exp < s2.exp_min || s2.exp > s2.exp_max ||
                    s2.gain < s2.gain_min || s2.gain > s2.gain_max) bad++;
                if (act > 0) cam_apply(&c2, ne, ng);
            }
        }
        char d[160];
        snprintf(d, sizeof d, "bad_steps=%d over 20 scenes x 80 evals", bad);
        check(bad == 0, "exp/gain always stay within configured bounds", d);
    }

    printf("\n== test_autoexp: %d checks, %d errors ==\n", checks, errors);
    printf("%s\n", errors ? "RESULT FAIL" : "RESULT PASS");
    return errors ? 1 : 0;
}
