import re, pathlib
src = pathlib.Path(r'D:\v30_build\m17\ti60f225_oob.xml')
dst = pathlib.Path(r'D:\eth_build\m17_ge\ti60f225_oob.xml')
ROOT = pathlib.Path(r'D:\eth_build\m17_ge')
data = src.read_bytes()
data = re.sub(rb'[ \t]*<efx:design_file name="rtl/ge/[^"]+"[^>]*/>\r?\n', b'', data)
keep = sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / 'rtl' / 'ge').rglob('*.v'))
ins = b''.join(b'        <efx:design_file name="%s" version="default" library="default"/>\r\n' % k.encode() for k in keep)
anchor = b'        <efx:top_vhdl_arch name=""/>'
assert anchor in data, 'anchor missing'
data = data.replace(anchor, ins + anchor, 1)
dst.write_bytes(data)
print('patched with', len(keep), 'ge files, size', len(data))
