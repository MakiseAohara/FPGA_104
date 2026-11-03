import re
from pathlib import Path
lines = Path(r"out\hdcp_check2\serial.log").read_text(encoding="utf-8", errors="replace").splitlines()
dumps, cur = [], []
for l in lines:
    m = re.search(r"MMT_IMG (\d+) ([0-9a-f]+)", l)
    if m:
        i = int(m.group(1))
        if i == 0 and cur:
            dumps.append(cur); cur = []
        cur.append(m.group(2))
    elif "MMT_IMGSTAT" in l:
        print(l[:80])
if cur: dumps.append(cur)
print("dump 数:", len(dumps), "每张行数:", [len(d) for d in dumps])
for k, d in enumerate(dumps[:2]):
    data = "".join(d)
    b = bytes.fromhex(data[: len(data)//2*2])
    print("dump%d bytes=%d mean=%.1f min=%d max=%d" % (k, len(b), sum(b)/len(b), min(b), max(b)))
if len(dumps) >= 2:
    a = "".join(dumps[0]); c = "".join(dumps[1])
    n = min(len(a), len(c))
    diff = sum(1 for i in range(0, n, 2) if a[i:i+2] != c[i:i+2])
    print("两张图不同字节数 %d / %d (%.1f%%)" % (diff, n//2, 100.0*diff/(n//2)))
