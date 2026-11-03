import re, pathlib, collections, statistics as st
p = pathlib.Path(r'C:\Users\Makise Aohara\Documents\deepseek-harness\default-workspace\FPGA_104\out\mot_test\serial_ts.log')
trk = re.compile(r'MMT_TRK f=(\d+) id=(-?\d+) c=(-?\d+),(-?\d+) b=(-?\d+),(-?\d+),(-?\d+),(-?\d+) .*?miss=(\d+)')
mot = re.compile(r'MMT_MOT f=(\d+) nd=(\d+) nt=(\d+) conf=(\d+) .*?obs=(\d+)')
frames = collections.defaultdict(list)   # f -> tracks
motf = {}
gt = []
for ln in p.read_text(encoding='utf-8', errors='replace').splitlines():
    if '\t' not in ln: continue
    ts, s = ln.split('\t', 1)
    if s.startswith('MMT_TRK'):
        m = trk.search(s)
        if m:
            g = list(map(int, m.groups()))
            frames[g[0]].append((ts, g))
    elif s.startswith('MMT_MOT'):
        m = mot.search(s)
        if m:
            g = list(map(int, m.groups()))
            motf.setdefault(g[0], (ts, g))
print('frames with TRK:', len(frames), ' MOT lines:', len(motf))
# 每 10 秒统计一次（用 MOT 行的时间戳）
buckets = collections.defaultdict(lambda: dict(n=0, nt=collections.Counter(), obs=collections.Counter(), ids=set()))
for f, (ts, g) in sorted(motf.items(), key=lambda kv: float(kv[1][0])):
    t = float(ts); b = int(t // 10) * 10
    d = buckets[b]
    d['n'] += 1
    d['nt'][g[2]] += 1
    d['obs'][g[4]] += 1
    for tt in frames.get(f, []):
        d['ids'].add(tt[1][1])
print('\n t(s)  calls  nt分布        obs分布       本段ID')
for b in sorted(buckets):
    d = buckets[b]
    print('%4d  %5d  %-12s  %-12s  %s' % (b, d['n'],
        dict(sorted(d['nt'].items())), dict(sorted(d['obs'].items())), sorted(d['ids'])))
