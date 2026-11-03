#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""eta_sim.py - 行为预测（eta）逻辑的离线自检：把 mot_core.h 的 mot_eta_frames 面积路
1:1 搬到 Python，用合成"走近/走远/站定"序列验证输出是否合理。

判定依据（设计意图）：
  · 站定（面积不涨）      -> -1（不预警）
  · 慢慢走近（6~8%/帧）   -> eta 8~20（提前量足够）
  · 快步走近（>=15%/帧）  -> eta <= 6（很快到位）
  · 走远（面积变小）      -> -1
  · 已贴脸（面积>=55%）   -> eta <= 1
"""
W = H = 96
NEAR_PCT, ARATE_MIN = 55, 4
TGT = W * H * NEAR_PCT // 100

def eta(area, arate):
    """v17.2：算不到 60 帧内就返回 60（"还早"），比返回 -1 更好判断。"""
    if arate < ARATE_MIN or area <= 0:
        return -1
    a = area
    for k in range(1, 61):
        a += a * arate // 100
        if a >= TGT:
            return k
        if a > W * H:
            return k
    return 60

def arate_ema(prev, cur, old):
    """与 mot_core.h v17.2 一致：面积变大时立即跟上（避免 EMA 冷启动把预警吃掉），
    变小时按 3/4 权重慢慢降。"""
    r = cur * 100 // prev - 100
    r = max(-60, min(60, r))
    ema = (old * 3 + r) // 4
    return max(r, ema) if r > 0 else ema

def arate_ema2(prev, cur, old):
    r = cur * 100 // prev - 100
    r = max(-60, min(60, r))
    return (old * 3 + r) // 4

def sim(growth_pct, start_area, frames=40):
    area, ar, grow = start_area, 0, 0
    out = []
    for _ in range(frames):
        new = area + area * growth_pct // 100
        r_now = new * 100 // area - 100
        if r_now >= 3:      # v17.2：连续 2 帧"在变大"才给提前量（单帧抖动不算）
            grow += 1
        elif r_now <= 0:
            grow = 0
        ar = arate_ema(area, new, ar)
        # v17.2：至少连续 2 帧在长才给提前量，避免单帧面积抖动误报
        out.append((new, ar, eta(new, ar) if grow >= 2 else -1))
        area = new
    return out

cases = [
    ("站定 2000 面积", 0, 2000), ("慢慢走近 +6%", 6, 800), ("走近 +10%", 10, 1200),
    ("快走近 +20%", 20, 1500), ("贴脸 +8% 从 4000", 8, 4000), ("走远 -10%", -10, 4000),
]
print("| 场景 | 第 3 帧 eta | 第 5 帧 eta | 首次 <=8 帧 | 首次 <=3 帧 | 面积达 55% 帧 |")
print("|---|---|---|---|---|---|")
ok = True
for name, g, a0 in cases:
    seq = sim(g, a0)
    e3 = seq[2][2]; e5 = seq[4][2]
    first8 = next((i + 1 for i, s in enumerate(seq) if 0 <= s[2] <= 8), None)
    first3 = next((i + 1 for i, s in enumerate(seq) if 0 <= s[2] <= 3), None)
    hit = next((i + 1 for i, s in enumerate(seq) if s[0] >= TGT), None)
    print("| %s | %s | %s | %s | %s | %s |" % (name, e3, e5, first8 or "-", first3 or "-", hit or "-"))
    if g <= 0 and (e3 != -1 or e5 != -1):
        ok = False; print("  !! 站定/走远不应给出 eta")
    if 6 <= g <= 8 and (e3 is None or e3 < 0):
        ok = False; print("  !! 慢走近应给出 eta")
    if g >= 15 and (e3 is None or e3 < 0 or e3 > 8):
        ok = False; print("  !! 快走近应给出小 eta")
print("\n自检:", "PASS" if ok else "FAIL")
