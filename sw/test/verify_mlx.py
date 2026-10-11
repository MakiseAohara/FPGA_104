#!/usr/bin/env python3
"""
verify_mlx.py -- check the Melexis library's output (produced by running the
                 REAL vendor C on RISC-V under rv32sim.py) against expected
                 values computed here, independently.

Division of labour
------------------
  gen_mlx_ee.py   builds eeData[] from chosen parameters and writes both the
                  .inc for the C side and the "what should come back out" set.
  t_mlx.c         (compiled for rv32 and run on rv32sim) prints every extracted
                  parameter and a few per-pixel values as raw IEEE-754 bit
                  patterns in hex.
  verify_mlx.py   (this file) recomputes the same quantities from the EEPROM
                  layout and compares.

The comparison for the floating-point quantities is done on the *bit pattern*,
not on decimal text, so a mismatch cannot hide in rounding of the printout.

The expected scalar/array formulas below are transcribed from
MLX90640_API.c lines 763-1036 (the Extract* family).  They are deliberately
written out longhand rather than reusing the encoder, so that encoder bugs do
not cancel out extractor bugs.
"""

import re
import subprocess
import sys
import os
import struct

SW = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
EE_INC = os.path.join(SW, 'test', '_mlx_ee.inc')
ELF = os.path.join(SW, 'test', 'build', 't_mlx.bin')
SYM = os.path.join(SW, 'test', 'build', 't_mlx.sym')
SIM = r'D:\FPGA\易灵思\工作区\_工具\rv32sim.py'


def f2bits(x):
    return struct.unpack('<I', struct.pack('<f', x))[0]


def bits2f(b):
    return struct.unpack('<f', struct.pack('<I', b & 0xFFFFFFFF))[0]


def load_ee(path):
    txt = open(path).read()
    vals = []
    for tok in re.findall(r'0x([0-9A-Fa-f]{4})', txt):
        vals.append(int(tok, 16))
    return vals


def run_sim():
    out = subprocess.run(
        [sys.executable, SIM, '--bin', ELF, '--sym', SYM, '--base', '0',
         '--entry-symbol', '_start', '--max', '400000000'],
        capture_output=True, text=True)
    return out.stdout, out.stderr


def parse(stdout):
    got = {}
    for line in stdout.splitlines():
        # tag names contain lowercase (e.g. PARAM_kVdd), so the class must be
        # [A-Za-z_0-9] -- an uppercase-only class silently drops every record.
        m = re.match(r'^([A-Za-z_0-9]+)\s+([0-9a-fA-F]{8})$', line.strip())
        if m:
            got[m.group(1)] = int(m.group(2), 16)
    return got


# ---------------------------------------------------------------------------
#  Independent recomputation of what ExtractParameters must produce
# ---------------------------------------------------------------------------
def expect(ee):
    e = {}
    NIB = lambda w, n: (w >> (4 * (n - 1))) & 0xF
    MSB = lambda w: (w >> 8) & 0xFF
    LSB = lambda w: w & 0xFF
    s8  = lambda v: v - 256 if v > 127 else v

    # --- VDD (763-775)
    kVdd = 32 * s8(MSB(ee[51]))
    vdd25 = ((LSB(ee[51]) - 256) << 5) - 8192
    e['PARAM_kVdd'] = kVdd & 0xFFFFFFFF
    e['PARAM_vdd25'] = vdd25 & 0xFFFFFFFF

    # --- PTAT (779-808)
    KvPTAT = (ee[50] & 0xFC00) >> 10
    if KvPTAT > 31:
        KvPTAT -= 64
    KtPTAT = ee[50] & 0x03FF
    if KtPTAT > 511:
        KtPTAT -= 1024
    e['PARAM_KvPTAT'] = f2bits(KvPTAT / 4096.0)
    e['PARAM_KtPTAT'] = f2bits(KtPTAT / 8.0)
    e['PARAM_vPTAT25'] = ee[49]
    # NOTE the extractor masks but does NOT shift by 12:
    #   alphaPTAT = (eeData[16] & NIBBLE4_MASK) / 2^14 + 8.0f
    e['PARAM_alphaPTAT'] = f2bits((ee[16] & 0xF000) / float(1 << 14) + 8.0)

    # --- gain / tgc / resolution / KsTa (812-839)
    e['PARAM_gainEE'] = (ee[48] & 0xFFFF)
    e['PARAM_tgc'] = f2bits(s8(LSB(ee[60])) / 32.0)
    e['PARAM_resEE'] = (ee[56] & 0x3000) >> 12
    e['PARAM_KsTa'] = f2bits(s8(MSB(ee[60])) / 8192.0)

    # --- KsTo (843-867)
    step = ((ee[63] & 0x3000) >> 12) * 10
    ct2 = NIB(ee[63], 2) * step
    ct3 = ct2 + NIB(ee[63], 3) * step
    e['PARAM_ct0'] = (-40) & 0xFFFFFFFF
    e['PARAM_ct1'] = 0
    e['PARAM_ct2'] = ct2 & 0xFFFFFFFF
    e['PARAM_ct3'] = ct3 & 0xFFFFFFFF
    e['PARAM_ct4'] = 400
    KsToScale = 1 << (NIB(ee[63], 1) + 8)
    e['PARAM_ksTo0'] = f2bits(s8(LSB(ee[61])) / float(KsToScale))
    e['PARAM_ksTo1'] = f2bits(s8(MSB(ee[61])) / float(KsToScale))
    e['PARAM_ksTo2'] = f2bits(s8(LSB(ee[62])) / float(KsToScale))
    e['PARAM_ksTo3'] = f2bits(s8(MSB(ee[62])) / float(KsToScale))
    e['PARAM_ksTo4'] = f2bits(-0.0002)

    # --- CP (1202-1254) -- needed by the alpha formula below
    alphaScale_cp = NIB(ee[32], 4) + 27
    offSP0 = ee[58] & 0x03FF
    if offSP0 > 511:
        offSP0 -= 1024
    offSP1 = (ee[58] & 0xFC00) >> 10
    if offSP1 > 31:
        offSP1 -= 64
    offSP1 += offSP0
    alpSP0 = ee[57] & 0x03FF
    if alpSP0 > 511:
        alpSP0 -= 1024
    alpSP0 = alpSP0 / float(1 << alphaScale_cp)
    alpSP1 = (ee[57] & 0xFC00) >> 10
    if alpSP1 > 31:
        alpSP1 -= 64
    alpSP1 = (1 + alpSP1 / 128.0) * alpSP0
    tgc = s8(LSB(ee[60])) / 32.0

    # --- offset[0] (972-1036)
    occRemScale = NIB(ee[16], 1)
    offsetRef = ee[17]
    occRow = []
    for i in range(6):
        for n in (1, 2, 3, 4):
            v = NIB(ee[18 + i], n)
            occRow.append(v - 16 if v > 7 else v)
    occCol = []
    for i in range(8):
        for n in (1, 2, 3, 4):
            v = NIB(ee[24 + i], n)
            occCol.append(v - 16 if v > 7 else v)
    off0 = (ee[64] & 0xFC00) >> 10
    if off0 > 31:
        off0 -= 64
    off0 = off0 * (1 << occRemScale)
    off0 = offsetRef + (occRow[0] << NIB(ee[16], 3)) + (occCol[0] << NIB(ee[16], 2)) + off0
    e['PIX_offset0'] = off0 & 0xFFFFFFFF

    # --- alpha[0] (871-968): includes the CP subtraction and the rescale loop
    accRemScale = NIB(ee[32], 1)
    alphaRef = ee[33]
    accRow = []
    for i in range(6):
        for n in (1, 2, 3, 4):
            v = NIB(ee[34 + i], n)
            accRow.append(v - 16 if v > 7 else v)
    accCol = []
    for i in range(8):
        for n in (1, 2, 3, 4):
            v = NIB(ee[40 + i], n)
            accCol.append(v - 16 if v > 7 else v)
    alphaScaleEE = NIB(ee[32], 4) + 30
    alphaTemp = []
    for p in range(768):
        i, j = p // 32, p % 32
        a = (ee[64 + p] & 0x03F0) >> 4
        if a > 31:
            a -= 64
        a = a * (1 << accRemScale)
        a = alphaRef + (accRow[i] << NIB(ee[32], 3)) + (accCol[j] << NIB(ee[32], 2)) + a
        a = a / float(1 << alphaScaleEE)
        a = a - tgc * (alpSP0 + alpSP1) / 2
        a = 0.000001 / a
        alphaTemp.append(a)
    t = max(alphaTemp)
    alphaScale = 0
    while t < 32767.4:
        t *= 2
        alphaScale += 1
    e['PARAM_alphaScale'] = alphaScale
    e['PIX_alpha0'] = int(alphaTemp[0] * (2 ** alphaScale) + 0.5) & 0xFFFF

    # --- kta[0] (1040-1105)
    KtaRC = [s8(MSB(ee[54])), s8(MSB(ee[55])), s8(LSB(ee[54])), s8(LSB(ee[55]))]
    ktaScale1_ee = NIB(ee[56], 2) + 8
    ktaScale2 = NIB(ee[56], 1)
    ktaTemp = []
    for p in range(768):
        split = 2 * (p // 32 - (p // 64) * 2) + p % 2
        k = (ee[64 + p] & 0x000E) >> 1
        if k > 3:
            k -= 8
        k = k * (1 << ktaScale2)
        k = KtaRC[split] + k
        k = k / float(1 << ktaScale1_ee)
        ktaTemp.append(k)
    t = max(abs(x) for x in ktaTemp)
    ktaScale1 = 0
    while t < 63.4:
        t *= 2
        ktaScale1 += 1
    e['PARAM_ktaScale'] = ktaScale1
    v = ktaTemp[0] * (2 ** ktaScale1)
    e['PIX_kta0'] = (int(v - 0.5) if v < 0 else int(v + 0.5)) & 0xFFFFFFFF

    # --- kv[0] (1112-1197)
    KvRoCo = NIB(ee[52], 4); KvRoCo = KvRoCo - 16 if KvRoCo > 7 else KvRoCo
    KvReCo = NIB(ee[52], 3); KvReCo = KvReCo - 16 if KvReCo > 7 else KvReCo
    KvRoCe = NIB(ee[52], 2); KvRoCe = KvRoCe - 16 if KvRoCe > 7 else KvRoCe
    KvReCe = NIB(ee[52], 1); KvReCe = KvReCe - 16 if KvReCe > 7 else KvReCe
    KvT = [KvRoCo, KvRoCe, KvReCo, KvReCe]
    kvScaleEE = NIB(ee[56], 3)
    kvTemp = [KvT[2 * (p // 32 - (p // 64) * 2) + p % 2] / float(1 << kvScaleEE)
              for p in range(768)]
    t = max(abs(x) for x in kvTemp)
    kvScale = 0
    while t < 63.4:
        t *= 2
        kvScale += 1
    e['PARAM_kvScale'] = kvScale
    v = kvTemp[0] * (2 ** kvScale)
    e['PIX_kv0'] = (int(v - 0.5) if v < 0 else int(v + 0.5)) & 0xFFFFFFFF

    return e


def main():
    if not (os.path.exists(ELF) and os.path.exists(SYM)):
        print('!! build t_mlx first (see build_rv32_test.ps1 call in the log)')
        return 1
    ee = load_ee(EE_INC)
    if len(ee) != 832:
        print('!! expected 832 EEPROM words, got %d' % len(ee))
        return 1

    stdout, stderr = run_sim()
    got = parse(stdout)
    exp = expect(ee)

    print('--- ExtractParameters / pixel params: vendor C on RV32 vs Python ---')
    bad = 0
    for k in sorted(exp):
        g = got.get(k)
        if g is None:
            print('  %-20s MISSING from simulator output' % k)
            bad += 1
            continue
        ok = (g == exp[k])
        if not ok:
            bad += 1
        print('  %-20s got=0x%08X want=0x%08X  %s' % (k, g, exp[k], 'OK' if ok else '<<< MISMATCH'))

    print()
    print('--- CalculateTo sanity ---')
    n = got.get('TO_FINITE_COUNT')
    print('  finite results: %s (expect 768)' % n)
    if n != 768:
        bad += 1
    for k in ('CALC_Vdd', 'CALC_Ta', 'TO_0', 'TO_383', 'TO_767'):
        if k in got:
            print('  %-10s = %s' % (k, bits2f(got[k])))

    print()
    if bad == 0:
        print('=== MLX VERIFY: ALL CHECKS PASSED ===')
        return 0
    print('=== MLX VERIFY: %d MISMATCH(ES) ===' % bad)
    return 2


if __name__ == '__main__':
    sys.exit(main())
