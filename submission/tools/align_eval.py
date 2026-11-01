"""align_eval.py - 按画面内容对齐时间轴再评估（避免"阶段标签 vs 实际操作"错位）"""
import re, sys
from collections import Counter
from pathlib import Path

log = Path(sys.argv[1])
frames = []   # dict(step, p, conf, nd, raw, pre, alarm)
step = None
cur = {}
for line in log.open(encoding="utf-8", errors="replace"):
    m = re.match(r"^(READY|A0|A\d+|B1|B2|B3|C1|D|E)\s+(\d+\.\d+)\s*(.*)", line)
    if m:
        step, rest = m.group(1), m.group(3)
    else:
        if step is None:
            continue
        rest = line
    mm = re.search(r"MMT_AI f=\d+ p=(-?\d+)", rest)
    if mm: cur["p"] = int(mm.group(1))
    mm = re.search(r"MMT_MOT f=(\d+) nd=(\d+) nt=(\d+) conf=(\d+) area=(\d+) raw=(\d+)", rest)
    if mm:
        cur.update(f=int(mm.group(1)), nd=int(mm.group(2)), conf=int(mm.group(4)), raw=int(mm.group(6)))
        frames.append(dict(step=step, **cur))
        cur = dict()
    if "MMT_PREWARN" in rest and frames:
        frames[-1]["pre"] = True
    if "MMT_ALARM start" in rest and frames:
        frames[-1]["alarm"] = True

def summarize(name, sel):
    if not sel:
        return
    present = [f for f in sel if (f.get("p") or -128) >= 50]
    absent = [f for f in sel if (f.get("p") or -128) < 0]
    shake = [f for f in sel if (f.get("raw") or 0) >= 8500]
    print("%-6s 帧 %4d | 有人帧(p>=50) %4d | 无人帧(p<0) %4d | 整幅前景帧 %3d" % (
        name, len(sel), len(present), len(absent), len(shake)))
    print("       有人帧中 有确认航迹 %4d 帧；无人帧中 有确认航迹 %4d 帧；无人帧中 报警 %d 次 预警 %d 次" % (
        sum(1 for f in present if f.get("conf", 0) > 0),
        sum(1 for f in absent if f.get("conf", 0) > 0),
        sum(1 for f in absent if f.get("alarm")),
        sum(1 for f in absent if f.get("pre"))))
    if shake:
        print("       整幅前景帧中 有确认航迹 %d 帧、预警 %d 次" % (
            sum(1 for f in shake if f.get("conf", 0) > 0), sum(1 for f in shake if f.get("pre"))))

by = {}
for f in frames:
    by.setdefault(f["step"], []).append(f)
order = ["READY", "A0"] + ["A%d" % i for i in range(1, 21)] + ["B1", "B2", "B3", "C1", "D", "E"]
for s in order:
    if s in by:
        summarize(s, by[s])
print()
alls = frames
summarize("ALL", alls)