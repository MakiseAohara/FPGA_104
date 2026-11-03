import re, glob
from pathlib import Path
TRK = re.compile(r"MMT_TRK f=(\d+) id=\d+ c=\d+,\d+ b=(-?\d+),(-?\d+),(-?\d+),(-?\d+)")
DEC = re.compile(r"MMT_DEC t=\d+ f=(\d+).*?person=(\d)")
tot = full = full_noperson = 0
per = {}
for f in glob.glob(r"out\*\serial.log"):
    person = {}
    n_full = n_full_np = n = 0
    for line in Path(f).read_text(encoding="utf-8", errors="replace").splitlines():
        m = DEC.search(line)
        if m: person[int(m.group(1))] = int(m.group(2)) == 1; continue
        m = TRK.search(line)
        if not m: continue
        fr = int(m.group(1)); x0,y0,x1,y1 = [int(x) for x in m.groups()[1:]]
        w, h = x1-x0+1, y1-y0+1
        n += 1
        if w*10 >= 96*9 and h*10 >= 96*9:
            n_full += 1
            if not person.get(fr, False): n_full_np += 1
    if n: per[f] = (n, n_full, n_full_np)
    tot += n; full += n_full; full_noperson += n_full_np
print("日志数 %d，检测框样本 %d" % (len(per), tot))
for f, (n, nf, nfnp) in sorted(per.items(), key=lambda kv: -kv[1][0]):
    print("  %-28s 框 %4d  整幅(>=90%%) %3d (%.0f%%)  其中 AI 判无人 %3d" % (f, n, nf, 100.0*nf/n, nfnp))
print("合计: 整幅占比 %.1f%%，整幅且 AI 判无人 %d/%d" % (100.0*full/tot, full_noperson, full))
