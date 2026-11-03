# -*- coding: utf-8 -*-
"""patch_prj_bytes.py - 在原始工程 XML 上做字节级修改（保留 CRLF），并修 DC_FIFO 的 SV 兼容问题。"""
import re, pathlib
ROOT = pathlib.Path(r'D:\eth_build\m17_ge')
prj = ROOT / 'ti60f225_oob.xml'
data = prj.read_bytes()
# 1) 删掉原始里那 12 个已经不用的 rtl/ge 条目
data = re.sub(rb'[ \t]*<efx:design_file name="rtl/ge/[^"]+"[^>]*/>\r?\n', b'', data)
# 2) 加入保留的 25 个
keep = sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / 'rtl' / 'ge').rglob('*.v'))
ins = b''.join(b'        <efx:design_file name="%s" version="default" library="default"/>\r\n'
               % k.encode() for k in keep)
anchor = b'    </efx:design_info>'
assert anchor in data
data = data.replace(anchor, ins + anchor, 1)
prj.write_bytes(data)
print('xml patched, ge files:', len(keep))

# 3) DC_FIFO: body parameter -> localparam（SV 模式下会报错）
for p in (ROOT / 'rtl' / 'ge').rglob('*.v'):
    t = p.read_bytes()
    n = t.replace(b'parameter\t\tTCo_C', b'localparam\t\tTCo_C')
    if n != t:
        p.write_bytes(n)
        print('fixed TCo_C in', p.name)
