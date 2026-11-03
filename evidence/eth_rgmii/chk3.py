import re
from pathlib import Path
lines = Path(r"out\hdcp_check\serial.log").read_text(encoding="utf-8", errors="replace").splitlines()
img = [l for l in lines if l.startswith("MMT_IMG") or " MMT_IMG " in l]
print("MMT_IMG 行数", len(img))
if img:
    print("首行:", img[0][:120])
    print("末行:", img[-1][:120])
    # 抓前 8 行作为一张图的样本
    rows = img[:8]
    for r in rows[:4]:
        print(len(r), r[:100])
    # 判断是否有多个 dump（行号回到 00）
    idx = [int(m.group(1)) for l in img if (m := re.match(r".*MMT_IMG (\d+) ", l))]
    print("行号序列前 20:", idx[:20])
    print("出现的 dump 次数(行号 0 的个数):", idx.count(0))
