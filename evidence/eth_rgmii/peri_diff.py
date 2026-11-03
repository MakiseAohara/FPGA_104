import re, pathlib
def top_sections(p):
    t = pathlib.Path(p).read_text(encoding='utf-8', errors='replace')
    return re.findall(r'<(efxpt:[a-z_0-9]+)[ >]', t)
a = set(top_sections(r'D:\v30_build\m17\ti60f225_oob.peri.xml'))
b = set(top_sections(r'D:\eth_build\ge\led_test.peri.xml'))
print('only in ours :', sorted(a - b))
print('only in demo :', sorted(b - a))
print('common count :', len(a & b))
