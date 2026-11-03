import re
from pathlib import Path
p = Path(r"D:\eth_build\m17_ge\ti60f225_oob.peri.xml")
t = p.read_text(encoding="utf-8", errors="replace")
names = re.findall(r'comp_gpio name="([^"]+)"', t)
print("comp_gpio 个数", len(names))
print(names[:40])
