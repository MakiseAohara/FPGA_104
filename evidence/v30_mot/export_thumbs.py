"""export_thumbs.py — 从串口日志导出 48x48 缩略图并 2x 放大成 96x96 帧（回放用）。
用法: py -3 export_thumbs.py <log> <out_dir>
"""
import argparse, json, re
from pathlib import Path

ap = argparse.ArgumentParser()
ap.add_argument('log'); ap.add_argument('out')
a = ap.parse_args()
out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
pat = re.compile(r'MMT_THUMB t=(\d+) f=(\d+) alarm=(\d+) p=(-?\d+) ([0-9a-f]+)')
frames, meta = [], []
for line in open(a.log, encoding='utf-8', errors='replace'):
    m = pat.search(line)
    if not m: continue
    t, f, al, p, hexs = int(m.group(1)), int(m.group(2)), int(m.group(3)), int(m.group(4)), m.group(5)
    if len(hexs) != 48*48*2: continue
    small = bytes.fromhex(hexs)
    big = bytearray(96*96)
    for y in range(96):
        sy = y // 2
        for x in range(96):
            big[y*96+x] = small[sy*48 + (x//2)]
    frames.append(bytes(big)); meta.append(dict(f=f, t=t, alarm=al, p=p))
(out/'frames.bin').write_bytes(b''.join(frames))
(out/'ai.txt').write_text(''.join(str(m['p']) + '\n' for m in meta), encoding='utf-8')
(out/'frames.json').write_text(json.dumps(meta, indent=1), encoding='utf-8')
print('frames', len(frames))
