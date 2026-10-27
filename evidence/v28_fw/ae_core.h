/*==============================================================================
 * ae_core.h — 自动曝光控制器（v16，纯 C，可在电脑上单独测试）
 *
 * 输入：96x96 输入图均值 mean（0..255）、目标范围 [lo,hi]、曝光/增益上下限
 * 输出：新的曝光/增益码值 + 动作码
 *
 * 参数（全部可在固件里用宏覆盖）：
 *   AE_TARGET_LO / AE_TARGET_HI  目标均值范围，默认 95 / 125
 *   AE_DEADBAND                  死区（目标范围外再放宽该值才动作），默认 3
 *   AE_CONFIRM                   连续多少次评估越界才动作，默认 2
 *   AE_STEP_PCT                  单次调节幅度 ±12%
 *   AE_WAIT_EVALS                动作后等待多少次评估再评估，默认 3
 *   AE_EXP_MAX_MULT              曝光上限 = 初始值 ×4
 *   AE_GAIN_MAX_MULT             增益上限 = 初始值 ×2（不超过 ×2）
 *   AE_DIM_ENABLE                默认 0：下限 = 初始值（任务书要求，只能变亮）；
 *                                1：下限 = 初始值 /4（允许变暗；主机测试偏亮场景用）
 *
 * 曝光/增益“码值”定义（需上板确认，设计说明中如实标注）：
 *   exp  = (0x3e01 << 8) | 0x3e02      16 位曝光码
 *   gain = (0x3e08 << 8) | 0x3e09      16 位增益码
 * 码值按线性近似做 ±12% 调节；真实线性度需上板标定。
 *============================================================================*/
#ifndef AE_CORE_H
#define AE_CORE_H

#ifndef AE_TARGET_LO
#define AE_TARGET_LO     95
#endif
#ifndef AE_TARGET_HI
#define AE_TARGET_HI     125
#endif
#ifndef AE_DEADBAND
#define AE_DEADBAND      3
#endif
#ifndef AE_CONFIRM
#define AE_CONFIRM       2
#endif
#ifndef AE_STEP_PCT
#define AE_STEP_PCT      12
#endif
#ifndef AE_WAIT_EVALS
/* 动作后至少等待 3 帧再评估。评估周期 AE_EVAL_FRAMES=8 帧 ≥3 帧，
 * 因此默认不再额外跳过评估（=0）；若把 AE_EVAL_FRAMES 调到 <3，请设为 3。 */
#define AE_WAIT_EVALS    0
#endif

/* 动作码 */
#define AE_ACT_NONE      0
#define AE_ACT_EXP_UP    1
#define AE_ACT_EXP_DN    2
#define AE_ACT_GAIN_UP   3
#define AE_ACT_GAIN_DN   4
#define AE_ACT_SAT_HI   (-1)   /* 已到最亮上限，无法再增 */
#define AE_ACT_SAT_LO   (-2)   /* 已到最暗下限，无法再减 */

typedef struct {
    int exp_min, exp_max;    /* 曝光码上下限 */
    int gain_min, gain_max;  /* 增益码上下限 */
    int exp, gain;           /* 当前码值 */
    int out_cnt;             /* 连续越界（超出死区）评估次数 */
    int in_cnt;              /* 连续在范围内评估次数（迟滞用） */
    int wait;                /* 动作后等待的评估次数 */
} ae_state_t;

typedef struct {
    int target_lo, target_hi;
} ae_cfg_t;

/* 初始化：初始码值 + 上限倍数；dim_en 控制下限是否允许降到 initial/4 */
static void ae_init(ae_state_t *s, int exp_init, int gain_init,
                    int exp_max_mult, int gain_max_mult, int dim_en)
{
    s->exp_min   = dim_en ? (exp_init / 4) : exp_init;
    s->gain_min  = dim_en ? (gain_init / 4) : gain_init;
    s->exp_max   = exp_init * exp_max_mult;
    s->gain_max  = gain_init * gain_max_mult;
    if (s->exp_max > 0xFFFF) s->exp_max = 0xFFFF;
    if (s->gain_max > 0xFFFF) s->gain_max = 0xFFFF;
    if (s->exp_min < 1) s->exp_min = 1;
    if (s->gain_min < 1) s->gain_min = 1;
    s->exp = exp_init;
    s->gain = gain_init;
    if (s->exp < s->exp_min) s->exp = s->exp_min;
    if (s->exp > s->exp_max) s->exp = s->exp_max;
    if (s->gain < s->gain_min) s->gain = s->gain_min;
    if (s->gain > s->gain_max) s->gain = s->gain_max;
    s->out_cnt = 0;
    s->in_cnt = 0;
    s->wait = 0;
}

static int ae_step_up(int v, int maxv)
{
    int n = (v * (100 + AE_STEP_PCT) + 99) / 100;
    if (n <= v) n = v + 1;
    if (n > maxv) n = maxv;
    return n;
}

static int ae_step_dn(int v, int minv)
{
    int n = (v * (100 - AE_STEP_PCT)) / 100;
    if (n >= v) n = v - 1;
    if (n < minv) n = minv;
    return n;
}

/* 一次评估。
 * mean: 本轮 96x96 输入图均值（0..255）
 * 返回动作码；*new_exp / *new_gain 返回动作后的码值（无动作时等于当前值）。
 */
static int ae_step(ae_state_t *s, int mean, const ae_cfg_t *cfg,
                   int *new_exp, int *new_gain)
{
    const int lo = cfg->target_lo;
    const int hi = cfg->target_hi;
    int act = AE_ACT_NONE;

    if (new_exp)  *new_exp  = s->exp;
    if (new_gain) *new_gain = s->gain;

    /* 动作后等待若干次评估（等画面稳定） */
    if (s->wait > 0) { s->wait--; return AE_ACT_NONE; }

    if (mean >= lo && mean <= hi) {
        s->in_cnt++;
        s->out_cnt = 0;
        return AE_ACT_NONE;
    }
    s->in_cnt = 0;

    /* 死区：刚越界一点点不动，避免在边界来回抖 */
    if (mean >= lo - AE_DEADBAND && mean <= hi + AE_DEADBAND) {
        s->out_cnt = 0;
        return AE_ACT_NONE;
    }

    s->out_cnt++;
    if (s->out_cnt < AE_CONFIRM) return AE_ACT_NONE;
    s->out_cnt = 0;

    if (mean < lo) {
        /* 需要变亮：先曝光，到上限再用增益 */
        if (s->exp < s->exp_max) {
            s->exp = ae_step_up(s->exp, s->exp_max);
            act = AE_ACT_EXP_UP;
        } else if (s->gain < s->gain_max) {
            s->gain = ae_step_up(s->gain, s->gain_max);
            act = AE_ACT_GAIN_UP;
        } else {
            act = AE_ACT_SAT_HI;
        }
    } else {
        /* 需要变暗：先曝光，到下限再用增益 */
        if (s->exp > s->exp_min) {
            s->exp = ae_step_dn(s->exp, s->exp_min);
            act = AE_ACT_EXP_DN;
        } else if (s->gain > s->gain_min) {
            s->gain = ae_step_dn(s->gain, s->gain_min);
            act = AE_ACT_GAIN_DN;
        } else {
            act = AE_ACT_SAT_LO;
        }
    }

    s->wait = AE_WAIT_EVALS;
    if (new_exp)  *new_exp  = s->exp;
    if (new_gain) *new_gain = s->gain;
    return act;
}

#endif /* AE_CORE_H */
