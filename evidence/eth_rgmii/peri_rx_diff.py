import re, pathlib
demo = pathlib.Path(r'D:\eth_build\ge\led_test.peri.xml').read_text(encoding='utf-8', errors='replace')
mine = pathlib.Path(r'D:\eth_build\m17_ge\ti60f225_oob.peri.xml').read_text(encoding='utf-8', errors='replace')
def block(txt, name):
    m = re.search(r'<efxpt:comp_gpio name="%s".*?</efxpt:comp_gpio>' % re.escape(name), txt, re.S)
    return m.group(0) if m else None
for n in ('rxc', 'rx_dv', 'rxd[0]'):
    a, b = block(demo, n), block(mine, n)
    print('==== %s: demo %s / mine %s' % (n, 'FOUND' if a else 'MISSING', 'FOUND' if b else 'MISSING'))
    if a and b and a.strip() != b.strip():
        print('--- demo ---'); print(a.strip()[:400])
        print('--- mine ---'); print(b.strip()[:400])
    elif a and b:
        print('identical')
for txt, name in ((demo, 'demo'), (mine, 'mine')):
    m = re.search(r'<efxpt:bus name="rxd"[^>]*>', txt)
    print(name, 'bus rxd:', m.group(0) if m else 'MISSING')
