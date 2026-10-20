////////////////////////////////////////////////////////////////////////////////
// ASCII image dump — visual check that we are really reading the camera frame.
//
// Format established by the frame finder: 4 bytes per pixel, 16-bit pixel
// duplicated in both halves of the 32-bit word, byte0 varies most (luma).
//
// Prints a 32x16 character rendering of the frame plus min/max/mean, for banks
// 0 and 2 (the two the video writer actually refreshes).
////////////////////////////////////////////////////////////////////////////////

#include <stdint.h>
#include "bsp.h"
#include "print.h"

#define FB_BASE      0x01000000u
#define FB_W         960
#define FB_H         1080
#define FB_FRAME_LEN (960u * 1080u * 4u + 0x200u)

static const char LEVELS[] = " .:-=+*#";
#define NLEVEL 8

static void dump(int bank, const char* tag)
{
   const uint32_t base = FB_BASE + (uint32_t)bank * FB_FRAME_LEN;
   uint32_t mn = 255, mx = 0;
   uint64_t sum = 0;
   uint8_t img[16][32];

   for (int y = 0; y < 16; ++y) {
      const uint32_t sy = (uint32_t)y * FB_H / 16u;
      const volatile uint32_t* row =
            (const volatile uint32_t*)(base + (sy * FB_W) * 4u);
      for (int x = 0; x < 32; ++x) {
         const uint32_t sx = (uint32_t)x * FB_W / 32u;
         const uint32_t v = row[sx] & 0xFFu;      /* byte0 = luma */
         img[y][x] = (uint8_t)v;
         if (v < mn) mn = v;
         if (v > mx) mx = v;
         sum += v;
      }
   }

   bsp_printf("MMT_IMG %s bank=%d min=%d max=%d mean=%d\n\r",
              tag, bank, (int)mn, (int)mx, (int)(sum / (16 * 32)));

   for (int y = 0; y < 16; ++y) {
      char line[33];
      for (int x = 0; x < 32; ++x) {
         uint32_t lv = (uint32_t)img[y][x] * NLEVEL / 256u;
         if (lv >= NLEVEL) lv = NLEVEL - 1;
         line[x] = LEVELS[lv];
      }
      line[32] = 0;
      bsp_printf("MMT_ROW %s %s\n\r", tag, line);
   }
}

int main(void)
{
   bsp_printf("MMT_ASCII_BOOT\n\r");
   for (int round = 0; round < 3; ++round) {
      dump(2, "b2");
      dump(0, "b0");
      for (volatile uint32_t d = 0; d < 6000000u; ++d) {}
   }
   bsp_printf("MMT_ASCII_DONE\n\r");
   while (1) {}
}
