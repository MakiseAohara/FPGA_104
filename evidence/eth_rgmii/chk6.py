import re
from pathlib import Path
def files(p):
    t = Path(p).read_text(encoding="utf-8", errors="replace")
    return [m.group(1) for m in re.finditer(r'design_file name="([^"]+)"', t)]
a = files(r"D:\eth_build\m17_ge\ti60f225_oob.xml")
b = files(r"D:\v30_build\m17\ti60f225_oob.xml")
print("GE 工程源码数", len(a), " 主工程源码数", len(b))
sa, sb = set(a), set(b)
print("\n只在 GE 工程:", sorted(sa - sb)[:20])
print("\n只在主工程:", sorted(sb - sa)[:20])
tops = re.findall(r'top_module[^>]*>([^<]+)<', Path(r"D:\eth_build\m17_ge\ti60f225_oob.xml").read_text(encoding="utf-8", errors="replace"))
tops2 = re.findall(r'top_module[^>]*>([^<]+)<', Path(r"D:\v30_build\m17\ti60f225_oob.xml").read_text(encoding="utf-8", errors="replace"))
print("\nGE top:", tops[:3], " 主工程 top:", tops2[:3])
