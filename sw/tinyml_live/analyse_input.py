"""Capture one or more model-input snapshots and compare the input distribution.

No person needed: this only characterises what the model is fed.

Writes the raw log next to the output file and prints per-snapshot statistics:
min/max/mean byte, share of pixels below 0x80, the modal byte, distinct values,
and how much of the frame is "flat" (a crude image-quality proxy).
"""
import argparse
import collections
import statistics
import time

import serial


def parse_snapshot(lines):
    """Return list of (frames, stat_line, rows)."""
    snaps = []
    cur = None
    for ln in lines:
        if ln.startswith("MMT_IMGSTAT"):
            if cur:
                snaps.append(cur)
            cur = {"stat": ln, "rows": []}
        elif ln.startswith("MMT_IMG ") and cur is not None:
            cur["rows"].append(ln)
    if cur:
        snaps.append(cur)
    return snaps


def analyse(snap, tag):
    rows = snap["rows"]
    if len(rows) < 96:
        print(f"  [{tag}] 只有 {len(rows)} 行，跳过")
        return None
    vals = []
    grid = []
    for r in rows[:96]:
        hexs = r.split()[2]
        row = [int(hexs[i:i + 2], 16) for i in range(0, len(hexs), 2)]
        grid.append(row)
        vals += row

    n = len(vals)
    lo = sum(1 for v in vals if v < 0x80)
    c = collections.Counter(vals)
    top_byte, top_cnt = c.most_common(1)[0]
    signed = [v - 256 if v >= 128 else v for v in vals]

    # crude "flatness": share of horizontal neighbours differing by < 3
    same = tot = 0
    for row in grid:
        for x in range(95):
            tot += 1
            if abs(row[x] - row[x + 1]) < 3:
                same += 1

    print(f"  [{tag}] {snap['stat']}")
    print(f"       字节 min={min(vals):3d} max={max(vals):3d} "
          f"mean={sum(vals)/n:6.1f}  sd={statistics.pstdev(vals):5.1f}")
    print(f"       有符号 mean={sum(signed)/n:7.1f}")
    print(f"       <0x80 占比 {100.0*lo/n:5.2f}%   众数 {top_byte:#04x} 占 {100.0*top_cnt/n:5.1f}%   "
          f"不同取值 {len(c)}")
    print(f"       水平相邻差<3 的占比 {100.0*same/tot:5.1f}%  (越高越平/越糊)")
    return dict(mean=sum(vals) / n, sd=statistics.pstdev(vals), lo=100.0 * lo / n,
                mode=top_byte, mode_pct=100.0 * top_cnt / n, distinct=len(c),
                flat=100.0 * same / tot)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default="COM15")
    ap.add_argument("--secs", type=float, default=70.0)
    ap.add_argument("--out", required=True)
    ap.add_argument("--tag", default="merge8")
    a = ap.parse_args()

    buf = bytearray()
    t0 = time.time()
    with serial.Serial(a.port, 115200, timeout=0.1) as p:
        p.reset_input_buffer()
        while time.time() - t0 < a.secs:
            n = p.in_waiting
            chunk = p.read(n if n else 1)
            if not chunk:
                continue
            buf.extend(chunk)

    text = buf.decode("ascii", "replace")
    open(a.out, "w", encoding="utf-8").write(text)
    lines = [l.strip() for l in text.splitlines() if l.strip()]
    snaps = parse_snapshot(lines)

    print(f"采集 {a.secs:.0f}s，收到 {len(buf)} 字节，快照 {len(snaps)} 组")
    osd = [l for l in lines if l.startswith("MMT_OSD")]
    print(f"MMT_OSD 行数: {len(osd)}")
    if osd:
        pv = []
        for l in osd:
            try:
                pv.append(int(l.split("p=")[1].split()[0]))
            except Exception:
                pass
        if pv:
            pos = sum(1 for v in pv if v > 0)
            print(f"  p: min={min(pv)} max={max(pv)} mean={sum(pv)/len(pv):.1f} "
                  f"osd=1 帧数 {pos}/{len(pv)} ({100.0*pos/len(pv):.1f}%)")
    print()
    res = []
    for i, s in enumerate(snaps):
        r = analyse(s, f"{a.tag}#{i}")
        if r:
            res.append(r)
    print(f"\n原始日志: {a.out}")


if __name__ == "__main__":
    main()
