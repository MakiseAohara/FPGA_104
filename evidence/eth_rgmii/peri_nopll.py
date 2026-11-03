import re, pathlib, shutil
p = pathlib.Path(r'D:\eth_build\m17_ge\ti60f225_oob.peri.xml')
bak = p.with_suffix('.xml.bak_full')
if not bak.exists():
    shutil.copy2(p, bak)
t = p.read_text(encoding='utf-8')
# 去掉 PLL 块，保留引脚
t2 = re.sub(r' *<efxpt:pll name="ge_0_gclk_pll".*?</efxpt:pll>\n', '', t, flags=re.S)
p.write_text(t2, encoding='utf-8')
print('PLL removed, size', len(t2))
