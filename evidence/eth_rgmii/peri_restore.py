import pathlib, shutil
p = pathlib.Path(r'D:\eth_build\m17_ge\ti60f225_oob.peri.xml')
bak = p.with_suffix('.xml.bak_full')
if bak.exists():
    shutil.copy2(bak, p)
    print('peri restored (pins+PLL), size', p.stat().st_size)
