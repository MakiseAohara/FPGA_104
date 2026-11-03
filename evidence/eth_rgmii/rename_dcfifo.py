import pathlib, re
ROOT = pathlib.Path(r'D:\eth_build\m17_ge\rtl\ge')
ren = {'DC_FIFO': 'GE_DC_FIFO', 'FifoAddrCnt': 'GE_FifoAddrCnt', 'GrayCnt': 'GE_GrayCnt', 'GrayDecode': 'GE_GrayDecode'}
n = 0
for p in ROOT.rglob('*.v'):
    t = p.read_bytes()
    o = t
    for a, b in ren.items():
        t = re.sub(rb'\b' + a.encode() + rb'\b', b.encode(), t)
    if t != o:
        p.write_bytes(t); n += 1
        print('renamed in', p.name)
print('files changed:', n)
