import re, sys, statistics as st
trk = re.compile(r'MMT_TRK f=(\d+) id=(-?\d+) c=(-?\d+),(-?\d+) b=(-?\d+),(-?\d+),(-?\d+),(-?\d+) '
                 r'v16=(-?\d+),(-?\d+) dir=(-?\d+) hit=(\d+) miss=(\d+) conf=(\d+) pred=(-?\d+),(-?\d+) eta=(-?\d+)')
path = sys.argv[1]
recs = {}; n = 0; prewarn = 0; prewarn_cur = 0; lp_exit_pre = 0; last_write = None
with open(path, 'r', encoding='utf-8', errors='replace') as f:
    for ln in f:
        if 'MMT_PREWARN' in ln: prewarn += 1
        if 'reason=prewarn' in ln: lp_exit_pre += 1
        i = ln.find('MMT_TRK')
        if i < 0: continue
        m = trk.search(ln, i)
        if not m: continue
        n += 1
        g = list(map(int, m.groups()))
        f_, id_, cx, cy, x0, y0, x1, y1, vx, vy, d, hit, miss, conf, px, py, eta = g
        recs.setdefault(id_, {})[f_] = (cx, cy, vx, vy, miss, px, py, eta)

print("TRK lines=%d ids=%d  MMT_PREWARN=%d  LP_EXIT reason=prewarn=%d" % (n, len(recs), prewarn, lp_exit_pre))

def err(k):
    e = []; sp = []
    for fr in recs.values():
        for f_ in sorted(fr):
            a = fr[f_]; b = fr.get(f_ + 1)
            if not b or b[4] != 0: continue
            cx, cy, vx, vy = a[0], a[1], a[2], a[3]
            ex = cx + int(round(vx * k / 16.0)); ey = cy + int(round(vy * k / 16.0))
            dx, dy = ex - b[0], ey - b[1]
            e.append((dx*dx+dy*dy) ** 0.5); sp.append(((vx*vx+vy*vy) ** 0.5) / 16.0)
    return e, sp

base = None
for k in (0, 1, 2, 3, 4, 6):
    e, sp = err(k)
    mv = [x for x, s in zip(e, sp) if s >= 0.5]
    stl = [x for x, s in zip(e, sp) if s < 0.5]
    print("k=%d frames  median=%5.2f mean=%5.2f | moving median=%5.2f (n=%d) | still median=%5.2f" %
          (k, st.median(e), st.mean(e), st.median(mv) if mv else -1, len(mv), st.median(stl) if stl else -1))

ets = [a[7] for fr in recs.values() for a in fr.values()]
print("eta values:", sorted(set(ets)), " share eta>=0: %.2f%%" % (100.0*sum(1 for x in ets if x >= 0)/len(ets)))
