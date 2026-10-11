#!/usr/bin/env python3
"""
gen_mlx_ee.py -- build a synthetic-but-layout-valid MLX90640 EEPROM image and
                 the *expected* params that MLX90640_ExtractParameters() must
                 produce from it.

WHY
---
We want to prove that the vendor's MLX90640_API.c really runs correctly when
compiled for RISC-V -- not merely that it compiles.  The way to do that without
a sensor is a round trip:

    chosen params  --encode-->  eeData[832]  --ExtractParameters()-->  params'

and then check params' == params.  The encoder below is written from the
extraction code in MLX90640_API.c (lines 763-1036), and the same file also
emits the expected values so the C side can print what it got and a comparison
can be made.

EEPROM layout used (all from MLX90640_API.c):
  word 16   NIB1 occRemScale  NIB2 occColScale  NIB3 occRowScale  NIB4 alphaPTAT
  word 17   offsetRef (int16)
  word 18-23   occRow[24]   (4 nibbles per word)
  word 24-31   occColumn[32]
  word 32   NIB1 accRemScale  NIB2 accColScale  NIB3 accRowScale  NIB4 alphaScale-30
  word 33   alphaRef
  word 34-39   accRow[24]
  word 40-47   accColumn[32]
  word 48   gainEE (int16)          word 49  vPTAT25
  word 50   [15:10] KvPTAT(6b s)  [9:0] KtPTAT(10b s)
  word 51   MSB kVdd(int8)  LSB vdd25 raw
  word 54/55   KtaRC[0..3]
  word 56   NIB1 ktaScale2  NIB2 ktaScale1-8  [13:12] resolutionEE
  word 60   MSB KsTa(int8)  LSB tgc(int8)
  word 61/62   ksTo raw bytes       word 63  NIB1 KsToScale-8, NIB2 ct[2], NIB3 ct[3], [13:12] step/10
  word 64..831  packed per pixel:  [15:10] offset(6b s) [9:4] alpha(6b s) [3:1] kta(3b s) [0] outlier

CONSTRAINTS the data must satisfy or ExtractDeviatingPixels() errors out
(MLX90640_API.c:1313-1322):
      eeData[64+p] != 0        otherwise pixel p is "broken"
      (eeData[64+p] & 1) == 0  otherwise pixel p is an "outlier"
   at most 4 of either, so in practice: every packed word must be non-zero and even.
"""

import struct
import sys

EE_NUM = 832
PIX = 768

# ------------------------------------------------------------------ helpers
def nib(v, n):
    """place a 0..15 value in nibble n (1..4) of a 16-bit word"""
    return (v & 0xF) << (4 * (n - 1))

def s6(v):
    return v & 0x3F

def s10(v):
    return v & 0x3FF

def s3(v):
    return v & 0x7


def build():
    ee = [0] * EE_NUM

    # ---- chosen raw scales / references (kept small so the arithmetic is easy
    #      to follow, and so the rescale loops terminate quickly) -------------
    occRemScale, occColScale, occRowScale = 0, 0, 0
    alphaPTAT_nib = 5
    accRemScale, accColScale, accRowScale = 0, 0, 0
    alphaScale_nib = 0                       # -> alphaScale = 30
    ktaScale2 = 0
    ktaScale1_nib = 0                        # -> ktaScale1 = 8
    kvScale_nib = 0                          # -> kvScale = 0

    offsetRef = 100
    alphaRef = 2000
    gainEE = 3000
    vPTAT25 = 15000
    KvPTAT_raw = 10                          # 6-bit signed, >31 would go negative
    KtPTAT_raw = 200                         # 10-bit signed
    kVdd_raw = 40                            # int8 -> kVdd = 32*40 = 1280
    vdd25_raw = 200                          # -> ((200-256)<<5) - 8192 = -9984
    KtaRC = [100, 110, 120, 130]
    resolutionEE = 1
    KsTa_raw = 60                            # int8 -> 60/8192
    tgc_raw = 32                             # int8 -> 1.0
    ksTo_raw = [20, 30, 40, 50]              # int8 each
    KsToScale_nib = 0                        # -> KsToScale = 1<<8
    step_raw = 1                             # -> step = 10
    ct2_raw = 3
    ct3_raw = 5

    ee[16] = nib(occRemScale, 1) | nib(occColScale, 2) | nib(occRowScale, 3) | nib(alphaPTAT_nib, 4)
    ee[17] = offsetRef & 0xFFFF

    occRow = [(i % 7) for i in range(24)]           # 0..6, no sign flip needed
    occCol = [(i % 7) for i in range(32)]
    for i in range(6):
        p = i * 4
        ee[18 + i] = nib(occRow[p], 1) | nib(occRow[p+1], 2) | nib(occRow[p+2], 3) | nib(occRow[p+3], 4)
    for i in range(8):
        p = i * 4
        ee[24 + i] = nib(occCol[p], 1) | nib(occCol[p+1], 2) | nib(occCol[p+2], 3) | nib(occCol[p+3], 4)

    ee[32] = nib(accRemScale, 1) | nib(accColScale, 2) | nib(accRowScale, 3) | nib(alphaScale_nib, 4)
    ee[33] = alphaRef & 0xFFFF

    accRow = [(i % 7) for i in range(24)]
    accCol = [(i % 7) for i in range(32)]
    for i in range(6):
        p = i * 4
        ee[34 + i] = nib(accRow[p], 1) | nib(accRow[p+1], 2) | nib(accRow[p+2], 3) | nib(accRow[p+3], 4)
    for i in range(8):
        p = i * 4
        ee[40 + i] = nib(accCol[p], 1) | nib(accCol[p+1], 2) | nib(accCol[p+2], 3) | nib(accCol[p+3], 4)

    ee[48] = gainEE & 0xFFFF
    ee[49] = vPTAT25 & 0xFFFF
    ee[50] = (s6(KvPTAT_raw) << 10) | s10(KtPTAT_raw)
    ee[51] = ((kVdd_raw & 0xFF) << 8) | (vdd25_raw & 0xFF)

    # ★ word 52: Kv 的四个角系数（KvRoCo/KvReCo/KvRoCe/KvReCe）。
    #   注意 Kv 不是逐像素打包的，而是这个 4 值图案。
    #   ⚠️ 这四个值**不能全 0**：ExtractKvPixelParameters 末尾有
    #        while (temp < 63.4) { temp = temp*2; kvScale++; }
    #      全 0 时 temp 恒为 0 → **永久死循环**（库自身没有超时）。
    #      alpha/kta 同理（各自的 while 阈值 32767.4 / 63.4）。
    KvRoCo, KvReCo, KvRoCe, KvReCe = 3, 4, 5, 6
    ee[52] = nib(KvReCe, 1) | nib(KvRoCe, 2) | nib(KvReCo, 3) | nib(KvRoCo, 4)

    ee[54] = ((KtaRC[0] & 0xFF) << 8) | (KtaRC[2] & 0xFF)
    ee[55] = ((KtaRC[1] & 0xFF) << 8) | (KtaRC[3] & 0xFF)
    ee[56] = nib(ktaScale2, 1) | nib(ktaScale1_nib, 2) | nib(kvScale_nib, 3) | ((resolutionEE & 0x3) << 12)

    # word 57/58/59: 补偿像素（CP）的 alpha / offset / cpKta / cpKv
    cpAlphaSP0_raw = 120          # 10-bit signed
    cpAlphaSP1_delta = 8          # 6-bit signed -> (1 + d/128)*alphaSP0
    cpOffSP0_raw = 200            # 10-bit signed
    cpOffSP1_raw = 5              # 6-bit signed, 加在 SP0 上
    cpKta_raw = 20                # int8
    cpKv_raw = 22                 # int8
    ee[57] = (s6(cpAlphaSP1_delta) << 10) | (cpAlphaSP0_raw & 0x3FF)
    ee[58] = (s6(cpOffSP1_raw) << 10) | (cpOffSP0_raw & 0x3FF)
    ee[59] = ((cpKv_raw & 0xFF) << 8) | (cpKta_raw & 0xFF)

    ee[60] = ((KsTa_raw & 0xFF) << 8) | (tgc_raw & 0xFF)
    ee[61] = ((ksTo_raw[1] & 0xFF) << 8) | (ksTo_raw[0] & 0xFF)
    ee[62] = ((ksTo_raw[3] & 0xFF) << 8) | (ksTo_raw[2] & 0xFF)
    ee[63] = nib(KsToScale_nib, 1) | nib(ct2_raw, 2) | nib(ct3_raw, 3) | ((step_raw & 0x3) << 12)

    # ---- packed per-pixel words -------------------------------------------
    # vary the fields a little so a "compare" is meaningful, keeping bit0 = 0
    off_f = [None] * PIX
    alp_f = [None] * PIX
    kta_f = [None] * PIX
    for p in range(PIX):
        off_f[p] = (p % 11) - 5          # -5..5   (6-bit signed range)
        alp_f[p] = (p % 13) - 6          # -6..6
        kta_f[p] = (p % 3)               # 0..2    (3-bit signed)
        w = ((s6(off_f[p]) << 10) | (s6(alp_f[p]) << 4) | (s3(kta_f[p]) << 1)) & 0xFFFE
        if w == 0:
            # ExtractDeviatingPixels() treats a zero packed word as a BROKEN
            # pixel; up to 4 are tolerated but there is no reason to hand it one.
            alp_f[p] = 1
            w = ((s6(off_f[p]) << 10) | (s6(alp_f[p]) << 4) | (s3(kta_f[p]) << 1)) & 0xFFFE
        ee[64 + p] = w

    # ---- expected scalar params (mirror of MLX90640_API.c:763-867) --------
    kVdd = 32 * struct.unpack('b', struct.pack('B', kVdd_raw & 0xFF))[0]
    vdd25 = ((vdd25_raw - 256) << 5) - 8192
    KvPTAT = KvPTAT_raw - 64 if KvPTAT_raw > 31 else KvPTAT_raw
    KtPTAT = KtPTAT_raw - 1024 if KtPTAT_raw > 511 else KtPTAT_raw
    exp = {
        'kVdd': kVdd,
        'vdd25': vdd25,
        'KvPTAT_q12': KvPTAT,          # KvPTAT/4096 -> report numerator
        'KtPTAT_q3': KtPTAT,           # KtPTAT/8    -> report numerator
        'vPTAT25': vPTAT25,
        'alphaPTAT_q14': alphaPTAT_nib + 8 * (1 << 14),   # alphaPTAT * 2^14
        'gainEE': gainEE,
        'tgc_q5': tgc_raw,             # tgc = tgc_raw/32 -> report numerator
        'resolutionEE': resolutionEE,
        'KsTa_q13': struct.unpack('b', struct.pack('B', KsTa_raw & 0xFF))[0],
        'KsToScale': 1 << (KsToScale_nib + 8),
        'ct0': -40, 'ct1': 0,
        'ct2': ct2_raw * (step_raw * 10),
        'ct3': ct2_raw * (step_raw * 10) + ct3_raw * (step_raw * 10),
        'ct4': 400,
        'ktaScale1': ktaScale1_nib + 8,
        'ktaScale2': ktaScale2,
        'alphaScaleFromEE': alphaScale_nib + 30,
    }
    return ee, exp, dict(off_f=off_f, alp_f=alp_f, kta_f=kta_f,
                         offsetRef=offsetRef, alphaRef=alphaRef,
                         accRow=accRow, accCol=accCol, KtaRC=KtaRC)


def main():
    ee, exp, extra = build()
    out_inc = sys.argv[1] if len(sys.argv) > 1 else '_mlx_ee.inc'
    with open(out_inc, 'w') as fh:
        fh.write('/* generated by gen_mlx_ee.py -- synthetic MLX90640 EEPROM image */\n')
        for i in range(0, EE_NUM, 8):
            fh.write('    ' + ','.join('0x%04X' % ee[i + k] for k in range(8)) + ',\n')
    print('wrote %s (%d words)' % (out_inc, EE_NUM))
    print('--- expected scalar params ---')
    for k in sorted(exp):
        print('  %-18s %d' % (k, exp[k]))

    # sanity: the packed words must survive ExtractDeviatingPixels
    broken = sum(1 for p in range(PIX) if ee[64 + p] == 0)
    outlier = sum(1 for p in range(PIX) if ee[64 + p] & 1)
    print('--- validity ---')
    print('  packed words == 0 (broken) : %d  (must be <= 4)' % broken)
    print('  packed words odd (outlier) : %d  (must be <= 4)' % outlier)


if __name__ == '__main__':
    main()
