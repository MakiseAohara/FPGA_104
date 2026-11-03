import re
from pathlib import Path
lines = Path(r"out\m17_v292\serial.log").read_text(encoding="utf-8", errors="replace").splitlines()
fps = [int(m.group(1)) for l in lines if (m := re.search(r"camfps=(\d+)", l))]
print("camfps 样本", fps[:20])
nz = [f for f in fps if f > 0]
print("非零 camfps 中位/最小/最大: ", sorted(nz)[len(nz)//2] if nz else None, min(nz) if nz else None, max(nz) if nz else None)
lp = [l for l in lines if "MMT_LP " in l]
print("lowpwr=1 的行数:", sum(1 for l in lp if "lowpwr=1" in l), "/", len(lp))
sht = [int(m.group(1)) for l in lines if (m := re.search(r"sht_upd=(\d+)", l))]
print("sht_upd 递增:", sht[0] if sht else None, "->", sht[-1] if sht else None)
inf = [int(m.group(1)) for l in lines if (m := re.search(r"infer=(\d+)", l))]
print("infer 递增:", inf[0] if inf else None, "->", inf[-1] if inf else None)
