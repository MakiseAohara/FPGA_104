#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""pred_accept.py - 预测功能验收（单人可做，只用串口日志）

被验收的东西（行为预测 = 提前量，不是算命）：
  ① 预警必须"提前"：先 MMT_PREWARN，再过一会儿才 MMT_ALARM start（lead_ms > 0）；
  ② pre_eta 必须随接近而变小（6→5→4…），不是常数；
  ③ 不许多报：空场（nd=0）和站定（nd>0 但不再靠近）时不发预警；
  ④ 预警后若最终没报警，要能自己撤销（不能挂死）。

用法:
  py -3 tools/pred_accept.py out/pred_A/serial.log [--json out/pred_A/accept.json]
判定阈值（PASS）:
  · 有效接近 >= 3 次，且每次 lead_ms > 0
  · lead_ms 中位 >= 400 ms（MOT 2 fps，一帧约 500 ms）
  · 空场误报 = 0，且站定误报 = 0
  · pre_eta 在 >= 70% 的预警片段里是下降的
"""
import argparse, json, re, statistics as st
from pathlib import Path

ap = argparse.ArgumentParser()
ap.add_argument("log")
ap.add_argument("--json", type=Path, default=None)
ap.add_argument("--lead-ms-min", type=int, default=400)
ap.add_argument("--min-approaches", type=int, default=3)
a = ap.parse_args()

MOT = re.compile(r"MMT_MOT f=(\d+) nd=(\d+) nt=(\d+) conf=(\d+) area=(\d+) raw=(\d+) pre=(-?\d+) pre_eta=(-?\d+) obs=(-?\d+)")
PRE = re.compile(r"MMT_PREWARN f=(\d+) id=(\d+) eta=(-?\d+) ms=(\d+)")
LEAD = re.compile(r"MMT_PREDLEAD f=(\d+) lead_ms=(\d+) id=(\d+) eta=(-?\d+)")
ALM = re.compile(r"MMT_ALARM (start|end) ms=(\d+) f=(\d+)")

rows, prewarns, leads, alarms = [], [], [], []
for line in Path(a.log).read_text(encoding="utf-8", errors="replace").splitlines():
    m = MOT.search(line)
    if m:
        g = [int(x) for x in m.groups()]
        rows.append(dict(f=g[0], nd=g[1], nt=g[2], area=g[4], pre=g[6], eta=g[7])); continue
    m = PRE.search(line)
    if m: prewarns.append(dict(f=int(m.group(1)), id=int(m.group(2)), eta=int(m.group(3)), ms=int(m.group(4)))); continue
    m = LEAD.search(line)
    if m: leads.append(dict(f=int(m.group(1)), lead_ms=int(m.group(2)), id=int(m.group(3)), eta=int(m.group(4)))); continue
    m = ALM.search(line)
    if m: alarms.append(dict(kind=m.group(1), ms=int(m.group(2)), f=int(m.group(3))))

# ---- 预警片段：连续 pre=1 的帧 ----
episodes = []
cur = []
for r in rows:
    if r["pre"] == 1:
        cur.append(r)
    elif cur:
        episodes.append(cur); cur = []
if cur: episodes.append(cur)

def after_alarm(f, ms):
    for al in alarms:
        if al["kind"] == "start" and al["ms"] >= ms:
            return al
    return None

epi = []
for e in episodes:
    alarm = after_alarm(e[0]["f"], prewarns[0]["ms"] if prewarns else 0)
    etas = [r["eta"] for r in e if r["eta"] >= 0]
    desc = None
    if len(etas) >= 2:
        desc = etas[-1] < etas[0]
    epi.append(dict(f0=e[0]["f"], f1=e[-1]["f"], n=len(e), eta0=etas[0] if etas else None,
                    eta1=etas[-1] if etas else None, decreasing=desc,
                    alarm=alarm is not None))

# ---- 空场 / 站定 误报 ----
empty_frames = [r for r in rows if r["nd"] == 0]
empty_pre = [r for r in empty_frames if r["pre"] == 1]

# 站定误报：连续 3 帧 nd 相同且面积完全不变（=人没动），却仍在预警
static_frames = []
for i in range(1, len(rows) - 1):
    cur, prv, nxt = rows[i], rows[i-1], rows[i+1]
    if cur["pre"] != 1 or cur["nd"] == 0:
        continue
    if prv["nd"] == cur["nd"] == nxt["nd"] and prv["area"] == cur["area"] == nxt["area"]:
        static_frames.append(cur["f"])
static_pre = len(static_frames)

lead_ok = [l for l in leads if l["lead_ms"] > 0]
rep = dict(
    frames=len(rows),
    prewarn_episodes=len(episodes),
    prewarn_calls=len(prewarns),
    predlead_records=len(leads),
    lead_ms=[l["lead_ms"] for l in leads],
    lead_ms_median=st.median([l["lead_ms"] for l in leads]) if leads else None,
    approaches_with_alarm=sum(1 for e in epi if e["alarm"]),
    eta_decreasing_ratio=round(sum(1 for e in epi if e["decreasing"]) / len(epi), 2) if epi else None,
    empty_frames=len(empty_frames),
    false_prewarn_empty=len(empty_pre),
    false_prewarn_static=static_pre,
    false_prewarn_static_frames=static_frames[:10],
    episodes=epi[:12],
)
checks = [
    ("有效接近次数 >= %d" % a.min_approaches, len(lead_ok) >= a.min_approaches),
    ("每次 lead_ms > 0", bool(leads) and len(lead_ok) == len(leads)),
    ("lead_ms 中位 >= %d ms" % a.lead_ms_min, (rep["lead_ms_median"] or 0) >= a.lead_ms_min),
    ("空场无误报", len(empty_pre) == 0),
    ("站定无误报", static_pre == 0),
    ("pre_eta 下降片段 >= 70%", (rep["eta_decreasing_ratio"] or 0) >= 0.7),
]
verdict = "PASS" if all(ok for _, ok in checks) else ("数据不足" if not prewarns else "FAIL")

print(json.dumps(rep, ensure_ascii=False, indent=1))
print("\n验收项:")
for name, ok in checks:
    print("  [%s] %s" % ("PASS" if ok else "FAIL", name))
print("\n总判定:", verdict)
if a.json:
    a.json.parent.mkdir(parents=True, exist_ok=True)
    a.json.write_text(json.dumps(dict(rep, checks=dict(checks), verdict=verdict), ensure_ascii=False, indent=1), encoding="utf-8")
    print("写入", a.json)
