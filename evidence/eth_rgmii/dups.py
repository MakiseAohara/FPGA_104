import re, pathlib, collections
p = pathlib.Path(r'D:\eth_build\m17_ge\ti60f225_oob.xml')
t = p.read_text(encoding='utf-8', errors='replace')
names = re.findall(r'<efx:design_file name="([^"]+)"', t)
c = collections.Counter(names)
print('total', len(names), 'dups', [(k, v) for k, v in c.items() if v > 1])
print('ge entries', sum(1 for n in names if n.startswith('rtl/ge/')))
import xml.etree.ElementTree as ET
try:
    ET.fromstring(t.encode()); print('xml ok')
except Exception as e:
    print('xml bad', e)
