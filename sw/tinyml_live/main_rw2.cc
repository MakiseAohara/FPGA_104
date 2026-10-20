////////////////////////////////////////////////////////////////////////////////
// Write / evict / read-back probe.
//
// The first version was inconclusive because the SoC has a D-cache (4K words,
// ~16 KB) and an 8-word pattern simply stays in it.
//
// This version:
//   1. writes a pattern at the framebuffer base
//   2. reads a 2 MB sweep to evict the cache
//   3. re-reads the pattern
//
// If the video really writes that region, the sweep will have pulled the
// video's data in and the pattern will be gone. If the pattern survives, the
// video genuinely does not write there.
////////////////////////////////////////////////////////////////////////////////

#include <stdint.h>
#include "bsp.h"
#include "print.h"

#define FB_BASE   0x01000000u
#define SAFE_BASE 0x00200000u
#define NW        8
#define SWEEP_WORDS (512u * 1024u)   /* 2 MB */

static uint32_t pat(uint32_t k) { return 0xA5A50000u | k; }

static uint32_t sweep(uint32_t base)
{
   const volatile uint32_t* p = (const volatile uint32_t*)base;
   uint32_t acc = 0;
   for (uint32_t i = 0; i < SWEEP_WORDS; ++i) acc += p[i];
   return acc;
}

static void check(const char* tag, uint32_t base)
{
   volatile uint32_t* p = (volatile uint32_t*)base;

   for (uint32_t k = 0; k < NW; ++k) p[k] = pat(k);

   uint32_t ok = 0, bad = 0;
   for (uint32_t k = 0; k < NW; ++k) {
      if (p[k] == pat(k)) ++ok; else ++bad;
   }
   bsp_printf("MMT_RW_%s imm_ok=%d imm_bad=%d\n\r", tag, (int)ok, (int)bad);

   // evict the cache by touching 2 MB, then re-read
   const uint32_t acc = sweep(base + 0x10000u);

   ok = 0; bad = 0;
   for (uint32_t k = 0; k < NW; ++k) {
      if (p[k] == pat(k)) ++ok; else ++bad;
   }
   bsp_printf("MMT_RW_%s evict_ok=%d evict_bad=%d acc=%x v0=%x v1=%x\n\r",
              tag, (int)ok, (int)bad, acc, p[0], p[1]);
}

int main(void)
{
   bsp_printf("MMT_RW2_BOOT\n\r");
   check("safe", SAFE_BASE);
   check("fb",   FB_BASE);
   bsp_printf("MMT_RW2_DONE\n\r");
   while (1) {}
}
