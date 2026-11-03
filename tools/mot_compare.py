#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""mot_compare.py - 两版固件同条件对比（单人就能做）：基线 vs 新版

用法: py -3 tools/mot_compare.py out/mot_A/serial.log out/mot_B/serial.log [--name-a 基线] [--name-b 新版]
指标口径（都从 MMT_MOT/MMT_TRK 算）:
  · ID 总数        越少越好（一个人不该反复换号）
  · ID 存活中位    越长约好
  · nt 中位        本帧在场航迹数（人站着时应该稳定=1）
  · nt 抖动(std)   越小越好
  · obs 中位       支撑航迹数（人数估计）
  · 框面积中位     用来确认两版看到的是同一批目标（差异大说明条件不同，数据不可比）
"""
import argparse, re, statistics as st
from pathlib import Path

MOT = re.compile(r"MMT_MOT f=(\d+) nd=(\d+) nt=(\d+) conf=(\d+) area=(\d+) raw=(\d+) pre=(-?\d+) pre_eta=(-?\d+) obs=(-?\d+)")
TRK = re.compile(r"MMT_TRK f=(\d+) id=(\d+) c=(-?\d+),(-?\d+) b=(-?\d+),(-?\d+),(-?\d+),(-?\d+)")

def load(path):
    mot, trk = [], {}
    for line in Path(path).read_text(encoding="utf-8", errors="replace").splitlines():
        m = MOT.search(line)
        if m:
            g = [int(x) for x in m.groups()]
            mot.append(dict(f=g[0], nd=g[1], nt=g[2], area=g[4], pre=g[6], eta=g[7], obs=g[8])); continue
        m = TRK.search(line)
        if m:
            g = [int(x) for x in m.groups()]
            trk.setdefault(g[1], []).append(dict(f=g[0], a=(g[6]-g[4]+1)*(g[7]-g[5]+1)))
    return mot, trk

def metrics(path):
    mot, trk = load(path)
    life = [s[-1]["f"] - s[0]["f"] + 1 for s in trk.values()]
    nt = [r["nt"] for r in mot]; ob = [r["obs"] for r in mot]
    return dict(frames=len(mot), ids=len(trk),
                life_med=st.median(life) if life else 0,
                life_p90=(sorted(life)[int(0.9*(len(life)-1))] if life else 0),
                nt_med=st.median(nt) if nt else 0,
                nt_std=round(st.pstdev(nt), 2) if len(nt) > 1 else 0,
                obs_med=st.median(ob) if ob else 0,
                area_med=st.median([r["area"] for r in mot if r["area"] > 0]) if any(r["area"] > 0 for r in mot) else 0)

ap = argparse.ArgumentParser()
ap.add_argument("a"); ap.add_argument("b")
ap.add_argument("--name-a", default="A(基线)"); ap.add_argument("--name-b", default="B(新版)")
x = ap.parse_args()
A, B = metrics(x.a), metrics(x.b)

print("| 指标 | %s | %s | 差异 | 谁更好 |" % (x.name_a, x.name_b))
print("|---|---|---|---|---|")
def row(name, ka, fmt="%.1f", lower_better=True, note=""):
    va, vb = A[ka], B[ka]
    d = vb - va
    if va == 0 and vb == 0:
        who = "—"
    elif d == 0:
        who = "持平"
    else:
        better_b = (d < 0) if lower_better else (d > 0)
        who = x.name_b if better_b else x.name_a
        if ka == "area_med":
            who = "条件不同" if abs(d) > 0.25 * max(1, va) else "一致"
    print("| %s | %s | %s | %+g | %s |" % (name, fmt % va, fmt % vb, d, who))

row("ID 总数", "ids", "%.0f", True)
row("ID 存活中位(帧)", "life_med", "%.0f", False)
row("ID 存活 p90(帧)", "life_p90", "%.0f", False)
row("nt 中位", "nt_med", "%.2f", True)
row("nt 抖动(std)", "nt_std", "%.2f", True)
row("obs 中位", "obs_med", "%.2f", True)
print("| 框面积中位 | %.0f | %.0f | %+g | %s |" % (A["area_med"], B["area_med"],
      B["area_med"] - A["area_med"],
      "一致" if abs(B["area_med"] - A["area_med"]) <= 0.25 * max(1, A["area_med"]) else "条件不同，数据不可比"))

print("\n判定建议（三项都站在同一侧才算「新版更好」）:")
votes = 0
for ka, lower in (("ids", True), ("life_med", False), ("nt_std", True)):
    va, vb = A[ka], B[ka]
    if va == vb or (va == 0 and vb == 0):
        continue
    votes += 1 if ((vb < va) if lower else (vb > va)) else -1
print("  票数 %+d（正=新版更好，负=基线更好）" % votes)
print("  结论:", "新版更好" if votes >= 2 else ("基线更好" if votes <= -2 else "两版无显著差别"))
print("\n提醒：两版必须是同一场景/同一动作（先跑 A 再跑 B，中间不挪相机、不换灯）。")
