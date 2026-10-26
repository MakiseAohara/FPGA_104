#include "wb_estimator.h"

/* Executed as a standalone RV32IM function under Unicorn, never flashed.
 * A nonzero return identifies the failed numerical property. */
int wb_selftest(void)
{
    wb_config c = {64, 128, 1024, 200, 4, 250};
    wb_stats s;
    wb_gains g;
    int p, n;
    for (p = WB_RGGB; p <= WB_GBRG; ++p) {
        wb_reset(&s);
        for (n = 0; n < 64; ++n) {
            if (p == WB_RGGB) wb_observe(&s, &c, p, 64, 128, 128, 192);
            if (p == WB_BGGR) wb_observe(&s, &c, p, 192, 128, 128, 64);
            if (p == WB_GRBG) wb_observe(&s, &c, p, 128, 64, 192, 128);
            if (p == WB_GBRG) wb_observe(&s, &c, p, 128, 192, 64, 128);
        }
        if (wb_propose(&s,&c,&g) != WB_PROPOSAL || g.r != 512 ||
            g.g != 256 || g.b != 171 || s.accepted != 64) return 10+p;
    }
    wb_reset(&s);
    for (n=0;n<64;++n) wb_observe(&s,&c,WB_RGGB,100,100,100,100);
    if (wb_propose(&s,&c,&g) != WB_PROPOSAL ||
        g.r != 256 || g.g != 256 || g.b != 256) return 20;
    wb_reset(&s);
    for (n=0;n<64;++n) wb_observe(&s,&c,WB_RGGB,0,100,100,100);
    if (wb_propose(&s,&c,&g) != WB_FEW_SAMPLES || s.rejected != 64) return 21;
    wb_reset(&s);
    for (n=0;n<64;++n) wb_observe(&s,&c,WB_RGGB,100,100,100,255);
    if (wb_propose(&s,&c,&g) != WB_FEW_SAMPLES || s.rejected != 64) return 22;
    wb_reset(&s);
    wb_observe(&s,&c,WB_RGGB,100,100,100,100);
    if (wb_propose(&s,&c,&g) != WB_FEW_SAMPLES) return 23;
    wb_reset(&s);
    for (n=0;n<64;++n) wb_observe(&s,&c,WB_RGGB,100,100,160,100);
    if (wb_propose(&s,&c,&g) != WB_GREEN_MISMATCH || g.r != 256) return 24;
    wb_reset(&s);
    for (n=0;n<64;++n) wb_observe(&s,&c,WB_RGGB,8,200,200,8);
    if (wb_propose(&s,&c,&g) != WB_CAPPED || g.r != 1024 || g.b != 1024) return 25;
    s.accepted = 1000000; s.sum_r=64000000; s.sum_g0=s.sum_g1=128000000;
    s.sum_b=192000000;
    if (wb_propose(&s,&c,&g) != WB_PROPOSAL || g.r != 512 || g.b != 171) return 26;
    c.min_gain=0;
    if (wb_propose(&s,&c,&g) != WB_INVALID) return 27;
    return 0;
}
