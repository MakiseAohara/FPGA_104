"""mot_metrics.py — 修前/修后对比用的四个指标"""
import argparse, re, statistics as st
from collections import defaultdict
ap = argparse.ArgumentParser(); ap.add_argument('log'); a = ap.parse_args()
mot = re.compile(r'MMT_MOT f=(\d+) nd=(\d+) nt=(\d+) conf=(\d+) area=(\d+)(?: raw=(\d+))?')
trk = re.compile(r'MMT_TRK f=(\d+) id=(\d+) .*conf=(\d+)')
rows, ids = [], defaultdict(int)
for line in open(a.log, encoding='utf-8', errors='replace'):
    m = mot.search(line)
    if m:
        g = m.groups()
        rows.append((int(g[0]), int(g[1]), int(g[3]), int(g[5] or 0)))
        continue
    m = trk.search(line)
    if m and int(m.group(3)) == 1:
        ids[int(m.group(2))] += 1
nd0 = sum(1 for r in rows if r[1] == 0)
big = sum(1 for r in rows if r[3] >= 8500)
lens = sorted(ids.values())
print({
    'frames': len(rows),
    'confirmed_tracks': len(ids),
    'confirmed_len_median': st.median(lens) if lens else 0,
    'confirmed_len_max': max(lens) if lens else 0,
    'nd0_frames': nd0,
    'raw_ge_8500_frames': big,
})
