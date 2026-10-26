/* Offline candidate only. No MMIO, SCCB, exposure or image-buffer writes.
 * Input must be unprocessed Bayer quads, never the v19 grayscale IMG dump.
 * Grey-world gains are proposals; scene statistics cannot establish a neutral
 * reference or the physical sensor phase. Caller must specify the phase.
 */
#ifndef WB_ESTIMATOR_H
#define WB_ESTIMATOR_H
#include <stdint.h>

enum wb_phase { WB_RGGB, WB_BGGR, WB_GRBG, WB_GBRG };
enum wb_result { WB_PROPOSAL = 0, WB_CAPPED = 1, WB_FEW_SAMPLES = -1,
                 WB_GREEN_MISMATCH = -2, WB_INVALID = -3 };
typedef struct {
    uint64_t sum_r, sum_g0, sum_g1, sum_b;
    uint32_t accepted, rejected;
} wb_stats;
typedef struct {
    uint32_t min_quads;
    uint16_t min_gain, max_gain;  /* Q8.8: 256 == unity */
    uint16_t max_green_diff_permille;
    uint8_t black_limit, clip_limit;
} wb_config;
typedef struct { uint16_t r, g, b; } wb_gains;

static void wb_reset(wb_stats *s)
{
    s->sum_r = s->sum_g0 = s->sum_g1 = s->sum_b = 0;
    s->accepted = s->rejected = 0;
}

static int wb_observe(wb_stats *s, const wb_config *c, enum wb_phase phase,
                      uint8_t a, uint8_t b, uint8_t d, uint8_t e)
{
    uint8_t r, g0, g1, blue;
    if (!s || !c || phase < WB_RGGB || phase > WB_GBRG ||
        c->black_limit >= c->clip_limit || s->accepted == UINT32_MAX ||
        s->rejected == UINT32_MAX) return WB_INVALID;
    /* Reject the whole 2x2 quad so all colour sums use matching locations. */
    if (a <= c->black_limit || b <= c->black_limit ||
        d <= c->black_limit || e <= c->black_limit ||
        a >= c->clip_limit || b >= c->clip_limit ||
        d >= c->clip_limit || e >= c->clip_limit) {
        s->rejected++;
        return WB_FEW_SAMPLES;
    }
    switch (phase) {
    case WB_RGGB: r=a; g0=b; g1=d; blue=e; break;
    case WB_BGGR: r=e; g0=b; g1=d; blue=a; break;
    case WB_GRBG: r=b; g0=a; g1=e; blue=d; break;
    default:      r=d; g0=a; g1=e; blue=b; break;
    }
    s->sum_r += r; s->sum_g0 += g0; s->sum_g1 += g1; s->sum_b += blue;
    s->accepted++;
    return WB_PROPOSAL;
}

static uint16_t wb_limit(uint64_t value, const wb_config *c, int *capped)
{
    if (value < c->min_gain) { *capped = 1; return c->min_gain; }
    if (value > c->max_gain) { *capped = 1; return c->max_gain; }
    return (uint16_t)value;
}

static int wb_propose(const wb_stats *s, const wb_config *c, wb_gains *out)
{
    uint64_t green, diff;
    int capped = 0;
    if (!s || !c || !out || !c->min_gain || c->min_gain > 256 ||
        c->max_gain < 256 || c->min_gain > c->max_gain ||
        !c->min_quads || c->black_limit >= c->clip_limit) return WB_INVALID;
    out->r = out->g = out->b = 256;
    if (s->accepted < c->min_quads || !s->sum_r || !s->sum_b)
        return WB_FEW_SAMPLES;
    /* Accumulated sums are bounded by accepted(uint32) * 255. */
    if (s->sum_r > (uint64_t)s->accepted * 255 ||
        s->sum_b > (uint64_t)s->accepted * 255 ||
        s->sum_g0 > (uint64_t)s->accepted * 255 ||
        s->sum_g1 > (uint64_t)s->accepted * 255) return WB_INVALID;
    green = (s->sum_g0 + s->sum_g1) / 2;
    if (!green) return WB_FEW_SAMPLES;
    diff = s->sum_g0 > s->sum_g1 ? s->sum_g0 - s->sum_g1 : s->sum_g1 - s->sum_g0;
    if (diff * 1000 > green * c->max_green_diff_permille)
        return WB_GREEN_MISMATCH;
    out->r = wb_limit((green * 256 + s->sum_r/2) / s->sum_r, c, &capped);
    out->b = wb_limit((green * 256 + s->sum_b/2) / s->sum_b, c, &capped);
    return capped ? WB_CAPPED : WB_PROPOSAL;
}
#endif
