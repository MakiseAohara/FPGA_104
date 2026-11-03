#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""MOT / 预测离线分析：直接解析串口日志，产出对比指标。
用法: py -3 tools/mot_analyze.py out/ev3/serial.log [more.log ...] [--md out.md]
指标: 检测框尺寸分布、ID 总数、ID 存活时间中位、nt/obs 分布、预测误差(像素)。
"""
import re, sys, statistics as st
from pathlib import Path

MOT = re.compile(r"MMT_MOT f=(\d+) nd=(\d+) nt=(\d+) conf=(\d+) area=(\d+) raw=(\d+) pre=(-?\d+) pre_eta=(-?\d+) obs=(-?\d+)")
TRK = re.compile(r"MMT_TRK f=(\d+) id=(\d+) c=(-?\d+),(-?\d+) b=(-?\d+),(-?\d+),(-?\d+),(-?\d+) "
                 r"v16=(-?\d+),(-?\d+) dir=(\d+) hit=(\d+) miss=(\d+) conf=(\d+) pred=(-?\d+),(-?\d+) eta=(-?\d+)")

def pct(v, q):
    if not v: return 0
    v = sorted(v); i = min(len(v) - 1, max(0, int(round(q * (len(v) - 1)))))
    return v[i]

def analyze(path):
    mot, trk = [], {}
    for line in Path(path).read_text(encoding="utf-8", errors="replace").splitlines():
        m = MOT.search(line)
        if m:
            g = [int(x) for x in m.groups()]
            mot.append(dict(f=g[0], nd=g[1], nt=g[2], conf=g[3], area=g[4],
                            raw=g[5], pre=g[6], pre_eta=g[7], obs=g[8])); continue
        t = TRK.search(line)
        if t:
            g = [int(x) for x in t.groups()]
            trk.setdefault(g[1], []).append(dict(f=g[0], cx=g[2], cy=g[3],
                x0=g[4], y0=g[5], x1=g[6], y1=g[7], vx=g[8], vy=g[9], dir=g[10],
                hit=g[11], miss=g[12], conf=g[13], px=g[14], py=g[15], eta=g[16]))
    # ---- 框尺寸 ----
    ws, hs, ars = [], [], []
    for tid, s in trk.items():
        x0, y0, x1, y1 = s[len(s)//2]["x0"], s[len(s)//2]["y0"], s[len(s)//2]["x1"], s[len(s)//2]["y1"]
        w, h = x1 - x0 + 1, y1 - y0 + 1
        if w > 0 and h > 0: ws.append(w); hs.append(h); ars.append(w * h)
    # ---- ID 存活（帧）----
    life = [s[-1]["f"] - s[0]["f"] + 1 for s in trk.values()]
    # ---- 预测误差 ----
    perr, serr, n_pred = [], [], 0
    for tid, s in trk.items():
        byf = {r["f"]: r for r in s}
        for r in s:
            nxt = byf.get(r["f"] + 1)
            if not nxt: continue
            if r["px"] or r["py"]:
                n_pred += 1
                perr.append(((r["px"] - nxt["cx"]) ** 2 + (r["py"] - nxt["cy"]) ** 2) ** 0.5)
            serr.append(((r["cx"] - nxt["cx"]) ** 2 + (r["cy"] - nxt["cy"]) ** 2) ** 0.5)
    ntvals = [r["nt"] for r in mot]; obsvals = [r["obs"] for r in mot]
    ndvals = [r["nd"] for r in mot]
    return dict(path=str(path), frames=len(mot), ids=len(trk),
        box_w=[pct(ws, .5), pct(ws, .9), max(ws) if ws else 0],
        box_h=[pct(hs, .5), pct(hs, .9), max(hs) if hs else 0],
        box_a=[pct(ars, .5), pct(ars, .9), max(ars) if ars else 0],
        life_med=pct(life, .5), life_p90=pct(life, .9), life_max=max(life) if life else 0,
        nt_med=pct(ntvals, .5), nt_max=max(ntvals) if ntvals else 0,
        nt_hist={k: ntvals.count(k) for k in sorted(set(ntvals))},
        obs_med=pct(obsvals, .5), obs_max=max(obsvals) if obsvals else 0,
        obs_hist={k: obsvals.count(k) for k in sorted(set(obsvals))},
        nd_med=pct(ndvals, .5),
        pred_n=n_pred,
        pred_err_med=round(pct(perr, .5), 2) if perr else None,
        pred_err_p90=round(pct(perr, .9), 2) if perr else None,
        static_err_med=round(pct(serr, .5), 2) if serr else None,
        static_err_p90=round(pct(serr, .9), 2) if serr else None)

def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    md = None
    if "--md" in sys.argv: md = Path(sys.argv[sys.argv.index("--md") + 1])
    res = [analyze(a) for a in args]
    out = []
    out.append("| 日志 | 帧数 | 中位框 w×h | p90 框 w×h | 中位面积 | ID 数 | 中位存活 | p90 存活 | nt 中位/最大 | obs 中位/最大 | 预测误差中位 | 静止误差中位 |")
    out.append("|---|---|---|---|---|---|---|---|---|---|---|---|")
    for r in res:
        out.append("| %s | %d | %d×%d | %d×%d | %d | %d | %d 帧 | %d 帧 | %d/%d | %d/%d | %s | %s |" % (
            Path(r["path"]).parent.name, r["frames"], r["box_w"][0], r["box_h"][0],
            r["box_w"][1], r["box_h"][1], r["box_a"][0], r["ids"], r["life_med"], r["life_p90"],
            r["nt_med"], r["nt_max"], r["obs_med"], r["obs_max"],
            r["pred_err_med"] if r["pred_err_med"] is not None else "-", r["static_err_med"]))
    txt = "\n".join(out)
    print(txt)
    for r in res:
        print("\n## %s\nnt 分布 %s\nobs 分布 %s" % (r["path"], r["nt_hist"], r["obs_hist"]))
    if md:
        md.write_text(txt + "\n", encoding="utf-8"); print("\nWROTE", md)

main()
