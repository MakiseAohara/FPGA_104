#!/usr/bin/env python3
"""patch21.py - build main_live21.cc (v20 + exposure sweep)."""
import io
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SRC = HERE.parent / "v20" / "src" / "main_live20.cc"
DST = HERE / "src" / "main_live21.cc"

SWEEP_BLOCK = r'''
#if SWEEP_ON
typedef struct { unsigned vts; unsigned long exp20; unsigned char gc, gf; } sw_t;
/* exp20 = 行数<<4（3e00 低4位, 3e01, 3e02 高4位） */
static const sw_t SW[] = {
   {1500,0x1BBF0,0x80,0x2A},                                   /* 0 开机值 */
   {1500,0x00640,0x80,0x2A},{1500,0x00C80,0x80,0x2A},{1500,0x01900,0x80,0x2A},
   {1500,0x03200,0x80,0x2A},{1500,0x04B00,0x80,0x2A},{1500,0x05AA0,0x80,0x2A},
   {1500,0x1BBF0,0x80,0x2A},                                   /* 7 开机值（复测） */
   {3000,0x0BAE0,0x80,0x2A},{6000,0x17660,0x80,0x2A},{7100,0x1BB20,0x80,0x2A},
   {1500,0x05AA0,0x00,0x20},{1500,0x05AA0,0x00,0x30},{1500,0x05AA0,0x00,0x3F},
   {1500,0x05AA0,0x01,0x20},{1500,0x05AA0,0x01,0x3F},
   {1500,0x05AA0,0x03,0x20},{1500,0x05AA0,0x03,0x3F},
   {1500,0x05AA0,0x07,0x20},
   {1500,0x05AA0,0x80,0x2A},{1500,0x05AA0,0x80,0x3F},{1500,0x05AA0,0x80,0x20},
   {1500,0x1BBF0,0x80,0x2A}                                    /* 22 恢复开机值 */
};
#define SW_N   ((int)(sizeof(SW)/sizeof(SW[0])))
static int sw_n = 0, sw_pass = 0, sw_done = 0;

static int sw_write(int idx)
{
   const sw_t *s = &SW[idx];
   int r;
   r = cam_checked_write(&g_cam_io, CAM_REG_VTS_H, (unsigned char)((s->vts >> 8) & 0x7F), 0);
   if (r == CAM_OK) r = cam_checked_write(&g_cam_io, CAM_REG_VTS_L, (unsigned char)(s->vts & 0xFF), 0);
   if (r == CAM_OK) r = cam_checked_write(&g_cam_io, CAM_REG_EXP_H, (unsigned char)((s->exp20 >> 16) & 0x0F), 0);
   if (r == CAM_OK) r = cam_checked_write(&g_cam_io, CAM_REG_EXP_M, (unsigned char)((s->exp20 >> 8) & 0xFF), 0);
   if (r == CAM_OK) r = cam_checked_write(&g_cam_io, CAM_REG_EXP_L, (unsigned char)(s->exp20 & 0xFF), 0);
   if (r == CAM_OK) r = cam_checked_write(&g_cam_io, CAM_REG_GAIN_C, s->gc, 0);
   if (r == CAM_OK) r = cam_checked_write(&g_cam_io, CAM_REG_GAIN_F, s->gf, 0);
   return r;
}

static void sw_apply(int idx)
{
   const int r = sw_write(idx);
   if (r != CAM_OK) {
      bsp_printf("MMT_SWEEP_ERR idx=%d err=%d\n\r", idx, r);
      (void)sw_write(0);                 /* 立即写回开机值 */
      sw_done = 1;
      return;
   }
   bsp_printf("MMT_SWEEP pass=%d idx=%d vts=%u exp20=0x%lx gc=0x%02x gf=0x%02x\n\r",
              sw_pass, idx, (unsigned)SW[idx].vts, SW[idx].exp20,
              (unsigned)SW[idx].gc, (unsigned)SW[idx].gf);
}

static void sweep_tick(void)
{
   if (sw_done) return;
   if ((sw_n % 12) == 0) {
      const int seq = sw_n / 12;
      if (seq >= 2 * SW_N) {             /* 两遍扫完 */
         (void)sw_write(0);              /* 写回开机值 */
         bsp_printf("MMT_SWEEP_DONE\n\r");
         sw_done = 1;
         return;
      }
      sw_pass = seq / SW_N;
      sw_apply(seq % SW_N);
      if (sw_done) return;
   }
   sw_n++;
}
#endif
'''


def main() -> int:
    s = io.open(SRC, encoding="utf-8").read()
    orig = len(s)

    # version strings
    for a, b in (("MMT_LIVE_BOOT v20", "MMT_LIVE_BOOT v21"),
                 ("MMT_CFG v20", "MMT_CFG v21")):
        if a not in s:
            print("MISS", a)
            return 1
        s = s.replace(a, b, 1)

    # insert the sweep block right before dec_update
    anchor = "static int dec_update(int32_t score, int motion, int ir_hot, int infer_ran,"
    if anchor not in s:
        print("MISS dec_update anchor")
        return 1
    s = s.replace(anchor, SWEEP_BLOCK.strip() + "\n\n" + anchor, 1)

    # call it just before the AE evaluation block (the 3rd #if AUTOEXP_ON)
    idx = -1
    for _ in range(3):
        idx = s.find("#if AUTOEXP_ON", idx + 1)
    if idx < 0:
        print("MISS AE block")
        return 1
    s = s[:idx] + "        sweep_tick();\n" + s[idx:]

    io.open(DST, "w", encoding="utf-8", newline="\n").write(s)
    print("wrote", DST, len(s), "bytes (delta %+d)" % (len(s) - orig))
    print("  SW entries:", s.count("{1500,") + s.count("{3000,") + s.count("{6000,") + s.count("{7100,"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
