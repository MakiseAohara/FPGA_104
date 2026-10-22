"""Check whether the frame content is horizontally duplicated.

Captures one 96x96 snapshot and compares the left half (source x = 0..960) with
the right half (source x = 960..1920).  If the pipeline really captures 1920
distinct columns the two halves are independent; if it captures 960 and repeats,
they match closely.
"""
import sys
import time

import serial

PORT = sys.argv[1] if len(sys.argv) > 1 else "COM15"
SECS = float(sys.argv[2]) if len(sys.argv) > 2 else 45.0


def capture(port, secs):
    buf = bytearray()
    t0 = time.time()
    with serial.Serial(port, 115200, timeout=0.1) as p:
        p.reset_input_buffer()
        while time.time() - t0 < secs:
            n = p.in_waiting
            chunk = p.read(n if n else 1)
            if chunk:
                buf.extend(chunk)
                # stop as soon as a full snapshot is in
                if buf.count(b"MMT_IMG ") >= 96:
                    break
    return buf.decode("ascii", "replace")


def main():
    text = capture(PORT, SECS)
    rows = []
    cur = {}
    for ln in text.splitlines():
        ln = ln.strip()
        if not ln.startswith("MMT_IMG "):
            continue
        parts = ln.split()
        if len(parts) < 3:
            continue
        try:
            y = int(parts[1])
        except ValueError:
            continue
        hx = parts[2]
        if len(hx) != 192:
            continue
        if y == 0 and len(cur) == 96:
            rows = [cur[k] for k in range(96)]
            cur = {}
        cur[y] = [int(hx[i:i + 2], 16) for i in range(0, 192, 2)]
    if len(cur) >= 40:
        rows = [cur[k] for k in sorted(cur)]
    if len(rows) < 40:
        sys.exit(f"快照行数不足（{len(cur)}）")

    diffs = []
    left, right = [], []
    for r in rows:
        for x in range(48):
            a, b = r[x], r[x + 48]
            left.append(a)
            right.append(b)
            diffs.append(abs(a - b))

    n = len(diffs)
    mean_l = sum(left) / n
    mean_r = sum(right) / n
    mean_d = sum(diffs) / n
    small = sum(1 for d in diffs if d <= 3)

    # correlation
    num = sum((left[i] - mean_l) * (right[i] - mean_r) for i in range(n))
    den = (sum((v - mean_l) ** 2 for v in left) *
           sum((v - mean_r) ** 2 for v in right)) ** 0.5
    corr = num / den if den else 0.0

    print(f"样本数        : {n}  (96 行 × 48 对)")
    print(f"左半均值      : {mean_l:.1f}")
    print(f"右半均值      : {mean_r:.1f}")
    print(f"平均绝对差    : {mean_d:.2f}")
    print(f"差值 ≤3 的比例: {100.0*small/n:.1f}%")
    print(f"左右相关系数  : {corr:.3f}")
    print()
    if corr > 0.9:
        print("⇒ 左右高度相关：画面被水平重复（实际只采到约 960 列）")
    elif corr > 0.6:
        print("⇒ 中等相关：可能是平滑场景，也可能是部分重复")
    else:
        print("⇒ 左右独立：确实采到了 1920 列")


if __name__ == "__main__":
    main()
