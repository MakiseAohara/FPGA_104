
import re
from pathlib import Path
d = Path(r'C:\Users\Makise Aohara\Downloads\Ti60F225A_V4_SCH.pdf').read_bytes()
print('Differences 出现次数:', d.count(b'/Differences'))
blocks = re.findall(rb"/Differences\s*\[(.*?)\]", d, re.S)
print('Differences 块:', len(blocks))
total = 0
sample = None
for b in blocks[:6]:
    toks = re.findall(rb"/([A-Za-z0-9_.]+)|(-?\d+)", b)
    names = [t[0].decode() for t in toks if t[0]]
    total += len(names)
    if sample is None and names: sample = names[:12]
print('总计字形名:', total)
print('样例:', sample)
