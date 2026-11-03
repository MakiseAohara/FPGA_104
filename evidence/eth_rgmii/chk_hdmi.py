import re
from pathlib import Path
p = Path(r"out\hdcp_check\serial.log")
lines = p.read_text(encoding="utf-8", errors="replace").splitlines()
print("lines", len(lines))
mot = [(int(m.group(1)), int(m.group(2))) for m in (re.search(r"MMT_MOT f=(\d+) nd=(\d+)", l) for l in lines) if m]
print("MOT frames:", mot[0][0] if mot else None, "->", mot[-1][0] if mot else None, " count", len(mot))
lp = [l for l in lines if "MMT_LP " in l][-2:]
osd = [l for l in lines if "MMT_OSD" in l][-2:]
print("\n".join(l[:200] for l in lp))
print("--OSD--")
print("\n".join(l[:200] for l in osd))
ls = [l for l in lines if "MMT_LP " in l]
print("--LP 行数", len(ls))
for l in ls[:2]: print(l[:180])
import collections
c = collections.Counter(re.search(r"MMT_[A-Z_]+", l).group(0) for l in lines if re.search(r"MMT_[A-Z_]+", l))
print("tag counts", dict(c))
