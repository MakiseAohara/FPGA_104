import re, pathlib, collections, statistics as st
p = pathlib.Path(r'C:\Users\Makise Aohara\Documents\deepseek-harness\default-workspace\FPGA_104\out\mot_test\serial_ts.log')
trk = re.compile(r'MMT_TRK f=(\d+) id=(-?\d+) c=(-?\d+),(-?\d+) b=(-?\d+),(-?\d+),(-?\d+),(-?\d+) .*?hit=(\d+) miss=(\d+)')
box = []
per_id = collections.defaultdict(list)
for ln in p.read_text(encoding='utf-8', errors='replace').splitlines():
    if '\t' not in ln: continue
    ts, s = ln.split('\t', 1)
    m = trk.search(s)
    if not m: continue
    g = list(map(int, m.groups()))
    f, i, cx, cy, x0, y0, x1, y1, hit, miss = g
    w, h = x1-x0+1, y1-y0+1
    box.append((float(ts), i, w, h, hit, miss))
print('track lines', len(box))
ws = [b[2] for b in box]; hs = [b[3] for b in box]
print('box w: median %d p90 %d | h: median %d p90 %d' % (st.median(ws), sorted(ws)[int(len(ws)*0.9)], st.median(hs), sorted(hs)[int(len(hs)*0.9)]))
wide = sum(1 for b in box if b[2] > 2.2 * b[3])
print('宽高比 >2.2 的框（疑似两人并在一起）: %d / %d = %.0f%%' % (wide, len(box), 100*wide/len(box)))
# 每个 ID 的寿命
ids = collections.defaultdict(list)
for ts, i, w, h, hit, miss in box: ids[i].append(ts)
life = [(i, max(v)-min(v), len(v)) for i, v in ids.items()]
life.sort(key=lambda x: -x[1])
print('\nID   存活(s)  出现次数')
for i, dur, n in life[:12]:
    print('%4d  %6.1f  %5d' % (i, dur, n))
print('\nID 总数 %d，时长中位 %.1f s' % (len(ids), st.median([l[1] for l in life])))
