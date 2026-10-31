# -*- coding: utf-8 -*-
"""export_thumbs.py — 用 MMT_THUMB(48x48) 生成 96x96 回放帧（最近邻 2x），并导出 ai_p / ir_cnt 序列。
用法: python export_thumbs.py <log> <out_dir> [--scale 2]
产物: frames.bin（每帧 96*96 字节）、ai.txt（每帧一个整数）、ir.txt（每帧一个整数）、frames.json（元数据）
"""
import argparse, json, re
from pathlib import Path

ap = argparse.ArgumentParser()
ap.add_argument('log')
ap.add_argument('out')
ap.add_argument('--scale', type=int, default=2)
a = ap.parse_args()
out = Path(a.out); out.mkdir(parents=True, exist_ok=True)

RE_THUMB = re.compile(r'MMT_THUMB t=(\d+) f=(\d+) alarm=(\d) p=(-?\d+) ([0-9a-fA-F]+)')
RE_DEC = re.compile(r'MMT_DEC t=(\d+) f=(\d+).*?ir_cnt=(\d+)')
RE_AI = re.compile(r'MMT_AI f=(\d+) p=(-?\d+)')

dec_ir = {}
dec_ms = {}
for line in open(a.log, encoding='utf-8', errors='replace'):
    m = RE_DEC.search(line)
    if m:
        dec_ms[int(m.group(2))] = int(m.group(1))
        dec_ir[int(m.group(2))] = int(m.group(3))

frames, meta, ai_list, ir_list = [], [], [], []
for line in open(a.log, encoding='utf-8', errors='replace'):
    m = RE_THUMB.search(line)
    if not m:
        continue
    t, f, alarm, p, hx = int(m.group(1)), int(m.group(2)), int(m.group(3)), int(m.group(4)), m.group(5)
    if len(hx) < 4608:
        continue
    b = bytes.fromhex(hx[:4608])
    if len(b) != 48 * 48:
        continue
    s = a.scale
    if s == 2:
        row96 = bytearray(96)
        frame = bytearray(96 * 96)
        for y in range(48):
            src = b[y * 48:(y + 1) * 48]
            for x in range(48):
                v = src[x]
                row96[2 * x] = v; row96[2 * x + 1] = v
            frame[(2 * y) * 96:(2 * y + 1) * 96] = row96
            frame[(2 * y + 1) * 96:(2 * y + 2) * 96] = row96
        frames.append(bytes(frame))
    ai_list.append(p)
    ir_list.append(dec_ir.get(f, 2))
    meta.append(dict(f=f, t=t, p=p, alarm=alarm, ir=dec_ir.get(f, 2)))

(out / 'frames.bin').write_bytes(b''.join(frames))
(out / 'ai.txt').write_text('\n'.join(str(x) for x in ai_list) + '\n', encoding='utf-8')
(out / 'ir.txt').write_text('\n'.join(str(x) for x in ir_list) + '\n', encoding='utf-8')
(out / 'frames.json').write_text(json.dumps(meta, indent=1), encoding='utf-8')
print('frames', len(frames), 'bytes', len(frames) * 96 * 96)
if meta:
    ps = sorted(m['p'] for m in meta)
    print('p min/med/max', ps[0], ps[len(ps)//2], ps[-1], '| ir max', max(m['ir'] for m in meta))
