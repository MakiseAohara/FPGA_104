import xml.etree.ElementTree as ET, pathlib
p = pathlib.Path(r'D:\eth_build\m17_ge\ti60f225_oob.xml')
try:
    ET.parse(p); print('xml OK')
except Exception as e:
    print('xml ERROR:', e)
    data = p.read_text(encoding='utf-8', errors='replace')
    print('len', len(data))
    import re
    i = data.find('rtl/ge/')
    print(repr(data[i-300:i+200]))
