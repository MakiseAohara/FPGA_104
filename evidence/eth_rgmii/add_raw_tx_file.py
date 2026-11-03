import pathlib
# 工程文件表：加 ge_raw_tx.v
p = pathlib.Path(r'D:\eth_build\m17_ge\ti60f225_oob.xml')
lines = p.read_bytes().split(b'\n')
if not any(b'ge_raw_tx.v' in l for l in lines):
    i = next(k for k, l in enumerate(lines) if b'<efx:top_vhdl_arch' in l)
    lines.insert(i, b'        <efx:design_file name="rtl/ge/ge_raw_tx.v" version="default" library="default"/>')
    p.write_bytes(b'\n'.join(lines))
    print('project: +ge_raw_tx.v')
else:
    print('already listed')
