////////////////////////////////////////////////////////////////////////////////
// Framebuffer finder.
//
// The write/evict probe proved the video does NOT write 0x01000000, yet HDMI
// shows a picture. So find where the image actually lives.
//
// For every 1 MB candidate base in 0x00000000..0x04000000, read 4096 consecutive
// 32-bit words and compute per-byte-lane mean / std. Real image data has lanes
// that differ (luma vs chroma, or R/G/B); uninitialised memory gives four
// nearly identical lanes.
//
// A candidate is reported when the spread of the four lane means exceeds 12 or
// the spread of the four lane stds exceeds 12.
////////////////////////////////////////////////////////////////////////////////

#include <stdint.h>
#include "bsp.h"
#include "print.h"

#define SCAN_TOP  0x04000000u
#define STEP      0x00100000u
#define NWORDS    4096u

static int isqrt_u32(uint32_t v)
{
   uint32_t r = 0;
   while ((uint64_t)(r + 1) * (r + 1) <= v) ++r;
   return (int)r;
}

static void scan(uint32_t base, uint32_t* best_base, int* best_spread)
{
   const volatile uint32_t* p = (const volatile uint32_t*)base;
   uint64_t s[4] = {0, 0, 0, 0};
   uint64_t q[4] = {0, 0, 0, 0};

   for (uint32_t i = 0; i < NWORDS; ++i) {
      const uint32_t w = p[i];
      for (int b = 0; b < 4; ++b) {
         const uint32_t v = (w >> (8 * b)) & 0xFFu;
         s[b] += v;
         q[b] += (uint64_t)v * v;
      }
   }

   int mean[4], sd[4];
   for (int b = 0; b < 4; ++b) {
      mean[b] = (int)(s[b] / NWORDS);
      const uint64_t var = (q[b] / NWORDS) - (uint64_t)mean[b] * mean[b];
      sd[b] = isqrt_u32((uint32_t)var);
   }

   int mmin = mean[0], mmax = mean[0], smin = sd[0], smax = sd[0];
   for (int b = 1; b < 4; ++b) {
      if (mean[b] < mmin) mmin = mean[b];
      if (mean[b] > mmax) mmax = mean[b];
      if (sd[b] < smin) smin = sd[b];
      if (sd[b] > smax) smax = sd[b];
   }
   const int mspread = mmax - mmin;
   const int sspread = smax - smin;

   if (mspread > *best_spread) { *best_spread = mspread; *best_base = base; }

   if (mspread > 12 || sspread > 12) {
      bsp_printf("MMT_SCAN base=%x m=%d,%d,%d,%d s=%d,%d,%d,%d\n\r",
                 base, mean[0], mean[1], mean[2], mean[3],
                 sd[0], sd[1], sd[2], sd[3]);
   }
}

int main(void)
{
   bsp_printf("MMT_SCAN_BOOT\n\r");
   uint32_t best_base = 0;
   int best_spread = -1;

   /* 0x0..0xFFF is a decode hole on this SoC: any access there bus-errors and
      hangs the core, so the scan must start at 1 MB. */
   for (uint32_t b = 0x00100000u; b < SCAN_TOP; b += STEP) {
      scan(b, &best_base, &best_spread);
      if ((b & 0x00700000u) == 0) bsp_printf("MMT_SCAN_AT %x\n\r", b);
   }

   bsp_printf("MMT_SCAN_BEST base=%x mspread=%d\n\r", best_base, best_spread);
   bsp_printf("MMT_SCAN_DONE\n\r");
   while (1) {}
}
