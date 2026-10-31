"""pred_eval.py - 行为预测(4)的量化评估：下一帧/2帧预测误差、ROI 预警、误预警"""
import argparse, re, statistics as st
from collections import defaultdict

TRK = re.compile(r"MMT_TRK f=(\d+) id=(\d+) c=(-?\d+),(-?\d+) b=(-?\d+),(-?\d+),(-?\d+),(-?\d+) v16=(-?\d+),(-?\d+) dir=(\d+) hit=(\d+) miss=(\d+) conf=(\d+) pred=(-?\d+),(-?\d+)")
PRE = re.compile(r"MMT_PREWARN f=(\d+) id=(\d+) eta=(-?\d+)")
DEC = re.compile(r"MMT_DEC t=(\d+) f=(\d+)")
ROI = (16, 16, 80, 80)

ap = argparse.ArgumentParser()
ap.add_argument("log")
ap.add_argument("--fps", type=float, default=2.0)
a = ap.parse_args()

trk = defaultdict(dict)      # id -> frame -> dict
pre = []
time_of = {}
for line in open(a.log, encoding="utf-8", errors="replace"):
    m = TRK.search(line)
    if m:
        g = m.groups()
        f, tid = int(g[0]), int(g[1])
        trk[tid][f] = dict(cx=int(g[2]), cy=int(g[3]), vx=int(g[8]) / 16.0, vy=int(g[9]) / 16.0,
                           px=int(g[14]), py=int(g[15]), conf=int(g[13]))
        continue
    m = PRE.search(line)
    if m:
        pre.append((int(m.group(1)), int(m.group(2))))
        continue
    m = DEC.search(line)
    if m:
        time_of[int(m.group(2))] = int(m.group(1)) / 1000.0

err1, err2 = [], []
for tid, frames in trk.items():
    fs = sorted(frames)
    for i, f in enumerate(fs):
        r = frames[f]
        if not r["conf"]:
            continue
        if f + 1 in frames:
            n1 = frames[f + 1]
            d = ((r["cx"] + r["vx"] - n1["cx"]) ** 2 + (r["cy"] + r["vy"] - n1["cy"]) ** 2) ** 0.5
            err1.append(d)
        if f + 2 in frames:
            n2 = frames[f + 2]
            d = ((r["px"] - n2["cx"]) ** 2 + (r["py"] - n2["cy"]) ** 2) ** 0.5
            err2.append(d)

def q(v, p):
    return sorted(v)[min(len(v) - 1, int(len(v) * p))] if v else None

# ROI 进入事件 + 预警匹配
entries = []
for tid, frames in trk.items():
    fs = sorted(frames)
    inside_before = None
    for f in fs:
        r = frames[f]
        inside = ROI[0] <= r["cx"] <= ROI[2] and ROI[1] <= r["cy"] <= ROI[3]
        if inside and inside_before is False:
            entries.append((f, tid))
        inside_before = inside

lead_ms, warned, missed = [], 0, 0
for f, tid in entries:
    cands = [(pf, pid) for (pf, pid) in pre if pid == tid and 0 <= f - pf <= int(3 * a.fps)]
    if cands:
        warned += 1
        pf = max(cands)[0]
        lead_ms.append((f - pf) / a.fps * 1000.0)
    else:
        missed += 1

bad = 0
for pf, pid in pre:
    if not any(pid == tid and 0 <= f - pf <= int(3 * a.fps) for f, tid in entries):
        bad += 1

print("日志:", a.log)
print("下一帧预测误差 中位/p90: %s / %s px (n=%d)" % (
    round(st.median(err1), 2) if err1 else "-", round(q(err1, 0.9), 2) if err1 else "-", len(err1)))
print("2 帧前视误差 中位/p90: %s / %s px (n=%d)" % (
    round(st.median(err2), 2) if err2 else "-", round(q(err2, 0.9), 2) if err2 else "-", len(err2)))
print("ROI 进入事件: %d，其中预警命中 %d (漏 %d)" % (len(entries), warned, missed))
print("预警提前量 中位/最小: %s / %s ms (n=%d)" % (
    round(st.median(lead_ms)) if lead_ms else "-", round(min(lead_ms)) if lead_ms else "-", len(lead_ms)))
print("误预警: %d 次 (PREWARN 后 3 s 内无目标进入 ROI)" % bad)