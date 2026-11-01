"""export_frames.py — 从固件串口日志导出 96x96 帧，供 MOT 回放。
用法: py -3 export_frames.py <log> <out_dir>
产物: frames.bin（每帧 9216 B，逐行 96 字节）+ frames.json（f/t/p 元数据）
"""
import argparse, json, re
from pathlib import Path

ap = argparse.ArgumentParser()
ap.add_argument('log'); ap.add_argument('out')
a = ap.parse_args()
out = Path(a.out); out.mkdir(parents=True, exist_ok=True)

stat = re.compile(r'MMT_IMGSTAT f=(\d+) .*p=(-?\d+)')
img = re.compile(r'MMT_IMG (\d\d) ([0-9a-fA-F]{192})')
frames, meta = [], []
cur = {}
last = {}
for line in open(a.log, encoding='utf-8', errors='replace'):
    t = line.split('\t')[0] if '\t' in line else ''
    m = stat.search(line)
    if m:
        last = dict(f=int(m.group(1)), p=int(m.group(2)), t=t); cur = {}
        continue
    m = img.search(line)
    if m:
        y = int(m.group(1)); cur[y] = bytes.fromhex(m.group(2))
        if len(cur) == 96:
            frames.append(b''.join(cur[y] for y in range(96)))
            meta.append(dict(last)); cur = {}

(out / 'frames.bin').write_bytes(b''.join(frames))
(out / 'frames.json').write_text(json.dumps(meta, indent=1), encoding='utf-8')
print('frames', len(frames), 'bytes', 96*96*len(frames))
if meta:
    ps = sorted(m['p'] for m in meta)
    print('p min/med/max', ps[0], ps[len(ps)//2], ps[-1])
