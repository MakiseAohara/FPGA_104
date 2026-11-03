#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""pred_eval.py - 用真实航迹数据评估"下一帧位置"预测器（离线，不需要板子）。
数据来源：串口日志里的 MMT_TRK 行（c=cx,cy v16=vx,vy）。
对比：静止 / 恒速(v16 原样) / 恒速×0.5 阻尼 / 恒速×0.75 / 一阶 alpha-beta(0.5,0.25) / 最近两帧差分。
输出：中位误差、p90、改善百分比，以及按"速度档"分组的误差（慢/中/快）。
"""
import re, sys, statistics as st
from pathlib import Path

TRK = re.compile(r"MMT_TRK f=(\d+) id=(\d+) c=(-?\d+),(-?\d+) b=(-?\d+),(-?\d+),(-?\d+),(-?\d+) "
                 r"v16=(-?\d+),(-?\d+) dir=(\d+) hit=(\d+) miss=(\d+) conf=(\d+) pred=(-?\d+),(-?\d+) eta=(-?\d+)")

def load(paths):
    tracks = {}
    for p in paths:
        for line in Path(p).read_text(encoding="utf-8", errors="replace").splitlines():
            m = TRK.search(line)
            if not m: continue
            g = [int(x) for x in m.groups()]
            key = (Path(p).parent.name, g[1])
            tracks.setdefault(key, []).append(dict(f=g[0], cx=g[2], cy=g[3], vx=g[8], vy=g[9]))
    out = []
    for k, s in tracks.items():
        s.sort(key=lambda r: r["f"])
        out.append(s)
    return out

def pct(v, q):
    if not v: return None
    v = sorted(v); i = min(len(v)-1, max(0, int(round(q*(len(v)-1))))); return v[i]

def evaluate(tracks):
    res = {}
    def add(name, err, speed):
        res.setdefault(name, {"all": [], "slow": [], "mid": [], "fast": []})
        res[name]["all"].append(err)
        bucket = "slow" if speed < 3 else ("mid" if speed < 8 else "fast")
        res[name][bucket].append(err)
    for s in tracks:
        byf = {r["f"]: r for r in s}
        for i, r in enumerate(s):
            nxt = byf.get(r["f"] + 1)
            if not nxt: continue
            dx, dy = nxt["cx"] - r["cx"], nxt["cy"] - r["cy"]
            speed = (dx*dx + dy*dy) ** 0.5
            def e(px, py): return ((px - nxt["cx"])**2 + (py - nxt["cy"])**2) ** 0.5
            add("空间静止", e(r["cx"], r["cy"]), speed)
            add("恒速 v16(1/16 px)", e(r["cx"] + r["vx"]//16, r["cy"] + r["vy"]//16), speed)
            add("恒速 x0.5 阻尼", e(r["cx"] + r["vx"]//32, r["cy"] + r["vy"]//32), speed)
            add("恒速 x0.75", e(r["cx"] + r["vx"]*3//64, r["cy"] + r["vy"]*3//64), speed)
            if i >= 2:
                p = s[i-1]
                lx, ly = r["cx"] - p["cx"], r["cy"] - p["cy"]
                add("最近两帧差分", e(r["cx"] + lx, r["cy"] + ly), speed)
                ax = r["cx"] + (lx + (r["vx"]/16.0)) / 2
                ay = r["cy"] + (ly + (r["vy"]/16.0)) / 2
                add("差分+速度平均", e(ax, ay), speed)
    return res

def main():
    paths = [a for a in sys.argv[1:] if not a.startswith("--")]
    tracks = load(paths)
    tracks = [t for t in tracks if len(t) >= 3]
    print("航迹数(>=3帧) %d, 样本 %d" % (len(tracks), sum(len(t)-1 for t in tracks)))
    r = evaluate(tracks)
    base = pct(r["空间静止"]["all"], .5) or 1
    print("\n| 预测器 | 中位误差 px | p90 px | 慢(<3px) | 中(3-8px) | 快(>8px) | 相对静止 |")
    print("|---|---|---|---|---|---|---|")
    for name, d in sorted(r.items(), key=lambda kv: pct(kv[1]["all"], .5) or 1e9):
        med = pct(d["all"], .5)
        print("| %s | %.2f | %.2f | %.2f | %.2f | %.2f | %+.1f%% |" % (
            name, med, pct(d["all"], .9) or 0,
            pct(d["slow"], .5) or 0, pct(d["mid"], .5) or 0, pct(d["fast"], .5) or 0,
            (med / base - 1) * 100))

main()
