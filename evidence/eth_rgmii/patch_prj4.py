import pathlib
src = pathlib.Path(r'D:\v30_build\m17\ti60f225_oob.xml')
dst = pathlib.Path(r'D:\eth_build\m17_ge\ti60f225_oob.xml')
ROOT = pathlib.Path(r'D:\eth_build\m17_ge')
lines = src.read_bytes().split(b'\n')
kept = [l for l in lines if b'name="rtl/ge/' not in l]
print('removed:', len(lines) - len(kept), 'of', len(lines))
keep = sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / 'rtl' / 'ge').rglob('*.v'))
ins = [b'        <efx:design_file name="%s" version="default" library="default"/>' % k.encode() for k in keep]
out, done = [], False
for l in kept:
    if not done and l.strip() == b'<efx:top_vhdl_arch name=""/>':
        out.extend(ins); done = True
    out.append(l)
assert done, 'anchor not found'
dst.write_bytes(b'\n'.join(out))
print('added', len(keep), 'files')
